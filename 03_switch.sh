#!/usr/bin/env bash
# -E (errtrace) は必須。process_target が仕掛ける ERR トラップ（terminate 前の失敗で旧EC2の
# 終了保護・停止保護を復元する）は、errtrace が無いと関数内の失敗で発火しない。
set -eEuo pipefail

# EC2切替スクリプト。
# 役割: ELC/BYOS 系 NEW_AMI_ID から新 EC2 を起動し、旧 EC2 の全 EBS（OSディスク含む）と ENI を付け替えてライセンスだけを切り替える。
# 前提: 01_prepare.sh と 02_backup.sh 済み。各対象の prepare 状態ファイルと backup_ami_id.txt が存在すること。
# 生成する状態ファイル: new_instance_run.json, new_instance_id.txt, new_instance_before_attach.json,
# new_root_device_name.txt, discarded_root_volume_id.txt, new_instance_after_switch.json,
# 03_switch.log, timings_03_switch.tsv。
# 実行方式: 既定は targets.txt を上から順に1台ずつ処理する逐次モード。--parallel[=N] 指定時のみ並行モード。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# --parallel の値が省略された場合に、load_config 後の MAX_PARALLEL で解決するためのマーカー。
PARALLEL_DEFAULT_MARKER=default

# 目的: 03 専用のコマンドラインオプション（--yes / --parallel / --single-target-confirmed / --help）を解釈する。
# 引数: コマンドライン引数 / 出力: グローバル YES, PARALLEL_ARG, SINGLE_TARGET, CONFIRMED_UPFRONT を設定。
# 注意: parse_yes_flag は 01/02/04 と共用のため拡張せず、並行実行を持つ 03 だけ専用パーサを持つ。
parse_switch_flags() {
  YES=false
  PARALLEL_ARG=1
  SINGLE_TARGET=
  CONFIRMED_UPFRONT=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) YES=true ;;
      --single-target-confirmed)
        # 並行モードで親プロセスが1台分の子プロセスを起動するための内部オプション。
        # 対象一覧の検証と確認は親が fan-out 前に済ませている。
        [[ -n "${2:-}" ]] || die "--single-target-confirmed には対象インスタンスIDが必要です"
        SINGLE_TARGET=$2
        CONFIRMED_UPFRONT=true
        shift
        ;;
      --parallel)
        # 値は省略可。次の引数が数値ならそれを使い、無ければ MAX_PARALLEL を後で採用する。
        if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
          PARALLEL_ARG=$2
          shift
        else
          PARALLEL_ARG=$PARALLEL_DEFAULT_MARKER
        fi
        ;;
      --parallel=*)
        PARALLEL_ARG=${1#--parallel=}
        ;;
      -h|--help)
        printf 'Usage: %s [--yes] [--parallel[=N]]\n' "$0"
        printf '  --yes            確認プロンプトを省略する\n'
        printf '  --parallel[=N]   対象を最大 N 台まで並行処理する（N 省略時は config.env の MAX_PARALLEL）\n'
        printf '  --single-target-confirmed <id>\n'
        printf '                   内部用。並行モードで親プロセスが1台分の子プロセスを起動するために使う\n'
        exit 0
        ;;
      *) die "不明なオプションです: $1" ;;
    esac
    shift
  done
}

# 目的: --parallel の指定値を検証し、実際の同時実行数を決定する。
# 引数: なし（PARALLEL_ARG と MAX_PARALLEL を参照） / 出力: stdout に同時実行数。
resolve_parallel() {
  local value=$PARALLEL_ARG
  if [[ "$value" == "$PARALLEL_DEFAULT_MARKER" ]]; then
    value=$MAX_PARALLEL
  fi
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 )); then
    die "並行数は1以上の整数で指定してください: $value"
    return 1
  fi
  printf '%s\n' "$value"
}

# 目的: AWS CLI に file:// で渡す一時 JSON ファイルを作る。
# 引数: なし / 出力: stdout に一時ファイルパス。
tmp_json() {
  local file
  file=$(mktemp)
  printf '%s\n' "$file"
}

# 目的: インスタンスにアタッチ済み EBS の DeleteOnTermination を変更する。
# 引数: インスタンスID, デバイス名, true/false / 出力: EC2 属性を更新。
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
# 引数: ENI ID, Attachment ID, true/false / 出力: ENI 属性を更新。
modify_eni_dot() {
  local eni_id=$1
  local attachment_id=$2
  local delete_on_termination=$3
  aws_json ec2 modify-network-interface-attribute \
    --network-interface-id "$eni_id" \
    --attachment "AttachmentId=${attachment_id},DeleteOnTermination=${delete_on_termination}" >/dev/null
}

# 目的: terminate 発行前の失敗時に、旧 EC2 の終了保護・停止保護を元の有効値へ戻す。
# 引数: なし（process_target のローカル変数を参照） / 出力: 保護属性を更新し、復元失敗はログへ記録。
restore_old_protection_on_error() {
  local rc=$?
  trap - ERR
  set +e
  if [[ "${terminate_issued:-false}" != "true" ]]; then
    if [[ "${term_protection_changed:-false}" == "true" ]]; then
      log_warn "$old_instance_id の終了保護を復元します。"
      aws_json ec2 modify-instance-attribute --instance-id "$old_instance_id" --disable-api-termination >/dev/null \
        || log_error "$old_instance_id の終了保護を復元できませんでした。"
    fi
    if [[ "${stop_protection_changed:-false}" == "true" ]]; then
      log_warn "$old_instance_id の停止保護を復元します。"
      aws_json ec2 modify-instance-attribute --instance-id "$old_instance_id" --disable-api-stop >/dev/null \
        || log_error "$old_instance_id の停止保護を復元できませんでした。"
    fi
  fi
  set -e
  return "$rc"
}

# 目的: 破壊的操作の前に、状態ファイルと新AMI・バックアップAMIが切替・復旧に使えることを確認する。
# 引数: 旧 EC2 インスタンスID / 出力: 不備があればエラー。AWS 側は describe のみで変更しない。
preflight_target() {
  local old_instance_id=$1
  local dir file backup_ami_id backup_json backup_state backup_source
  local new_ami_json new_ami_state new_ami_arch old_arch
  dir=$(state_dir "$old_instance_id")
  local json_files=(
    instance.json enis.json block_devices.json root_device_name.json
    instance_type.json key_name.json iam_instance_profile.json ebs_optimized.json monitoring.json
    disable_api_termination.json disable_api_stop.json credit_specification.json tags.json
    placement.json metadata_options.json shutdown_behavior.json maintenance_options.json
    private_dns_name_options.json cpu_options.json capacity_reservation.json
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
  need_file "$dir/backup_ami_id.txt"
  need_file "$dir/user_data.b64.txt"
  if [[ "$COPY_USER_DATA" == "true" && -s "$dir/user_data.b64.txt" ]]; then
    base64 -d "$dir/user_data.b64.txt" >/dev/null || die "UserData の base64 を復号できません: $dir/user_data.b64.txt"
  fi

  new_ami_json=$(aws_json ec2 describe-images --image-ids "$NEW_AMI_ID")
  [[ "$(jq '.Images | length' <<<"$new_ami_json")" == "1" ]] || die "NEW_AMI_ID が見つかりません: $NEW_AMI_ID"
  new_ami_state=$(jq -r '.Images[0].State // empty' <<<"$new_ami_json")
  [[ "$new_ami_state" == "available" ]] || die "NEW_AMI_ID が available ではありません: $NEW_AMI_ID state=$new_ami_state"
  new_ami_arch=$(jq -r '.Images[0].Architecture // empty' <<<"$new_ami_json")
  old_arch=$(jq -r '.Reservations[0].Instances[0].Architecture // empty' "$dir/instance.json")
  [[ "$new_ami_arch" == "$old_arch" ]] || die "NEW_AMI_ID のアーキテクチャ不一致: instance=$old_arch ami=$new_ami_arch"

  backup_ami_id=$(<"$dir/backup_ami_id.txt")
  backup_json=$(aws_json ec2 describe-images --image-ids "$backup_ami_id")
  backup_state=$(jq -r '.Images[0].State // empty' <<<"$backup_json")
  [[ "$backup_state" == "available" ]] || die "バックアップAMIが available ではありません: $backup_ami_id state=$backup_state"
  backup_source=$(jq -r 'first(.Images[0].Tags[]? | select(.Key == "SourceInstanceId") | .Value) // empty' <<<"$backup_json")
  [[ "$backup_source" == "$old_instance_id" ]] || die "バックアップAMIの SourceInstanceId が対象と一致しません: ami=$backup_ami_id expected=$old_instance_id actual=${backup_source:-空}"
}

# 目的: 1台の旧 EC2 を新 AMI 起動の EC2 に置き換え、旧 EBS/ENI を移設する。
# 引数: 旧 EC2 インスタンスID / 出力: 新インスタンスID、破棄予定ルートボリュームID、切替後 describe JSON。
process_target() {
  local old_instance_id=$1
  local dir disable_term disable_stop name current_desc
  local term_protection_changed=false stop_protection_changed=false terminate_issued=false
  dir=$(state_dir "$old_instance_id")

  # --- 事前確認: 状態ファイル・新AMI・バックアップAMI ---
  # 並行モードでは main が fan-out 前に全対象へ実行済みだが、describe だけの冪等な確認なので
  # 各対象でも実行して、逐次モードと同じ「確認直前の状態で検証する」保証を保つ。
  preflight_target "$old_instance_id"

  if [[ "${CONFIRMED_UPFRONT:-false}" != "true" ]]; then
    confirm_or_exit "$YES" "破壊的操作を実行します。旧EC2 $old_instance_id を停止後、ENI/EBSを保全して terminate し、新EC2へ付け替えます。"
  fi
  trap restore_old_protection_on_error ERR

  # --- ステップ1: 必要に応じて終了保護、停止保護を一時的に無効化 ---
  timer_start step1_disable_protection
  disable_term=$(jq -r '.' "$dir/disable_api_termination.json")
  if [[ "$disable_term" == "true" ]]; then
    log_info "$old_instance_id の終了保護を一時的に無効化します。"
    aws_json ec2 modify-instance-attribute --instance-id "$old_instance_id" --no-disable-api-termination >/dev/null
    term_protection_changed=true
  fi
  disable_stop=$(jq -r '.' "$dir/disable_api_stop.json")
  if [[ "$disable_stop" == "true" ]]; then
    log_info "$old_instance_id の停止保護を一時的に無効化します。"
    aws_json ec2 modify-instance-attribute --instance-id "$old_instance_id" --no-disable-api-stop >/dev/null
    stop_protection_changed=true
  fi
  timer_end step1_disable_protection "ステップ1 保護解除"

  # --- ステップ2: 旧 EC2 を停止 ---
  timer_start step2_stop_old
  log_info "$old_instance_id を停止します。"
  aws_json ec2 stop-instances --instance-ids "$old_instance_id" >/dev/null
  wait_until "$WAIT_INSTANCE_STATE_TIMEOUT" 15 "instance stopped: $old_instance_id" instance_state_is "$old_instance_id" "stopped"
  timer_end step2_stop_old "ステップ2 旧EC2停止"

  # prepare 後の構成変更を、まだ旧 EC2 を復旧可能な時点で検出する。
  timer_start step2b_drift_check
  current_desc=$(aws_json ec2 describe-instances --instance-ids "$old_instance_id")
  if ! diff -u \
    <(jq '[.[] | {VolumeId, DeviceName}] | sort_by(.VolumeId, .DeviceName)' "$dir/block_devices.json") \
    <(jq '[.Reservations[0].Instances[0].BlockDeviceMappings[] | select(.Ebs != null) | {VolumeId: .Ebs.VolumeId, DeviceName}] | sort_by(.VolumeId, .DeviceName)' <<<"$current_desc") >/dev/null; then
    die "prepare 後に EBS 構成が変更されている。01 からやり直すこと"
  fi
  if ! diff -u \
    <(jq '[.[] | {NetworkInterfaceId, DeviceIndex}] | sort_by(.NetworkInterfaceId, .DeviceIndex)' "$dir/enis.json") \
    <(jq '[.Reservations[0].Instances[0].NetworkInterfaces[] | {NetworkInterfaceId, DeviceIndex: .Attachment.DeviceIndex}] | sort_by(.NetworkInterfaceId, .DeviceIndex)' <<<"$current_desc") >/dev/null; then
    die "prepare 後に ENI 構成が変更されている。01 からやり直すこと"
  fi
  timer_end step2b_drift_check "ステップ2b 構成差分チェック"

  # --- ステップ3: 全 EBS と全 ENI の DeleteOnTermination=false ---
  # 旧 EC2 を terminate する前に false へ変えないと、インスタンス終了と同時に旧EBS/ENIが削除される可能性がある。
  # jq | while のループはサブシェルなので、タイマーは必ずループの外側で開始・終了する。
  timer_start step3_dot_false
  log_info "EBS/ENI の DeleteOnTermination を false に変更します。"
  jq -r '.[] | [.DeviceName, .VolumeId] | @tsv' "$dir/block_devices.json" |
  while IFS=$'\t' read -r device_name _volume_id; do
    modify_volume_dot "$old_instance_id" "$device_name" false
  done
  jq -r '.[] | [.NetworkInterfaceId, .AttachmentId] | @tsv' "$dir/enis.json" |
  while IFS=$'\t' read -r eni_id attachment_id; do
    modify_eni_dot "$eni_id" "$attachment_id" false
  done
  timer_end step3_dot_false "ステップ3 DeleteOnTermination=false"

  # --- ステップ4: 全 EBS をデタッチ ---
  timer_start step4_detach_ebs
  log_info "旧 EBS ボリュームをデタッチします。"
  jq -r '.[].VolumeId' "$dir/block_devices.json" |
  while IFS= read -r volume_id; do
    aws_json ec2 detach-volume --volume-id "$volume_id" --instance-id "$old_instance_id" >/dev/null
  done
  jq -r '.[].VolumeId' "$dir/block_devices.json" |
  while IFS= read -r volume_id; do
    wait_until "$WAIT_VOLUME_STATE_TIMEOUT" 10 "volume available: $volume_id" volume_state_is "$volume_id" "available"
  done
  timer_end step4_detach_ebs "ステップ4 旧EBSデタッチ"

  # --- ステップ5: 旧 EC2 を terminate ---
  # プライマリENI(DeviceIndex 0)は running/stopped インスタンスから単独デタッチできないため、ENIを新EC2へ移すには terminate が必須。
  timer_start step5_terminate_old
  log_info "$old_instance_id を terminate します。"
  aws_json ec2 terminate-instances --instance-ids "$old_instance_id" >/dev/null
  terminate_issued=true
  trap - ERR
  wait_until "$WAIT_INSTANCE_STATE_TIMEOUT" 15 "instance terminated: $old_instance_id" instance_state_is "$old_instance_id" "terminated"
  jq -r '.[].NetworkInterfaceId' "$dir/enis.json" |
  while IFS= read -r eni_id; do
    wait_until "$WAIT_ENI_AVAILABLE_TIMEOUT" 10 "eni available: $eni_id" eni_status_is "$eni_id" "available"
  done
  timer_end step5_terminate_old "ステップ5 旧EC2 terminate"

  # --- ステップ6: 旧 ENI を DeviceIndex そのままで指定し、新 AMI から新 EC2 を起動 ---
  timer_start step6_run_new
  local ni_file tag_file placement_file metadata_file private_dns_file capacity_reservation_file user_data_file run_args new_json new_instance_id
  ni_file=$(tmp_json)
  tag_file=$(tmp_json)
  placement_file=$(tmp_json)
  metadata_file=$(tmp_json)
  private_dns_file=$(tmp_json)
  capacity_reservation_file=$(tmp_json)
  user_data_file=$(mktemp)
  jq '[.[] | {NetworkInterfaceId, DeviceIndex, DeleteOnTermination: false}]' "$dir/enis.json" > "$ni_file"
  # aws: で始まるタグは AWS 予約タグで CreateTags/RunInstances から指定できないため、ユーザー管理タグだけを新EC2へコピーする。
  local copy_tag_count
  copy_tag_count=$(jq '[.[] | select(.Key | startswith("aws:") | not)] | length' "$dir/tags.json")
  jq -n --slurpfile tags "$dir/tags.json" \
    '[{ResourceType: "instance", Tags: ($tags[0] | map(select(.Key | startswith("aws:") | not)))}]' > "$tag_file"
  # 入力例: {"AvailabilityZone":"ap-northeast-1a","Tenancy":"default","GroupName":null}
  # 出力例: {"AvailabilityZone":"ap-northeast-1a","Tenancy":"default"}。null は run-instances に渡さない。
  jq '{AvailabilityZone, Tenancy} | with_entries(select(.value != null))' "$dir/placement.json" > "$placement_file"
  # 入力例: {"HttpTokens":"required","HttpEndpoint":"enabled","InstanceMetadataTags":null}
  # 出力例: {"HttpTokens":"required","HttpEndpoint":"enabled"}。未設定項目は API に送らない。
  jq '{
    HttpTokens,
    HttpPutResponseHopLimit,
    HttpEndpoint,
    HttpProtocolIpv6,
    InstanceMetadataTags
  } | with_entries(select(.value != null))' "$dir/metadata_options.json" > "$metadata_file"
  jq 'if . == null then {} else with_entries(select(.value != null)) end' "$dir/private_dns_name_options.json" > "$private_dns_file"
  # describe 形式には null 値のキーが混ざり得るため、placement 等と同様に除去してから run-instances へ渡す。
  jq 'if . == null then {} else with_entries(select(.value != null)) end' "$dir/capacity_reservation.json" > "$capacity_reservation_file"

  run_args=(ec2 run-instances
    --image-id "$NEW_AMI_ID"
    --client-token "switch-ec2-${old_instance_id}"
    --instance-type "$(jq -r '.' "$dir/instance_type.json")"
    # AWS CLI v2 では API の MinCount/MaxCount は --count で指定する（--min-count/--max-count は v2 に存在しない）
    --count 1
    --network-interfaces "file://$ni_file"
    --placement "file://$placement_file"
    --metadata-options "file://$metadata_file"
    --instance-initiated-shutdown-behavior "$(jq -r . "$dir/shutdown_behavior.json")")

  # --network-interfaces で既存ENI IDを指定する場合、AWS CLI/API では --subnet-id や --security-group-ids をトップレベルに併用できない。
  # サブネット、IP、SG、Elastic IP は ENI 自体の属性として旧環境から引き継がれる。
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
    # AWS CLI v2 は fileb:// の生バイトを API 送信用に再エンコードする。
    run_args+=(--user-data "fileb://$user_data_file")
  fi

  log_info "新 EC2 を $NEW_AMI_ID から起動します。"
  if ! new_json=$(aws_json "${run_args[@]}"); then
    rm -f "$ni_file" "$tag_file" "$placement_file" "$metadata_file" "$private_dns_file" "$capacity_reservation_file" "$user_data_file"
    die "新 EC2 の起動に失敗しました: old=$old_instance_id"
  fi
  rm -f "$ni_file" "$tag_file" "$placement_file" "$metadata_file" "$private_dns_file" "$capacity_reservation_file" "$user_data_file"
  printf '%s\n' "$new_json" > "$dir/new_instance_run.json"
  new_instance_id=$(jq -r '.Instances[0].InstanceId' <<<"$new_json")
  printf '%s\n' "$new_instance_id" > "$dir/new_instance_id.txt"
  log_info "新 EC2: $new_instance_id"

  wait_until "$WAIT_INSTANCE_STATE_TIMEOUT" 15 "new instance running: $new_instance_id" instance_state_is "$new_instance_id" "running"
  timer_end step6_run_new "ステップ6 新EC2起動"

  # --- ステップ7: 新 EC2 を停止 ---
  timer_start step7_stop_new
  log_info "$new_instance_id を停止して新AMI由来ルートボリュームを外します。"
  aws_json ec2 stop-instances --instance-ids "$new_instance_id" >/dev/null
  wait_until "$WAIT_INSTANCE_STATE_TIMEOUT" 15 "new instance stopped: $new_instance_id" instance_state_is "$new_instance_id" "stopped"
  timer_end step7_stop_new "ステップ7 新EC2停止"

  # --- ステップ8: 新 AMI 由来のルートボリュームをデタッチし、削除予定タグを付与 ---
  timer_start step8_detach_discard_root
  # ライセンスは起動時AMIで決まるため、新AMI由来のRHEL 9.8 ルートは起動後に不要になる。検証完了までは削除せずタグで識別する。
  local new_desc new_root_device discard_volume old_root_device target_root_device
  new_desc=$(aws_json ec2 describe-instances --instance-ids "$new_instance_id")
  printf '%s\n' "$new_desc" > "$dir/new_instance_before_attach.json"
  new_root_device=$(jq -r '.Reservations[0].Instances[0].RootDeviceName' <<<"$new_desc")
  discard_volume=$(jq -r --arg root "$new_root_device" '.Reservations[0].Instances[0].BlockDeviceMappings[] | select(.DeviceName==$root) | .Ebs.VolumeId' <<<"$new_desc")
  printf '%s\n' "$new_root_device" > "$dir/new_root_device_name.txt"
  printf '%s\n' "$discard_volume" > "$dir/discarded_root_volume_id.txt"
  aws_json ec2 detach-volume --volume-id "$discard_volume" --instance-id "$new_instance_id" >/dev/null
  wait_until "$WAIT_VOLUME_STATE_TIMEOUT" 10 "discard root available: $discard_volume" volume_state_is "$discard_volume" "available"
  name=$(instance_name_for_file "$dir/instance.json" "$old_instance_id")
  aws_json ec2 create-tags --resources "$discard_volume" --tags \
    "Key=Name,Value=${name}-discarded-root-rhel98" \
    "Key=Purpose,Value=switch-ec2-discarded-root" \
    "Key=DeleteAfterVerification,Value=true" \
    "Key=SourceOldInstanceId,Value=${old_instance_id}" \
    "Key=NewInstanceId,Value=${new_instance_id}" >/dev/null
  timer_end step8_detach_discard_root "ステップ8 新AMIルート切離し"

  # --- ステップ9: 旧 EBS を新 EC2 にアタッチ ---
  timer_start step9_attach_old_ebs
  # 旧ルートボリュームは旧 RootDeviceName ではなく新インスタンスの RootDeviceName に合わせる。
  # AMI 世代や仮想化方式で /dev/sda1 と /dev/xvda のように名前が異なる場合でも、EC2 が正しいルートとして扱えるようにするため。
  old_root_device=$(jq -r '.' "$dir/root_device_name.json")
  target_root_device="$new_root_device"
  log_info "旧 EBS ボリュームを新 EC2 にアタッチします。旧root=$old_root_device 新root名=$target_root_device"
  jq -c '.[]' "$dir/block_devices.json" |
  while IFS= read -r mapping; do
    local device volume attach_device
    device=$(jq -r '.DeviceName' <<<"$mapping")
    volume=$(jq -r '.VolumeId' <<<"$mapping")
    attach_device="$device"
    if [[ "$device" == "$old_root_device" ]]; then
      attach_device="$target_root_device"
    fi
    aws_json ec2 attach-volume --volume-id "$volume" --instance-id "$new_instance_id" --device "$attach_device" >/dev/null
    wait_until "$WAIT_VOLUME_STATE_TIMEOUT" 10 "volume attached: $volume instance=$new_instance_id device=$attach_device" \
      volume_attachment_is_attached "$volume" "$new_instance_id" "$attach_device"
  done
  timer_end step9_attach_old_ebs "ステップ9 旧EBSアタッチ"

  # --- ステップ10: EBS/ENI の DeleteOnTermination を元の値に復元 ---
  timer_start step10_restore_dot
  log_info "DeleteOnTermination を元の値に復元します。"
  jq -c '.[]' "$dir/block_devices.json" |
  while IFS= read -r mapping; do
    local device dot attach_device
    device=$(jq -r '.DeviceName' <<<"$mapping")
    dot=$(jq -r '.DeleteOnTermination' <<<"$mapping")
    attach_device="$device"
    if [[ "$device" == "$old_root_device" ]]; then
      attach_device="$target_root_device"
    fi
    modify_volume_dot "$new_instance_id" "$attach_device" "$dot"
  done

  new_desc=$(aws_json ec2 describe-instances --instance-ids "$new_instance_id")
  jq -c '.Reservations[0].Instances[0].NetworkInterfaces[] | {NetworkInterfaceId, AttachmentId: .Attachment.AttachmentId}' <<<"$new_desc" |
  while IFS= read -r current_eni; do
    local eni_id attachment_id dot
    eni_id=$(jq -r '.NetworkInterfaceId' <<<"$current_eni")
    attachment_id=$(jq -r '.AttachmentId' <<<"$current_eni")
    dot=$(jq -r --arg eni "$eni_id" '.[] | select(.NetworkInterfaceId==$eni) | .DeleteOnTermination' "$dir/enis.json")
    modify_eni_dot "$eni_id" "$attachment_id" "$dot"
  done
  timer_end step10_restore_dot "ステップ10 DeleteOnTermination復元"

  # --- ステップ11: 新 EC2 を起動し、2/2 ステータスチェック OK まで待機 ---
  timer_start step11_start_new
  log_info "$new_instance_id を起動します。"
  aws_json ec2 start-instances --instance-ids "$new_instance_id" >/dev/null
  wait_until "$WAIT_INSTANCE_STATE_TIMEOUT" 15 "new instance running: $new_instance_id" instance_state_is "$new_instance_id" "running"
  wait_until "$WAIT_STATUS_OK_TIMEOUT" 20 "new instance status ok: $new_instance_id" status_ok "$new_instance_id"
  if [[ "$(jq -r '.' "$dir/disable_api_stop.json")" == "true" ]]; then
    log_info "$new_instance_id の停止保護を元の値に復元します。"
    aws_json ec2 modify-instance-attribute --instance-id "$new_instance_id" --disable-api-stop >/dev/null
  fi
  aws_json ec2 describe-instances --instance-ids "$new_instance_id" > "$dir/new_instance_after_switch.json"
  timer_end step11_start_new "ステップ11 新EC2起動と2/2確認"
  log_info "切替完了: old=$old_instance_id new=$new_instance_id discarded_root=$discard_volume"
  timings_summary "$TIMINGS_FILE" "切替所要時間 内訳: $old_instance_id -> $new_instance_id"
}

# 目的: 並行モードで fan-out する前に、全対象を検証して1回だけまとめて確認する。
# 引数: 同時実行数 / 出力: 検証失敗・不承認時はエラー。
# 注意: 対象ごとに /dev/tty から確認を取ると並行実行で入力が競合するため、確認は fan-out 前に集約する。
#       確認前に全対象の read-only 検証を通すので、ここで落ちれば破壊的操作は1台も走らない。
#       子プロセスへは --single-target-confirmed で「確認済み」を伝える。
confirm_all_targets_upfront() {
  local parallel=$1
  local target target_output
  local -a targets=()
  if ! target_output=$(read_targets); then
    return 1
  fi
  mapfile -t targets <<< "$target_output"
  for target in "${targets[@]}"; do
    [[ -n "$target" ]] || continue
    log_info "事前確認: $target"
    preflight_target "$target"
  done
  confirm_or_exit "$YES" "破壊的操作を最大 ${parallel} 台並行で実行します。対象: ${targets[*]}
各対象で旧EC2を停止後、ENI/EBSを保全して terminate し、新EC2へ付け替えます。
並行実行では失敗時に複数台の復旧が同時に必要になり得ます。"
}

# 目的: 引数・設定を読み込み、targets.txt の全対象へ switch 処理を適用する。
# 引数: --yes, --parallel[=N], --single-target-confirmed <id>, --help / 出力: 対象ごとの新EC2状態ファイル。
main() {
  parse_switch_flags "$@"
  load_config

  # 並行モードで親から起動された子プロセス。自分の担当1台だけを処理する。
  if [[ -n "$SINGLE_TARGET" ]]; then
    setup_target_logging "$SINGLE_TARGET"
    timer_start target_total
    # 成功・失敗のどちらでも対象単位の所要時間を残す。EXIT トラップは終了コードを変えない。
    trap 'timer_end target_total "対象所要時間"' EXIT
    process_target "$SINGLE_TARGET"
    return 0
  fi

  local parallel
  parallel=$(resolve_parallel)
  if (( parallel > 1 )); then
    confirm_all_targets_upfront "$parallel"
    # 対象ごとに自分自身を子プロセスとして起動する。errexit の状態をプロセス境界で切り離し、
    # 途中失敗を確実に検出するため（詳細は lib/common.sh の run_targets_parallel を参照）。
    run_targets_parallel "$parallel" bash "$SCRIPT_DIR/03_switch.sh" --single-target-confirmed
  else
    run_targets process_target
  fi
}

main "$@"
