#!/usr/bin/env bash
set -euo pipefail

# 切り戻し後検証スクリプト。
# 役割: 復旧 EC2 が旧 EC2 のベースラインと一致し、UsageOperation が元の PAYG 値へ戻ったことを確認する。
# 前提: 01_prepare.sh と 05_rollback.sh 済み。各対象の prepare 状態ファイルと rollback_instance_id.txt が存在すること。
# 生成する状態ファイル: verify_rollback_instance.json, verify_rollback_enis.normalized.json,
# verify_rollback_volumes.json, verify_rollback_tags.normalized.json,
# after_rollback_instance.json, after_rollback_volumes.json, after_rollback_enis.json,
# 06_verify_rollback.log, timings_06_verify_rollback.tsv。
# 実行方式: targets.txt を上から順に1台ずつ検証する逐次方式。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# 05_rollback.sh の同名変数と同じ値を保つこと。
ROLLBACK_PRESERVED_PURPOSE="switch-ec2-rollback-preserved"
verify_failed=0

# 目的: 検証成功を標準出力へ表示する。
# 引数: メッセージ。
# 出力: stdout。
report_pass() { printf '[PASS] %s\n' "$*"; }

# 目的: 検証失敗を標準出力へ表示し、対象の失敗フラグを立てる。
# 引数: メッセージ。
# 出力: stdout。
report_fail() { printf '[FAIL] %s\n' "$*"; verify_failed=1; }

# 目的: 判定ではない補足情報を標準出力へ表示する。
# 引数: メッセージ。
# 出力: stdout。
report_info() { printf '[INFO] %s\n' "$*"; }

# 目的: jq でキー順を正規化した JSON 同士を比較する。
# 引数: 左 JSON ファイル, 右 JSON ファイル。
# 出力: 終了コードで一致/不一致。
json_equal() {
  local left=$1
  local right=$2
  diff -u <(jq -S . "$left") <(jq -S . "$right") >/dev/null
}

# 目的: 期待値と実測値の JSON ファイルを比較して共通形式で報告する。
# 引数: 期待値ファイル, 実測値ファイル, 成功メッセージ, 失敗メッセージ。
# 出力: 検証レポート。失敗時は verify_failed を更新する。
compare_json_files() {
  local expected=$1
  local actual=$2
  local pass_message=$3
  local fail_message=$4
  if json_equal "$expected" "$actual"; then
    report_pass "$pass_message"
  else
    report_fail "$fail_message"
    diff -u "$expected" "$actual" || true
  fi
}

# 目的: 1台の切り戻し結果を旧 EC2 ベースラインと比較する。
# 引数: 旧 EC2 インスタンスID。
# 出力: 検証レポート、verify_rollback_* と after_rollback_* 状態ファイル。
process_target() {
  local old_instance_id=$1
  local dir rollback_instance_id rollback_desc rollback_file backup_ami_id backup_ami_json
  local volumes_desc enis_desc old_value new_value attribute_json
  local -a volume_ids=() eni_ids=() preserved_volume_ids=()
  verify_failed=0
  dir=$(state_dir "$old_instance_id")
  local required_files=(
    instance.json enis.json block_devices.json before_instance.json before_volumes.json before_enis.json
    tags.json instance_type.json
    usage_operation.json metadata_options.json iam_instance_profile.json ebs_optimized.json monitoring.json
    key_name.json disable_api_termination.json disable_api_stop.json shutdown_behavior.json
    maintenance_options.json private_dns_name_options.json cpu_options.json capacity_reservation.json
    boot_mode.json user_data.b64.txt backup_ami_id.txt new_instance_id.txt rollback_instance_id.txt
    rollback_preserved_volume_ids.txt
  )
  local file
  for file in "${required_files[@]}"; do
    need_file "$dir/$file"
  done

  rollback_instance_id=$(<"$dir/rollback_instance_id.txt")
  backup_ami_id=$(<"$dir/backup_ami_id.txt")
  rollback_desc=$(aws_json ec2 describe-instances --instance-ids "$rollback_instance_id")
  [[ "$(jq '.Reservations | length' <<<"$rollback_desc")" == "1" ]] \
    || die "復旧 EC2 が見つかりません: $rollback_instance_id"
  rollback_file="$dir/verify_rollback_instance.json"
  printf '%s\n' "$rollback_desc" > "$rollback_file"
  backup_ami_json=$(aws_json ec2 describe-images --image-ids "$backup_ami_id")
  printf '%s\n' "$backup_ami_json" > "$dir/verify_rollback_backup_ami.json"
  mapfile -t volume_ids < <(jq -r '.Reservations[0].Instances[0].BlockDeviceMappings[]?.Ebs.VolumeId // empty' <<<"$rollback_desc")
  mapfile -t eni_ids < <(jq -r '.Reservations[0].Instances[0].NetworkInterfaces[]?.NetworkInterfaceId // empty' <<<"$rollback_desc")
  if ((${#volume_ids[@]} > 0)); then
    volumes_desc=$(aws_json ec2 describe-volumes --volume-ids "${volume_ids[@]}")
  else
    volumes_desc='{"Volumes":[]}'
  fi
  if ((${#eni_ids[@]} > 0)); then
    enis_desc=$(aws_json ec2 describe-network-interfaces --network-interface-ids "${eni_ids[@]}")
  else
    enis_desc='{"NetworkInterfaces":[]}'
  fi
  printf '%s\n' "$volumes_desc" > "$dir/verify_rollback_volumes.json"

  # --- ステップ0: 切り戻し前後の手動 diff 用に describe 全文を保存 ---
  timer_start step0_save_describe
  printf '%s\n' "$rollback_desc" | normalize_describe_json instances > "$dir/after_rollback_instance.json"
  printf '%s\n' "$volumes_desc" | normalize_describe_json volumes > "$dir/after_rollback_volumes.json"
  printf '%s\n' "$enis_desc" | normalize_describe_json enis > "$dir/after_rollback_enis.json"
  timer_end step0_save_describe "ステップ0 describe保存"

  printf '\n=== %s -> %s 切り戻し検証 ===\n' "$old_instance_id" "$rollback_instance_id"

  # --- ステップ1: プライマリプライベート IP と ENI 構成を確認 ---
  timer_start step1_verify_network
  local old_ip new_ip
  old_ip=$(jq -r 'first(.[] | select(.DeviceIndex == 0) | .PrimaryPrivateIpAddress) // empty' "$dir/enis.json")
  new_ip=$(jq -r '.Reservations[0].Instances[0].PrivateIpAddress // empty' "$rollback_file")
  if [[ -n "$old_ip" && "$old_ip" == "$new_ip" ]]; then
    report_pass "プライマリプライベートIP一致: $old_ip"
  else
    report_fail "プライマリプライベートIP不一致: old=${old_ip:-空} rollback=${new_ip:-空}"
  fi
  jq '[.[] | {DeviceIndex, NetworkInterfaceId, DeleteOnTermination}] | sort_by(.DeviceIndex)' \
    "$dir/enis.json" > "$dir/verify_rollback_expected_enis.normalized.json"
  jq '[.Reservations[0].Instances[0].NetworkInterfaces[]
      | {DeviceIndex: .Attachment.DeviceIndex, NetworkInterfaceId, DeleteOnTermination: .Attachment.DeleteOnTermination}]
      | sort_by(.DeviceIndex)' "$rollback_file" > "$dir/verify_rollback_enis.normalized.json"
  compare_json_files "$dir/verify_rollback_expected_enis.normalized.json" "$dir/verify_rollback_enis.normalized.json" \
    "全ENI ID/DeviceIndex/DeleteOnTermination 一致" "ENI 構成不一致。差分:"
  timer_end step1_verify_network "ステップ1 IP・ENI検証"

  # --- ステップ2: ボリュームのデバイス名・DOT・SnapshotId と属性を確認 ---
  timer_start step2_verify_volumes
  jq -n --slurpfile bd "$dir/block_devices.json" --slurpfile ami "$dir/verify_rollback_backup_ami.json" '
    [ $bd[0][] as $d
      | {DeviceName: $d.DeviceName,
         DeleteOnTermination: $d.DeleteOnTermination,
         SnapshotId: ($ami[0].Images[0].BlockDeviceMappings[]
                      | select(.DeviceName == $d.DeviceName) | .Ebs.SnapshotId)} ]
    | sort_by(.DeviceName)' > "$dir/verify_rollback_expected_volumes.json"
  jq '[.Volumes[]
      | {DeviceName: .Attachments[0].Device, VolumeId, SnapshotId, Size, VolumeType,
         Iops, Throughput, Encrypted,
         DeleteOnTermination: .Attachments[0].DeleteOnTermination}]
      | sort_by(.DeviceName)' <<<"$volumes_desc" > "$dir/verify_rollback_actual_volumes.json"
  jq '[.[] | {DeviceName, DeleteOnTermination, SnapshotId}] | sort_by(.DeviceName)' \
    "$dir/verify_rollback_actual_volumes.json" > "$dir/verify_rollback_actual_volume_origins.json"
  compare_json_files "$dir/verify_rollback_expected_volumes.json" "$dir/verify_rollback_actual_volume_origins.json" \
    "全ボリュームのデバイス名/DeleteOnTermination/SnapshotId 一致" "ボリュームのスナップショット由来または構成が不一致。差分:"
  report_info "復旧ボリュームはバックアップAMIのスナップショットから新規作成されるため、旧 VolumeId とは一致しません（設計どおり）"

  jq '[.Volumes[]
      | {DeviceName: .Attachments[0].Device, Size, VolumeType, Iops, Throughput, Encrypted}]
      | sort_by(.DeviceName)' "$dir/before_volumes.json" > "$dir/verify_rollback_expected_volume_attributes.json"
  jq '[.[] | {DeviceName, Size, VolumeType, Iops, Throughput, Encrypted}] | sort_by(.DeviceName)' \
    "$dir/verify_rollback_actual_volumes.json" > "$dir/verify_rollback_actual_volume_attributes.json"
  compare_json_files "$dir/verify_rollback_expected_volume_attributes.json" "$dir/verify_rollback_actual_volume_attributes.json" \
    "全ボリュームのサイズ/タイプ/IOPS/Throughput/暗号化属性一致" "ボリューム属性不一致。差分:"
  timer_end step2_verify_volumes "ステップ2 ボリューム検証"

  # --- ステップ3: UsageOperation・タグ・インスタンスタイプを確認 ---
  timer_start step3_verify_identity
  local old_usage new_usage
  old_usage=$(jq -r '. // empty' "$dir/usage_operation.json")
  new_usage=$(jq -r '.Reservations[0].Instances[0].UsageOperation // empty' "$rollback_file")
  if [[ -z "$new_usage" ]]; then
    report_fail "UsageOperation が復旧 EC2 で空です"
  elif [[ "$old_usage" == "$new_usage" ]]; then
    report_pass "UsageOperation が元の値に戻りました: $new_usage"
  else
    report_fail "UsageOperation が元の値に戻っていません: expected=$old_usage actual=$new_usage"
  fi
  jq 'map(select(.Key | startswith("aws:") | not)) | sort_by(.Key, .Value)' \
    "$dir/tags.json" > "$dir/verify_rollback_expected_tags.normalized.json"
  jq '[.Reservations[0].Instances[0].Tags[]? | select(.Key | startswith("aws:") | not)] | sort_by(.Key, .Value)' \
    "$rollback_file" > "$dir/verify_rollback_tags.normalized.json"
  compare_json_files "$dir/verify_rollback_expected_tags.normalized.json" "$dir/verify_rollback_tags.normalized.json" \
    "タグ一致（aws: 予約タグ除く）" "タグ不一致。差分:"
  old_value=$(jq -r '.' "$dir/instance_type.json")
  new_value=$(jq -r '.Reservations[0].Instances[0].InstanceType // empty' "$rollback_file")
  [[ "$old_value" == "$new_value" ]] && report_pass "インスタンスタイプ一致: $new_value" \
    || report_fail "インスタンスタイプ不一致: old=$old_value rollback=${new_value:-空}"
  timer_end step3_verify_identity "ステップ3 課金・タグ・タイプ検証"

  # --- ステップ4: 起動属性と保護設定を確認 ---
  timer_start step4_verify_attributes
  local old_term new_term old_stop new_stop
  jq '{HttpTokens,HttpPutResponseHopLimit,HttpEndpoint,HttpProtocolIpv6,InstanceMetadataTags}' \
    "$dir/metadata_options.json" > "$dir/verify_rollback_expected_metadata.json"
  jq '.Reservations[0].Instances[0].MetadataOptions
      | {HttpTokens,HttpPutResponseHopLimit,HttpEndpoint,HttpProtocolIpv6,InstanceMetadataTags}' \
    "$rollback_file" > "$dir/verify_rollback_actual_metadata.json"
  compare_json_files "$dir/verify_rollback_expected_metadata.json" "$dir/verify_rollback_actual_metadata.json" \
    "MetadataOptions 一致" "MetadataOptions 不一致。差分:"
  old_value=$(jq -r '.Arn // empty' "$dir/iam_instance_profile.json")
  new_value=$(jq -r '.Reservations[0].Instances[0].IamInstanceProfile.Arn // empty' "$rollback_file")
  [[ "$old_value" == "$new_value" ]] && report_pass "IamInstanceProfile.Arn 一致" \
    || report_fail "IamInstanceProfile.Arn 不一致: old=${old_value:-なし} rollback=${new_value:-なし}"
  old_value=$(jq -r '.' "$dir/ebs_optimized.json")
  new_value=$(jq -r '.Reservations[0].Instances[0].EbsOptimized // false' "$rollback_file")
  [[ "$old_value" == "$new_value" ]] && report_pass "EbsOptimized 一致: $new_value" \
    || report_fail "EbsOptimized 不一致: old=$old_value rollback=$new_value"
  old_value=$(jq -r '.State // empty' "$dir/monitoring.json")
  new_value=$(jq -r '.Reservations[0].Instances[0].Monitoring.State // empty' "$rollback_file")
  [[ "$old_value" == "$new_value" ]] && report_pass "Monitoring.State 一致: $new_value" \
    || report_fail "Monitoring.State 不一致: old=${old_value:-空} rollback=${new_value:-空}"
  old_value=$(jq -r '. // empty' "$dir/key_name.json")
  new_value=$(jq -r '.Reservations[0].Instances[0].KeyName // empty' "$rollback_file")
  [[ "$old_value" == "$new_value" ]] && report_pass "KeyName 一致: ${new_value:-なし}" \
    || report_fail "KeyName 不一致: old=${old_value:-なし} rollback=${new_value:-なし}"

  old_term=$(jq -r '.' "$dir/disable_api_termination.json")
  attribute_json=$(aws_json ec2 describe-instance-attribute --instance-id "$rollback_instance_id" --attribute disableApiTermination)
  new_term=$(jq -r '.DisableApiTermination.Value // false' <<<"$attribute_json")
  [[ "$old_term" == "$new_term" ]] && report_pass "終了保護一致: $new_term" \
    || report_fail "終了保護不一致: old=$old_term rollback=$new_term"
  old_stop=$(jq -r '.' "$dir/disable_api_stop.json")
  attribute_json=$(aws_json ec2 describe-instance-attribute --instance-id "$rollback_instance_id" --attribute disableApiStop)
  new_stop=$(jq -r '.DisableApiStop.Value // false' <<<"$attribute_json")
  [[ "$old_stop" == "$new_stop" ]] && report_pass "停止保護一致: $new_stop" \
    || report_fail "停止保護不一致: old=$old_stop rollback=$new_stop"
  old_value=$(jq -r '.' "$dir/shutdown_behavior.json")
  attribute_json=$(aws_json ec2 describe-instance-attribute --instance-id "$rollback_instance_id" --attribute instanceInitiatedShutdownBehavior)
  new_value=$(jq -r '.InstanceInitiatedShutdownBehavior.Value // "stop"' <<<"$attribute_json")
  [[ "$old_value" == "$new_value" ]] && report_pass "InstanceInitiatedShutdownBehavior 一致: $new_value" \
    || report_fail "InstanceInitiatedShutdownBehavior 不一致: old=$old_value rollback=$new_value"

  old_value=$(jq -r '.AutoRecovery // empty' "$dir/maintenance_options.json")
  if [[ -z "$old_value" ]]; then
    report_info "MaintenanceOptions.AutoRecovery は保存値が null のため検証をスキップ"
  else
    new_value=$(jq -r '.Reservations[0].Instances[0].MaintenanceOptions.AutoRecovery // empty' "$rollback_file")
    [[ "$old_value" == "$new_value" ]] && report_pass "MaintenanceOptions.AutoRecovery 一致: $new_value" \
      || report_fail "MaintenanceOptions.AutoRecovery 不一致: old=$old_value rollback=${new_value:-空}"
  fi
  if [[ "$(jq -r 'type' "$dir/private_dns_name_options.json")" == "null" ]]; then
    report_info "PrivateDnsNameOptions は保存値が null のため検証をスキップ"
  else
    old_value=$(jq -cS . "$dir/private_dns_name_options.json")
    new_value=$(jq -cS '.Reservations[0].Instances[0].PrivateDnsNameOptions // null' "$rollback_file")
    [[ "$old_value" == "$new_value" ]] && report_pass "PrivateDnsNameOptions 一致" \
      || report_fail "PrivateDnsNameOptions 不一致: old=$old_value rollback=$new_value"
  fi
  if [[ "$(jq -r 'type' "$dir/cpu_options.json")" == "null" ]]; then
    report_info "CpuOptions は保存値が null のため検証をスキップ"
  else
    old_value=$(jq -cS . "$dir/cpu_options.json")
    new_value=$(jq -cS '.Reservations[0].Instances[0].CpuOptions | {CoreCount, ThreadsPerCore}' "$rollback_file")
    [[ "$old_value" == "$new_value" ]] && report_pass "CpuOptions 一致: $new_value" \
      || report_fail "CpuOptions 不一致: old=$old_value rollback=$new_value"
  fi
  if [[ "$(jq -r 'type' "$dir/capacity_reservation.json")" == "null" ]]; then
    report_info "CapacityReservationSpecification は保存値が null のため検証をスキップ"
  else
    old_value=$(jq -cS . "$dir/capacity_reservation.json")
    new_value=$(jq -cS '.Reservations[0].Instances[0].CapacityReservationSpecification // null' "$rollback_file")
    [[ "$old_value" == "$new_value" ]] && report_pass "CapacityReservationSpecification 一致" \
      || report_fail "CapacityReservationSpecification 不一致: old=$old_value rollback=$new_value"
  fi
  old_value=$(jq -r '.BootMode // empty' "$dir/boot_mode.json")
  new_value=$(jq -r '.Reservations[0].Instances[0].BootMode // empty' "$rollback_file")
  [[ "$old_value" == "$new_value" ]] && report_pass "BootMode 一致: ${new_value:-未設定}" \
    || report_fail "BootMode 不一致: old=${old_value:-未設定} rollback=${new_value:-未設定}"
  timer_end step4_verify_attributes "ステップ4 起動属性・保護検証"

  # --- ステップ5: 保全 EBS の残置と ELC 新 EC2 の消滅を確認 ---
  timer_start step5_verify_preserved
  mapfile -t preserved_volume_ids < "$dir/rollback_preserved_volume_ids.txt"
  if ((${#preserved_volume_ids[@]} == 0)); then
    report_fail "保全 EBS ID が記録されていません"
  else
    local preserved_desc extra_preserved
    preserved_desc=$(aws_json ec2 describe-volumes --volume-ids "${preserved_volume_ids[@]}")
    if jq -e --argjson count "${#preserved_volume_ids[@]}" \
      '.Volumes | length == $count and all(.State == "available")' <<<"$preserved_desc" >/dev/null; then
      report_pass "保全 EBS が全件 available"
    else
      report_fail "保全 EBS が全件 available ではありません"
    fi
    # 05_rollback.sh は block_devices.json に記録済みの既知 EBS だけにタグを付ける。
    # ROLLBACK_ALLOW_EXTRA_VOLUMES=true で保全した追加 EBS は意図的にタグ無しのため、判定を分ける。
    if jq -e --arg purpose "$ROLLBACK_PRESERVED_PURPOSE" --slurpfile known "$dir/block_devices.json" '
      [.Volumes[] | select(.VolumeId as $id | any($known[0][]; .VolumeId == $id))]
      | length > 0 and all(any(.Tags[]?; .Key == "Purpose" and .Value == $purpose))' <<<"$preserved_desc" >/dev/null; then
      report_pass "既知の保全 EBS に Purpose=$ROLLBACK_PRESERVED_PURPOSE が付与済み"
    else
      report_fail "既知の保全 EBS の Purpose タグが不一致"
    fi
    extra_preserved=$(jq -r --slurpfile known "$dir/block_devices.json" '
      [.Volumes[] | select(.VolumeId as $id | any($known[0][]; .VolumeId == $id) | not) | .VolumeId] | join(" ")' <<<"$preserved_desc")
    if [[ -n "$extra_preserved" ]]; then
      report_info "03_switch.sh 後に追加された EBS を保全しています（タグ無し・手動で扱うこと）: $extra_preserved"
    fi
  fi
  local elc_instance_id elc_desc elc_state
  elc_instance_id=$(<"$dir/new_instance_id.txt")
  elc_desc=$(aws_json ec2 describe-instances --instance-ids "$elc_instance_id")
  elc_state=$(jq -r '.Reservations[0].Instances[0].State.Name // empty' <<<"$elc_desc")
  [[ "$elc_state" == "terminated" ]] && report_pass "ELC 新 EC2 は terminated: $elc_instance_id" \
    || report_fail "ELC 新 EC2 が terminated ではありません: instance=$elc_instance_id state=${elc_state:-空}"
  timer_end step5_verify_preserved "ステップ5 残置・消滅検証"

  # --- ステップ6: UserData・2/2 ステータス・保全 ENI のアタッチ状態を確認 ---
  timer_start step6_verify_runtime
  if [[ "$COPY_USER_DATA" == "true" ]]; then
    old_value=$(<"$dir/user_data.b64.txt")
    attribute_json=$(aws_json ec2 describe-instance-attribute --instance-id "$rollback_instance_id" --attribute userData)
    new_value=$(jq -r '.UserData.Value // empty' <<<"$attribute_json")
    [[ "$old_value" == "$new_value" ]] && report_pass "UserData 一致" || report_fail "UserData 不一致"
  elif [[ -s "$dir/user_data.b64.txt" ]]; then
    report_info "UserData は引き継いでいない（COPY_USER_DATA=false）"
  fi
  if status_ok "$rollback_instance_id"; then
    report_pass "復旧 EC2 の 2/2 ステータスチェック OK"
  else
    report_fail "復旧 EC2 の 2/2 ステータスチェックが OK ではありません"
  fi
  jq '[.[] | {NetworkInterfaceId}] | sort_by(.NetworkInterfaceId)' "$dir/enis.json" > "$dir/verify_rollback_expected_eni_ids.json"
  jq --arg instance "$rollback_instance_id" '
    [.NetworkInterfaces[] | select(.Status == "in-use" and .Attachment.InstanceId == $instance) | {NetworkInterfaceId}]
    | sort_by(.NetworkInterfaceId)' <<<"$enis_desc" > "$dir/verify_rollback_attached_eni_ids.json"
  compare_json_files "$dir/verify_rollback_expected_eni_ids.json" "$dir/verify_rollback_attached_eni_ids.json" \
    "保全 ENI は全件復旧 EC2 にアタッチ済み（孤児 ENI なし）" "保全 ENI に未アタッチまたは孤児があります。差分:"
  timer_end step6_verify_runtime "ステップ6 実行状態検証"

  # --- ステップ7: 手動 diff の案内 ---
  timer_start step7_manual_guidance
  report_info "切り戻しでデータはバックアップAMI取得時点まで巻き戻ります。OS内の状態確認は別途の運用手順に従ってください"
  report_info "切り戻し前後の describe 全文の手動 diff:"
  report_info "  diff -u $dir/before_instance.json $dir/after_rollback_instance.json"
  report_info "  diff -u $dir/before_volumes.json $dir/after_rollback_volumes.json"
  report_info "  diff -u $dir/before_enis.json $dir/after_rollback_enis.json"
  report_info "想定差分は README.md の「切り戻し前後 describe の想定 diff」を参照してください"
  timer_end step7_manual_guidance "ステップ7 手動確認案内"

  # --- ステップ8: 対象単位の検証サマリ ---
  timer_start step8_summary
  timer_end step8_summary "ステップ8 検証サマリ"
  timings_summary "$TIMINGS_FILE" "切り戻し検証所要時間 内訳: $old_instance_id -> $rollback_instance_id"
  if [[ "$verify_failed" == "0" ]]; then
    printf '[SUMMARY] %s -> %s PASS\n' "$old_instance_id" "$rollback_instance_id"
    return 0
  fi
  printf '[SUMMARY] %s -> %s FAIL\n' "$old_instance_id" "$rollback_instance_id"
  return 1
}

# 目的: 引数・設定を読み込み、targets.txt の全対象へ切り戻し検証を適用する。
# 引数: --yes, --help。
# 出力: 対象ごとの検証レポートと verify_rollback_* 状態ファイル。
main() {
  parse_yes_flag "$@"
  load_config
  run_targets process_target
}

main "$@"
