#!/usr/bin/env bash
# -E (errtrace) は必須。process_target が仕掛ける ERR トラップ（terminate 前の失敗で新EC2の
# 終了保護・停止保護を復元する）は、errtrace が無いと関数内の失敗で発火しない。
set -eEuo pipefail

# 切り戻しスクリプト。
# 役割: 02_backup.sh のバックアップ AMI から復旧 EC2 を起動し、保全 ENI を付け替えて IP を維持したまま
#       PAYG ライセンスへ戻す。ELC 新 EC2 は terminate し、その EBS は available で残置する。
# 前提: 01〜03 完走済み（new_instance_after_switch.json の存在で確認）。
# 生成する状態ファイル: rollback_instance_run.json, rollback_instance_id.txt,
# rollback_preserved_volume_ids.txt, rollback_instance_after.json,
# 05_rollback.log, timings_05_rollback.tsv。
# 実行方式: targets.txt を上から順に1台ずつ処理する逐次のみ（並行モードなし）。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# 06_verify_rollback.sh の同名変数と同じ値を保つこと。
ROLLBACK_PRESERVED_PURPOSE="switch-ec2-rollback-preserved"

# 目的: 05 専用のコマンドラインオプション（--yes / --target / --help）を解釈する。
# 引数: コマンドライン引数。
# 出力: グローバル YES, ROLLBACK_TARGETS を設定する。
parse_rollback_flags() {
  YES=false
  ROLLBACK_TARGETS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) YES=true ;;
      --target)
        [[ -n "${2:-}" ]] || die "--target には対象インスタンスIDが必要です"
        [[ "$2" =~ ^i-[0-9a-f]+$ ]] || die "不正なインスタンスIDです: $2"
        ROLLBACK_TARGETS+=("$2")
        shift
        ;;
      -h|--help)
        printf 'Usage: %s [--yes] [--target <instance-id>]...\n' "$0"
        printf '  --yes          確認プロンプトを省略する\n'
        printf '  --target <id>  targets.txt を使わず指定した旧EC2だけを切り戻す（複数指定可）\n'
        exit 0
        ;;
      *) die "不明なオプションです: $1" ;;
    esac
    shift
  done
}

# 目的: AWS CLI に file:// で渡す一時 JSON ファイルを作る。
# 引数: なし。
# 出力: stdout に一時ファイルパス。
tmp_json() {
  local file
  file=$(mktemp)
  printf '%s\n' "$file"
}

# 目的: インスタンスにアタッチ済み EBS の DeleteOnTermination を変更する。
# 引数: インスタンスID, デバイス名, true/false。
# 出力: EC2 属性を更新する。
modify_volume_dot() {
  local instance_id=$1
  local device_name=$2
  local delete_on_termination=$3
  local file
  file=$(tmp_json)
  jq -n --arg device "$device_name" --argjson dot "$delete_on_termination" \
    '[{DeviceName: $device, Ebs: {DeleteOnTermination: $dot}}]' > "$file"
  aws_json ec2 modify-instance-attribute --instance-id "$instance_id" --block-device-mappings "file://$file" >/dev/null
  rm -f "$file"
}

# 目的: ENI アタッチメントの DeleteOnTermination を変更する。
# 引数: ENI ID, Attachment ID, true/false。
# 出力: ENI 属性を更新する。
modify_eni_dot() {
  local eni_id=$1
  local attachment_id=$2
  local delete_on_termination=$3
  aws_json ec2 modify-network-interface-attribute \
    --network-interface-id "$eni_id" \
    --attachment "AttachmentId=${attachment_id},DeleteOnTermination=${delete_on_termination}" >/dev/null
}

# 目的: terminate 発行前の失敗時に、ELC 新 EC2 の終了保護・停止保護を元の有効値へ戻す。
# 引数: なし（process_target のローカル変数を参照）。
# 出力: 保護属性を更新し、復元失敗はログへ記録する。
restore_protection_on_error() {
  local rc=$?
  trap - ERR
  set +e
  if [[ "${terminate_issued:-false}" != "true" ]]; then
    if [[ "${term_protection_changed:-false}" == "true" ]]; then
      log_warn "$new_instance_id の終了保護を復元します。"
      aws_json ec2 modify-instance-attribute --instance-id "$new_instance_id" --disable-api-termination >/dev/null \
        || log_error "$new_instance_id の終了保護を復元できませんでした。"
    fi
    if [[ "${stop_protection_changed:-false}" == "true" ]]; then
      log_warn "$new_instance_id の停止保護を復元します。"
      aws_json ec2 modify-instance-attribute --instance-id "$new_instance_id" --disable-api-stop >/dev/null \
        || log_error "$new_instance_id の停止保護を復元できませんでした。"
    fi
  fi
  set -e
  return "$rc"
}

# 目的: 破壊的操作の前に、状態ファイル・バックアップAMI・ELC新EC2の構成を検証する。
# 引数: 旧 EC2 インスタンスID。
# 出力: 不備があればエラー。AWS 側は describe のみで変更しない。
preflight_target() {
  local old_instance_id=$1
  local dir file backup_ami_id backup_json backup_state backup_source old_arch backup_arch
  local old_usage backup_usage old_boot backup_boot new_instance_id new_desc new_state saved_new_id
  local expected_devices actual_devices snapshot_ids snapshot_json extra_volumes
  dir=$(state_dir "$old_instance_id")

  [[ ! -f "$dir/rollback_instance_id.txt" ]] || die "この対象は切り戻し済みのため再実行禁止です: $old_instance_id"
  local json_files=(
    instance.json enis.json block_devices.json tags.json placement.json metadata_options.json
    instance_type.json key_name.json iam_instance_profile.json ebs_optimized.json monitoring.json
    shutdown_behavior.json disable_api_termination.json disable_api_stop.json maintenance_options.json
    private_dns_name_options.json cpu_options.json capacity_reservation.json credit_specification.json
    root_device_name.json usage_operation.json
  )
  for file in "${json_files[@]}"; do
    need_file "$dir/$file"
    [[ -s "$dir/$file" ]] || die "状態ファイルが空です: $dir/$file"
    # jq -e . は false/null を終了コード1にするため、その2値だけ構文解析済みの正当値として補完する。
    if ! jq -e . "$dir/$file" >/dev/null; then
      jq -e 'select(. == false or . == null) | true' "$dir/$file" >/dev/null \
        || die "状態ファイルが有効な JSON ではありません: $dir/$file"
    fi
  done
  need_file "$dir/user_data.b64.txt"
  need_file "$dir/backup_ami_id.txt"
  need_file "$dir/backup_created_at.txt"
  need_file "$dir/new_instance_id.txt"
  if [[ ! -f "$dir/new_instance_after_switch.json" ]]; then
    die "03_switch.sh の完走証跡がありません: $dir/new_instance_after_switch.json。README.md の手動復旧 runbook を参照してください。"
  fi
  jq -e . "$dir/new_instance_after_switch.json" >/dev/null \
    || die "状態ファイルが有効な JSON ではありません: $dir/new_instance_after_switch.json"
  if [[ "$COPY_USER_DATA" == "true" && -s "$dir/user_data.b64.txt" ]]; then
    base64 -d "$dir/user_data.b64.txt" >/dev/null || die "UserData の base64 を復号できません: $dir/user_data.b64.txt"
  fi

  backup_ami_id=$(<"$dir/backup_ami_id.txt")
  backup_json=$(aws_json ec2 describe-images --image-ids "$backup_ami_id")
  [[ "$(jq '.Images | length' <<<"$backup_json")" == "1" ]] || die "バックアップAMIが見つかりません: $backup_ami_id"
  backup_state=$(jq -r '.Images[0].State // empty' <<<"$backup_json")
  [[ "$backup_state" == "available" ]] || die "バックアップAMIが available ではありません: $backup_ami_id state=$backup_state"
  backup_source=$(jq -r 'first(.Images[0].Tags[]? | select(.Key == "SourceInstanceId") | .Value) // empty' <<<"$backup_json")
  [[ "$backup_source" == "$old_instance_id" ]] \
    || die "バックアップAMIの SourceInstanceId が対象と一致しません: ami=$backup_ami_id expected=$old_instance_id actual=${backup_source:-空}"
  old_arch=$(jq -r '.Reservations[0].Instances[0].Architecture // empty' "$dir/instance.json")
  backup_arch=$(jq -r '.Images[0].Architecture // empty' <<<"$backup_json")
  [[ "$backup_arch" == "$old_arch" ]] \
    || die "バックアップAMIのアーキテクチャが想定外です（状態保存またはAMI作成の不整合）: instance=$old_arch ami=$backup_arch"
  old_usage=$(jq -r '. // empty' "$dir/usage_operation.json")
  backup_usage=$(jq -r '.Images[0].UsageOperation // empty' <<<"$backup_json")
  [[ -n "$old_usage" && "$backup_usage" == "$old_usage" ]] \
    || die "バックアップAMIの UsageOperation が旧PAYG値と一致しません: expected=${old_usage:-空} actual=${backup_usage:-空}"
  old_boot=$(jq -r '.Reservations[0].Instances[0].CurrentInstanceBootMode // .Reservations[0].Instances[0].BootMode // "legacy-bios"' "$dir/instance.json")
  backup_boot=$(jq -r '.Images[0].BootMode // "legacy-bios"' <<<"$backup_json")
  [[ "$backup_boot" == "$old_boot" || ( "$backup_boot" == "uefi-preferred" && "$old_boot" == "uefi" ) ]] \
    || die "バックアップAMIの BootMode が想定外です（状態保存またはAMI作成の不整合）: instance=$old_boot ami=$backup_boot"

  expected_devices=$(jq -c '[.[].DeviceName] | sort' "$dir/block_devices.json")
  actual_devices=$(jq -c '[.Images[0].BlockDeviceMappings[] | select(.Ebs != null) | .DeviceName] | sort' <<<"$backup_json")
  [[ "$expected_devices" == "$actual_devices" ]] \
    || die "バックアップAMIの EBS デバイス集合が切替前と一致しません: expected=$expected_devices actual=$actual_devices"
  jq -e '[.Images[0].BlockDeviceMappings[] | select(.Ebs != null) | .Ebs.SnapshotId] | all(type == "string" and length > 0)' \
    <<<"$backup_json" >/dev/null || die "バックアップAMIに SnapshotId が無い EBS マッピングがあります: $backup_ami_id"
  mapfile -t snapshot_ids < <(jq -r '.Images[0].BlockDeviceMappings[] | select(.Ebs != null) | .Ebs.SnapshotId' <<<"$backup_json")
  snapshot_json=$(aws_json ec2 describe-snapshots --snapshot-ids "${snapshot_ids[@]}")
  jq -e --argjson count "${#snapshot_ids[@]}" '.Snapshots | length == $count and all(.State == "completed")' \
    <<<"$snapshot_json" >/dev/null || die "バックアップAMIのスナップショットが completed ではありません: $backup_ami_id"

  new_instance_id=$(<"$dir/new_instance_id.txt")
  saved_new_id=$(jq -r '.Reservations[0].Instances[0].InstanceId // empty' "$dir/new_instance_after_switch.json")
  [[ "$saved_new_id" == "$new_instance_id" ]] \
    || die "切替後状態ファイルのインスタンスIDが不一致です: expected=$new_instance_id actual=${saved_new_id:-空}"
  new_desc=$(aws_json ec2 describe-instances --instance-ids "$new_instance_id")
  [[ "$(jq '.Reservations | length' <<<"$new_desc")" == "1" ]] || die "ELC 新 EC2 が見つかりません: $new_instance_id"
  new_state=$(jq -r '.Reservations[0].Instances[0].State.Name // empty' <<<"$new_desc")
  [[ "$new_state" == "running" || "$new_state" == "stopped" ]] \
    || die "ELC 新 EC2 が切り戻し可能な状態ではありません: instance=$new_instance_id state=$new_state"

  # 既知の全 EBS が期待デバイスにあり、追加分以外の差異がないことを確認する。旧 root 名は 03 が保存した新 root 名へ読み替える。
  need_file "$dir/new_root_device_name.txt"
  if ! diff -u \
    <(jq --arg old_root "$(jq -r . "$dir/root_device_name.json")" --arg new_root "$(<"$dir/new_root_device_name.txt")" \
      '[.[] | {VolumeId, DeviceName: (if .DeviceName == $old_root then $new_root else .DeviceName end)}] | sort_by(.VolumeId, .DeviceName)' "$dir/block_devices.json") \
    <(jq --slurpfile known "$dir/block_devices.json" \
      '[.Reservations[0].Instances[0].BlockDeviceMappings[] | select(.Ebs != null)
        | select(.Ebs.VolumeId as $id | any($known[0][]; .VolumeId == $id))
        | {VolumeId: .Ebs.VolumeId, DeviceName}] | sort_by(.VolumeId, .DeviceName)' <<<"$new_desc") >/dev/null; then
    die "03_switch.sh 後に既知 EBS の構成が変更されています。terminate を中止します。"
  fi
  extra_volumes=$(jq -r --slurpfile known "$dir/block_devices.json" '
    [.Reservations[0].Instances[0].BlockDeviceMappings[] | select(.Ebs != null)
      | select(.Ebs.VolumeId as $id | any($known[0][]; .VolumeId == $id) | not) | .Ebs.VolumeId] | join(" ")' <<<"$new_desc")
  if [[ -n "$extra_volumes" ]]; then
    if [[ "${ROLLBACK_ALLOW_EXTRA_VOLUMES:-false}" == "true" ]]; then
      log_warn "03_switch.sh 後に追加された EBS を保全して続行します（ロールバック用タグは付けません）: $extra_volumes"
    else
      die "03_switch.sh 後に追加された EBS があります: $extra_volumes。確認済みの場合のみ ROLLBACK_ALLOW_EXTRA_VOLUMES=true を環境変数で指定してください。"
    fi
  fi
  if ! diff -u \
    <(jq '[.[] | {NetworkInterfaceId, DeviceIndex}] | sort_by(.NetworkInterfaceId, .DeviceIndex)' "$dir/enis.json") \
    <(jq '[.Reservations[0].Instances[0].NetworkInterfaces[] | {NetworkInterfaceId, DeviceIndex: .Attachment.DeviceIndex}] | sort_by(.NetworkInterfaceId, .DeviceIndex)' <<<"$new_desc") >/dev/null; then
    die "03_switch.sh 後に ENI 構成が変更されています。terminate を中止します。"
  fi
}

# 目的: バックアップ作成時刻から現在までの経過時間を表示用に求める。
# 引数: backup_created_at.txt の YYYYmmdd-HHMMSS 文字列。
# 出力: stdout に経過時間の概算文字列。
backup_age_for_display() {
  local created=$1
  local created_epoch now seconds
  if [[ "$created" =~ ^[0-9]{8}-[0-9]{6}$ ]] \
    && created_epoch=$(date -d "${created:0:8} ${created:9:2}:${created:11:2}:${created:13:2}" +%s 2>/dev/null); then
    now=$(date +%s)
    seconds=$(( now - created_epoch ))
    printf '%d日 %02d時間 %02d分' "$(( seconds / 86400 ))" "$(( seconds % 86400 / 3600 ))" "$(( seconds % 3600 / 60 ))"
  else
    printf '算出不能'
  fi
}

# 目的: 1台の ELC 新 EC2 を終了し、バックアップAMI由来の復旧 EC2 へ置き換える。
# 引数: 旧 EC2 インスタンスID。
# 出力: 復旧インスタンスID、保全ボリュームID、切り戻し後 describe JSON。
process_target() {
  local old_instance_id=$1
  local dir new_instance_id backup_ami_id disable_term disable_stop name current_desc confirmation
  local term_protection_changed=false stop_protection_changed=false terminate_issued=false
  local -a current_volume_ids=() known_volume_ids=() eni_ids=()
  dir=$(state_dir "$old_instance_id")

  # --- ステップ0: 状態ファイル・バックアップAMI・ELC新EC2の事前確認 ---
  timer_start step0_preflight
  preflight_target "$old_instance_id"
  new_instance_id=$(<"$dir/new_instance_id.txt")
  backup_ami_id=$(<"$dir/backup_ami_id.txt")
  current_desc=$(aws_json ec2 describe-instances --instance-ids "$new_instance_id")
  mapfile -t current_volume_ids < <(jq -r '.Reservations[0].Instances[0].BlockDeviceMappings[]?.Ebs.VolumeId // empty' <<<"$current_desc")
  mapfile -t known_volume_ids < <(jq -r '.[].VolumeId' "$dir/block_devices.json")
  mapfile -t eni_ids < <(jq -r '.[].NetworkInterfaceId' "$dir/enis.json")
  confirmation="破壊的な切り戻しを実行します。
terminate 対象の ELC 新 EC2: $new_instance_id
復旧に使うバックアップAMI: $backup_ami_id
巻き戻り時点: $(<"$dir/backup_created_at.txt")（現在まで約 $(backup_age_for_display "$(<"$dir/backup_created_at.txt")")）
この期間の書き込みは失われます。
残置する保全 EBS: ${current_volume_ids[*]}"
  timer_end step0_preflight "ステップ0 事前確認"
  confirm_or_exit "$YES" "$confirmation"
  trap restore_protection_on_error ERR

  # --- ステップ1: ELC 新 EC2 の終了保護・停止保護を一時的に無効化 ---
  timer_start step1_disable_protection
  disable_term=$(jq -r '.' "$dir/disable_api_termination.json")
  if [[ "$disable_term" == "true" ]]; then
    log_info "$new_instance_id の終了保護を一時的に無効化します。"
    aws_json ec2 modify-instance-attribute --instance-id "$new_instance_id" --no-disable-api-termination >/dev/null
    term_protection_changed=true
  fi
  disable_stop=$(jq -r '.' "$dir/disable_api_stop.json")
  if [[ "$disable_stop" == "true" ]]; then
    log_info "$new_instance_id の停止保護を一時的に無効化します。"
    aws_json ec2 modify-instance-attribute --instance-id "$new_instance_id" --no-disable-api-stop >/dev/null
    stop_protection_changed=true
  fi
  timer_end step1_disable_protection "ステップ1 保護解除"

  # --- ステップ2: ELC 新 EC2 を停止 ---
  timer_start step2_stop_new
  log_info "$new_instance_id を停止します。"
  aws_json ec2 stop-instances --instance-ids "$new_instance_id" >/dev/null
  wait_until "$WAIT_INSTANCE_STATE_TIMEOUT" 15 "instance stopped: $new_instance_id" instance_state_is "$new_instance_id" "stopped"
  timer_end step2_stop_new "ステップ2 ELC新EC2停止"

  # --- ステップ3: 現物の全 EBS/ENI を DeleteOnTermination=false にして実測確認 ---
  timer_start step3_dot_false
  current_desc=$(aws_json ec2 describe-instances --instance-ids "$new_instance_id")
  jq -r '.Reservations[0].Instances[0].BlockDeviceMappings[] | select(.Ebs != null) | .DeviceName' <<<"$current_desc" |
  while IFS= read -r device_name; do
    modify_volume_dot "$new_instance_id" "$device_name" false
  done
  jq -r '.Reservations[0].Instances[0].NetworkInterfaces[] | [.NetworkInterfaceId, .Attachment.AttachmentId] | @tsv' <<<"$current_desc" |
  while IFS=$'\t' read -r eni_id attachment_id; do
    modify_eni_dot "$eni_id" "$attachment_id" false
  done
  current_desc=$(aws_json ec2 describe-instances --instance-ids "$new_instance_id")
  jq -e '[.Reservations[0].Instances[0].BlockDeviceMappings[].Ebs.DeleteOnTermination] | all(. == false)' \
    <<<"$current_desc" >/dev/null || die "EBS の DeleteOnTermination=false 化に失敗。terminate を中止します。"
  jq -e '[.Reservations[0].Instances[0].NetworkInterfaces[].Attachment.DeleteOnTermination] | all(. == false)' \
    <<<"$current_desc" >/dev/null || die "ENI の DeleteOnTermination=false 化に失敗。terminate を中止します。IP 喪失を防ぐためです。"
  local eni_desc
  eni_desc=$(aws_json ec2 describe-network-interfaces --network-interface-ids "${eni_ids[@]}")
  jq -e '[.NetworkInterfaces[].Attachment.DeleteOnTermination] | all(. == false)' <<<"$eni_desc" >/dev/null \
    || die "ENI の DeleteOnTermination=false 化を ENI 実測で確認できません。terminate を中止します。"
  timer_end step3_dot_false "ステップ3 DeleteOnTermination=falseと確認"

  # --- ステップ4: 現物の全 EBS をデタッチして available を待機 ---
  timer_start step4_detach_ebs
  mapfile -t current_volume_ids < <(jq -r '.Reservations[0].Instances[0].BlockDeviceMappings[]?.Ebs.VolumeId // empty' <<<"$current_desc")
  printf '%s\n' "${current_volume_ids[@]}" > "$dir/rollback_preserved_volume_ids.txt"
  log_info "ELC 新 EC2 の全 EBS ボリュームをデタッチします。"
  for volume_id in "${current_volume_ids[@]}"; do
    aws_json ec2 detach-volume --volume-id "$volume_id" --instance-id "$new_instance_id" >/dev/null
  done
  for volume_id in "${current_volume_ids[@]}"; do
    wait_until "$WAIT_VOLUME_STATE_TIMEOUT" 10 "volume available: $volume_id" volume_state_is "$volume_id" "available"
  done
  timer_end step4_detach_ebs "ステップ4 ELC側EBSデタッチ"

  # --- ステップ5: ELC 新 EC2 を terminate して ENI 解放を待機 ---
  timer_start step5_terminate_new
  log_info "$new_instance_id を terminate します。"
  aws_json ec2 terminate-instances --instance-ids "$new_instance_id" >/dev/null
  terminate_issued=true
  trap - ERR
  wait_until "$WAIT_INSTANCE_STATE_TIMEOUT" 15 "instance terminated: $new_instance_id" instance_state_is "$new_instance_id" "terminated"
  for eni_id in "${eni_ids[@]}"; do
    wait_until "$WAIT_ENI_AVAILABLE_TIMEOUT" 10 "eni available: $eni_id" eni_status_is "$eni_id" "available"
  done
  timer_end step5_terminate_new "ステップ5 ELC新EC2 terminate"

  # --- ステップ6: 保全 ENI を指定してバックアップ AMI から復旧 EC2 を起動 ---
  timer_start step6_run_rollback
  local ni_file tag_file placement_file metadata_file private_dns_file capacity_reservation_file user_data_file
  local copy_tag_count rollback_json rollback_instance_id
  local -a run_args=()
  ni_file=$(tmp_json)
  tag_file=$(tmp_json)
  placement_file=$(tmp_json)
  metadata_file=$(tmp_json)
  private_dns_file=$(tmp_json)
  capacity_reservation_file=$(tmp_json)
  user_data_file=$(mktemp)
  jq '[.[] | {NetworkInterfaceId, DeviceIndex, DeleteOnTermination: false}]' "$dir/enis.json" > "$ni_file"
  copy_tag_count=$(jq '[.[] | select(.Key | startswith("aws:") | not)] | length' "$dir/tags.json")
  jq -n --slurpfile tags "$dir/tags.json" \
    '[{ResourceType:"instance", Tags: ($tags[0] | map(select(.Key | startswith("aws:") | not)))}]' > "$tag_file"
  jq '{AvailabilityZone, Tenancy} | with_entries(select(.value != null))' "$dir/placement.json" > "$placement_file"
  jq '{HttpTokens,HttpPutResponseHopLimit,HttpEndpoint,HttpProtocolIpv6,InstanceMetadataTags}
    | with_entries(select(.value != null))' "$dir/metadata_options.json" > "$metadata_file"
  jq 'if . == null then {} else with_entries(select(.value != null)) end' \
    "$dir/private_dns_name_options.json" > "$private_dns_file"
  jq 'if . == null then {} else with_entries(select(.value != null)) end' \
    "$dir/capacity_reservation.json" > "$capacity_reservation_file"

  run_args=(ec2 run-instances
    --image-id "$backup_ami_id"
    --client-token "switch-ec2-rollback-${old_instance_id}"
    --instance-type "$(jq -r '.' "$dir/instance_type.json")"
    --count 1
    --network-interfaces "file://$ni_file"
    --placement "file://$placement_file"
    --metadata-options "file://$metadata_file"
    --instance-initiated-shutdown-behavior "$(jq -r . "$dir/shutdown_behavior.json")")
  if (( copy_tag_count > 0 )); then
    run_args+=(--tag-specifications "file://$tag_file")
  fi
  if [[ "$(jq -r '.' "$dir/key_name.json")" != "null" ]]; then
    run_args+=(--key-name "$(jq -r '.' "$dir/key_name.json")")
  fi
  if [[ "$(jq -r '.Arn // empty' "$dir/iam_instance_profile.json")" != "" ]]; then
    run_args+=(--iam-instance-profile "Arn=$(jq -r '.Arn' "$dir/iam_instance_profile.json")")
  fi
  if [[ "$(jq -r '.' "$dir/ebs_optimized.json")" == "true" ]]; then
    run_args+=(--ebs-optimized)
  fi
  if [[ "$(jq -r '.State // "disabled"' "$dir/monitoring.json")" == "enabled" ]]; then
    run_args+=(--monitoring Enabled=true)
  else
    run_args+=(--monitoring Enabled=false)
  fi
  if [[ "$(jq -r '.' "$dir/disable_api_termination.json")" == "true" ]]; then
    run_args+=(--disable-api-termination)
  fi
  if [[ "$(jq -r '.CpuCredits // empty' "$dir/credit_specification.json")" != "" ]]; then
    run_args+=(--credit-specification "CpuCredits=$(jq -r '.CpuCredits' "$dir/credit_specification.json")")
  fi
  if [[ "$(jq -r '.AutoRecovery // empty' "$dir/maintenance_options.json")" != "" ]]; then
    run_args+=(--maintenance-options "AutoRecovery=$(jq -r '.AutoRecovery' "$dir/maintenance_options.json")")
  fi
  if [[ "$(jq 'length' "$private_dns_file")" != "0" ]]; then
    run_args+=(--private-dns-name-options "file://$private_dns_file")
  fi
  if [[ "$(jq -r '.CoreCount // empty' "$dir/cpu_options.json")" != "" ]]; then
    run_args+=(--cpu-options "CoreCount=$(jq -r '.CoreCount' "$dir/cpu_options.json"),ThreadsPerCore=$(jq -r '.ThreadsPerCore' "$dir/cpu_options.json")")
  fi
  if [[ "$(jq 'length' "$capacity_reservation_file")" != "0" ]]; then
    run_args+=(--capacity-reservation-specification "file://$capacity_reservation_file")
  fi
  if [[ "$COPY_USER_DATA" == "true" && -s "$dir/user_data.b64.txt" ]]; then
    base64 -d "$dir/user_data.b64.txt" > "$user_data_file"
    run_args+=(--user-data "fileb://$user_data_file")
  fi
  log_info "復旧 EC2 をバックアップAMI $backup_ami_id から起動します。"
  if ! rollback_json=$(aws_json "${run_args[@]}"); then
    rm -f "$ni_file" "$tag_file" "$placement_file" "$metadata_file" "$private_dns_file" "$capacity_reservation_file" "$user_data_file"
    die "復旧 EC2 の起動に失敗しました: old=$old_instance_id"
  fi
  rm -f "$ni_file" "$tag_file" "$placement_file" "$metadata_file" "$private_dns_file" "$capacity_reservation_file" "$user_data_file"
  printf '%s\n' "$rollback_json" > "$dir/rollback_instance_run.json"
  rollback_instance_id=$(jq -r '.Instances[0].InstanceId' <<<"$rollback_json")
  printf '%s\n' "$rollback_instance_id" > "$dir/rollback_instance_id.txt"
  log_info "復旧 EC2: $rollback_instance_id"
  timer_end step6_run_rollback "ステップ6 復旧EC2起動"

  # --- ステップ7: 復旧 EC2 の running と 2/2 ステータス OK を待機 ---
  timer_start step7_wait_rollback
  wait_until "$WAIT_INSTANCE_STATE_TIMEOUT" 15 "rollback instance running: $rollback_instance_id" instance_state_is "$rollback_instance_id" "running"
  wait_until "$WAIT_STATUS_OK_TIMEOUT" 20 "rollback instance status ok: $rollback_instance_id" status_ok "$rollback_instance_id"
  timer_end step7_wait_rollback "ステップ7 復旧EC2起動確認"

  # --- ステップ8: 復旧 EC2 の EBS/ENI DeleteOnTermination を切替前の値へ復元 ---
  timer_start step8_restore_dot
  log_info "復旧 EC2 の DeleteOnTermination を切替前の値に復元します。"
  jq -c '.[]' "$dir/block_devices.json" |
  while IFS= read -r mapping; do
    local device dot
    device=$(jq -r '.DeviceName' <<<"$mapping")
    dot=$(jq -r '.DeleteOnTermination' <<<"$mapping")
    modify_volume_dot "$rollback_instance_id" "$device" "$dot"
  done
  current_desc=$(aws_json ec2 describe-instances --instance-ids "$rollback_instance_id")
  jq -c '.Reservations[0].Instances[0].NetworkInterfaces[] | {NetworkInterfaceId, AttachmentId: .Attachment.AttachmentId}' <<<"$current_desc" |
  while IFS= read -r current_eni; do
    local eni_id attachment_id dot
    eni_id=$(jq -r '.NetworkInterfaceId' <<<"$current_eni")
    attachment_id=$(jq -r '.AttachmentId' <<<"$current_eni")
    dot=$(jq -r --arg eni "$eni_id" '.[] | select(.NetworkInterfaceId==$eni) | .DeleteOnTermination' "$dir/enis.json")
    modify_eni_dot "$eni_id" "$attachment_id" "$dot"
  done
  timer_end step8_restore_dot "ステップ8 DeleteOnTermination復元"

  # --- ステップ9: 復旧 EC2 の停止保護を切替前の値へ復元 ---
  timer_start step9_restore_stop_protection
  if [[ "$(jq -r '.' "$dir/disable_api_stop.json")" == "true" ]]; then
    log_info "$rollback_instance_id の停止保護を元の値に復元します。"
    aws_json ec2 modify-instance-attribute --instance-id "$rollback_instance_id" --disable-api-stop >/dev/null
  fi
  timer_end step9_restore_stop_protection "ステップ9 停止保護復元"

  # --- ステップ10: 保全した既知 EBS へ識別・警告タグを付与 ---
  timer_start step10_tag_preserved
  name=$(instance_name_for_file "$dir/instance.json" "$old_instance_id")
  for volume_id in "${known_volume_ids[@]}"; do
    aws_json ec2 create-tags --resources "$volume_id" --tags \
      "Key=Name,Value=${name}-preserved-elc-volume" \
      "Key=Purpose,Value=${ROLLBACK_PRESERVED_PURPOSE}" \
      "Key=DeleteAfterVerification,Value=true" \
      "Key=Warning,Value=DO-NOT-ATTACH-DUPLICATE-FS-UUID" \
      "Key=SourceOldInstanceId,Value=${old_instance_id}" \
      "Key=RolledBackFromInstanceId,Value=${new_instance_id}" \
      "Key=RollbackInstanceId,Value=${rollback_instance_id}" >/dev/null
  done
  timer_end step10_tag_preserved "ステップ10 保全EBSタグ付け"

  # --- ステップ11: 復旧 EC2 の最終 describe を保存して所要時間を表示 ---
  timer_start step11_save_result
  aws_json ec2 describe-instances --instance-ids "$rollback_instance_id" > "$dir/rollback_instance_after.json"
  timer_end step11_save_result "ステップ11 最終状態保存"
  log_info "切り戻し完了: old=$old_instance_id elc=$new_instance_id rollback=$rollback_instance_id"
  timings_summary "$TIMINGS_FILE" "切り戻し所要時間 内訳: $new_instance_id -> $rollback_instance_id"
}

# 目的: --target 指定の各対象へ逐次処理を適用し、成功・失敗サマリを返す。
# 引数: なし（グローバル ROLLBACK_TARGETS を参照）。
# 出力: stderr に成功・失敗サマリ、失敗が1台以上あれば終了コード1。
run_selected_targets() {
  local -
  local target rc start_epoch elapsed summary_rc=0
  local run_start
  local -a successes=() failures=()
  local -A seen=()
  for target in "${ROLLBACK_TARGETS[@]}"; do
    if [[ -n "${seen[$target]:-}" ]]; then
      die "--target に重複したインスタンスIDがあります: $target"
      return 1
    fi
    seen[$target]=1
  done
  run_start=$(date +%s)
  for target in "${ROLLBACK_TARGETS[@]}"; do
    log_info "処理開始: $target"
    start_epoch=$(date +%s)
    set +e
    ( set -eEuo pipefail; setup_target_logging "$target"; process_target "$target" )
    rc=$?
    set -e
    elapsed=$(( $(date +%s) - start_epoch ))
    if [[ "$rc" == "0" ]]; then
      log_info "処理成功: $target (${elapsed}s)"
      successes+=("$target")
    else
      log_error "処理失敗: $target (${elapsed}s)"
      failures+=("$target")
    fi
  done
  report_targets_summary "$(( $(date +%s) - run_start ))" "${successes[*]:-}" "${failures[*]:-}" || summary_rc=$?
  return "$summary_rc"
}

# 目的: 引数・設定を読み込み、指定対象または targets.txt の全対象へ切り戻し処理を適用する。
# 引数: --yes, --target <instance-id>, --help。
# 出力: 対象ごとの復旧 EC2 状態ファイル。
main() {
  parse_rollback_flags "$@"
  load_config
  if ((${#ROLLBACK_TARGETS[@]} > 0)); then
    run_selected_targets
  else
    run_targets process_target
  fi
}

main "$@"
