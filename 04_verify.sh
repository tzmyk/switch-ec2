#!/usr/bin/env bash
set -euo pipefail

# 切替後検証スクリプト。
# 役割: 新 EC2 が旧 EC2 のIP、ENI、EBS、タグ、インスタンスタイプを維持し、UsageOperation が切り替わったことを確認する。
# 前提: 01_prepare.sh と 03_switch.sh 済み。各対象の prepare 状態ファイルと new_instance_id.txt が存在すること。
# 生成する状態ファイル: verify_new_instance.json, verify_old_enis.normalized.json, verify_new_enis.normalized.json,
# verify_expected_volumes.json, verify_actual_volumes.json, verify_old_tags.normalized.json, verify_new_tags.normalized.json。
# ディスクUUIDとOSバージョンの実測検証は、踏み台EC2上で ec2-side/compare_disk_info.sh を実行して確認する。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

verify_failed=0

# 目的: 検証成功を標準出力へ表示する。
# 引数: メッセージ / 出力: stdout。
report_pass() { printf '[PASS] %s\n' "$*"; }
# 目的: 検証失敗を標準出力へ表示し、対象の失敗フラグを立てる。
# 引数: メッセージ / 出力: stdout。
report_fail() { printf '[FAIL] %s\n' "$*"; verify_failed=1; }
# 目的: 判定ではない補足情報を標準出力へ表示する。
# 引数: メッセージ / 出力: stdout。
report_info() { printf '[INFO] %s\n' "$*"; }

# 目的: jqでキー順を正規化したJSON同士を比較する。
# 引数: 左JSONファイル, 右JSONファイル / 出力: 終了コードで一致/不一致。
json_equal() {
  local left=$1
  local right=$2
  diff -u <(jq -S . "$left") <(jq -S . "$right") >/dev/null
}

# 目的: 1台の切替結果について、旧EC2ベースラインと新EC2実態を比較する。
# 引数: 旧 EC2 インスタンスID / 出力: 検証レポートと verify_* 状態ファイル。
process_target() {
  local old_instance_id=$1
  local dir new_instance_id new_desc new_file
  verify_failed=0
  dir=$(state_dir "$old_instance_id")
  need_file "$dir/instance.json"
  need_file "$dir/enis.json"
  need_file "$dir/block_devices.json"
  need_file "$dir/root_device_name.json"
  need_file "$dir/metadata_options.json"
  need_file "$dir/iam_instance_profile.json"
  need_file "$dir/ebs_optimized.json"
  need_file "$dir/monitoring.json"
  need_file "$dir/key_name.json"
  need_file "$dir/disable_api_termination.json"
  need_file "$dir/disable_api_stop.json"
  need_file "$dir/shutdown_behavior.json"
  need_file "$dir/maintenance_options.json"
  need_file "$dir/private_dns_name_options.json"
  need_file "$dir/cpu_options.json"
  need_file "$dir/capacity_reservation.json"
  need_file "$dir/user_data.b64.txt"
  need_file "$dir/new_instance_id.txt"

  new_instance_id=$(<"$dir/new_instance_id.txt")
  new_desc=$(aws_json ec2 describe-instances --instance-ids "$new_instance_id")
  new_file="$dir/verify_new_instance.json"
  printf '%s\n' "$new_desc" > "$new_file"

  printf '\n=== %s -> %s 検証 ===\n' "$old_instance_id" "$new_instance_id"

  # --- ステップ1: プライマリプライベートIPを確認 ---
  local old_ip new_ip
  old_ip=$(jq -r '.Reservations[0].Instances[0].PrivateIpAddress // empty' "$dir/instance.json")
  new_ip=$(jq -r '.Reservations[0].Instances[0].PrivateIpAddress // empty' "$new_file")
  if [[ "$old_ip" == "$new_ip" ]]; then
    report_pass "プライマリプライベートIP一致: $old_ip"
  else
    report_fail "プライマリプライベートIP不一致: old=$old_ip new=$new_ip"
  fi

  # --- ステップ2: ENI ID、DeviceIndex、DeleteOnTermination の維持を確認 ---
  jq '[.[] | {DeviceIndex, NetworkInterfaceId, DeleteOnTermination}] | sort_by(.DeviceIndex)' "$dir/enis.json" > "$dir/verify_old_enis.normalized.json"
  jq '[.Reservations[0].Instances[0].NetworkInterfaces[] | {DeviceIndex: .Attachment.DeviceIndex, NetworkInterfaceId, DeleteOnTermination: .Attachment.DeleteOnTermination}] | sort_by(.DeviceIndex)' "$new_file" > "$dir/verify_new_enis.normalized.json"
  if json_equal "$dir/verify_old_enis.normalized.json" "$dir/verify_new_enis.normalized.json"; then
    report_pass "全ENI ID/DeviceIndex/DeleteOnTermination 一致"
  else
    report_fail "ENI 構成不一致。差分: $dir/verify_old_enis.normalized.json / $dir/verify_new_enis.normalized.json"
    diff -u "$dir/verify_old_enis.normalized.json" "$dir/verify_new_enis.normalized.json" || true
  fi

  # --- ステップ3: EBS ボリュームID、デバイス名、DeleteOnTermination を確認 ---
  # 旧ルートだけは新インスタンスの RootDeviceName に付け替える設計なので、その差分は期待値として正規化する。
  local old_root new_root
  old_root=$(jq -r '.' "$dir/root_device_name.json")
  new_root=$(jq -r '.Reservations[0].Instances[0].RootDeviceName' "$new_file")
  jq --arg old_root "$old_root" --arg new_root "$new_root" '
    map(if .DeviceName == $old_root then {DeviceName: $new_root, VolumeId, DeleteOnTermination} else {DeviceName, VolumeId, DeleteOnTermination} end)
    | sort_by(.VolumeId, .DeviceName)
  ' "$dir/block_devices.json" > "$dir/verify_expected_volumes.json"
  jq '[.Reservations[0].Instances[0].BlockDeviceMappings[] | {DeviceName, VolumeId: .Ebs.VolumeId, DeleteOnTermination: .Ebs.DeleteOnTermination}] | sort_by(.VolumeId, .DeviceName)' "$new_file" > "$dir/verify_actual_volumes.json"
  if json_equal "$dir/verify_expected_volumes.json" "$dir/verify_actual_volumes.json"; then
    report_pass "ボリュームID/デバイス名/DeleteOnTermination 一致（ルート名差異は許容）"
  else
    report_fail "ボリューム構成不一致。差分:"
    diff -u "$dir/verify_expected_volumes.json" "$dir/verify_actual_volumes.json" || true
  fi

  # --- ステップ4: タグを確認 ---
  # aws: で始まるタグは AWS 予約タグであり、ユーザーが RunInstances/CreateTags でコピーできないため比較対象外。
  jq 'map(select(.Key | startswith("aws:") | not)) | sort_by(.Key, .Value)' "$dir/tags.json" > "$dir/verify_old_tags.normalized.json"
  jq '[.Reservations[0].Instances[0].Tags[]? | select(.Key | startswith("aws:") | not)] | sort_by(.Key, .Value)' "$new_file" > "$dir/verify_new_tags.normalized.json"
  if json_equal "$dir/verify_old_tags.normalized.json" "$dir/verify_new_tags.normalized.json"; then
    report_pass "タグ一致（aws: 予約タグ除く）"
  else
    report_fail "タグ不一致。差分:"
    diff -u "$dir/verify_old_tags.normalized.json" "$dir/verify_new_tags.normalized.json" || true
  fi

  # --- ステップ5: インスタンスタイプを確認 ---
  local old_type new_type
  old_type=$(jq -r '.' "$dir/instance_type.json")
  new_type=$(jq -r '.Reservations[0].Instances[0].InstanceType' "$new_file")
  if [[ "$old_type" == "$new_type" ]]; then
    report_pass "インスタンスタイプ一致: $old_type"
  else
    report_fail "インスタンスタイプ不一致: old=$old_type new=$new_type"
  fi

  # --- ステップ6: UsageOperation の変化と期待値を判定 ---
  # 課金コード/UsageOperation は起動時AMIで決まるため、ここは旧PAYGから新AMI由来の値へ変化することが期待される。
  local old_usage new_usage
  old_usage=$(jq -r '. // empty' "$dir/usage_operation.json")
  new_usage=$(jq -r '.Reservations[0].Instances[0].UsageOperation // empty' "$new_file")
  if [[ -z "$new_usage" ]]; then
    report_fail "UsageOperation が新 EC2 で空です: old=${old_usage:-空}"
  elif [[ "$old_usage" == "$new_usage" ]]; then
    report_fail "UsageOperation が切替前後で変化していません: $new_usage"
  elif [[ -n "$EXPECTED_NEW_USAGE_OPERATION" && "$new_usage" != "$EXPECTED_NEW_USAGE_OPERATION" ]]; then
    report_fail "UsageOperation が期待値と不一致: expected=$EXPECTED_NEW_USAGE_OPERATION actual=$new_usage"
  else
    report_pass "UsageOperation 切替確認: old=${old_usage:-空} new=$new_usage"
  fi

  # --- ステップ7: 起動属性と保護設定の復元を確認 ---
  local old_value new_value old_term new_term old_stop new_stop attribute_json
  old_value=$(jq -r '.HttpTokens // empty' "$dir/metadata_options.json")
  new_value=$(jq -r '.Reservations[0].Instances[0].MetadataOptions.HttpTokens // empty' "$new_file")
  [[ "$old_value" == "$new_value" ]] && report_pass "MetadataOptions.HttpTokens 一致: $new_value" \
    || report_fail "MetadataOptions.HttpTokens 不一致: old=${old_value:-空} new=${new_value:-空}"
  old_value=$(jq -r '.HttpEndpoint // empty' "$dir/metadata_options.json")
  new_value=$(jq -r '.Reservations[0].Instances[0].MetadataOptions.HttpEndpoint // empty' "$new_file")
  [[ "$old_value" == "$new_value" ]] && report_pass "MetadataOptions.HttpEndpoint 一致: $new_value" \
    || report_fail "MetadataOptions.HttpEndpoint 不一致: old=${old_value:-空} new=${new_value:-空}"
  old_value=$(jq -r '.Arn // empty' "$dir/iam_instance_profile.json")
  new_value=$(jq -r '.Reservations[0].Instances[0].IamInstanceProfile.Arn // empty' "$new_file")
  [[ "$old_value" == "$new_value" ]] && report_pass "IamInstanceProfile.Arn 一致" \
    || report_fail "IamInstanceProfile.Arn 不一致: old=${old_value:-なし} new=${new_value:-なし}"
  old_value=$(jq -r '.' "$dir/ebs_optimized.json")
  new_value=$(jq -r '.Reservations[0].Instances[0].EbsOptimized // false' "$new_file")
  [[ "$old_value" == "$new_value" ]] && report_pass "EbsOptimized 一致: $new_value" \
    || report_fail "EbsOptimized 不一致: old=$old_value new=$new_value"
  old_value=$(jq -r '.State // empty' "$dir/monitoring.json")
  new_value=$(jq -r '.Reservations[0].Instances[0].Monitoring.State // empty' "$new_file")
  [[ "$old_value" == "$new_value" ]] && report_pass "Monitoring.State 一致: $new_value" \
    || report_fail "Monitoring.State 不一致: old=${old_value:-空} new=${new_value:-空}"
  old_value=$(jq -r '. // empty' "$dir/key_name.json")
  new_value=$(jq -r '.Reservations[0].Instances[0].KeyName // empty' "$new_file")
  [[ "$old_value" == "$new_value" ]] && report_pass "KeyName 一致: ${new_value:-なし}" \
    || report_fail "KeyName 不一致: old=${old_value:-なし} new=${new_value:-なし}"

  old_term=$(jq -r '.' "$dir/disable_api_termination.json")
  attribute_json=$(aws_json ec2 describe-instance-attribute --instance-id "$new_instance_id" --attribute disableApiTermination)
  new_term=$(jq -r '.DisableApiTermination.Value // false' <<<"$attribute_json")
  [[ "$old_term" == "$new_term" ]] && report_pass "終了保護一致: $new_term" \
    || report_fail "終了保護不一致: old=$old_term new=$new_term"
  old_stop=$(jq -r '.' "$dir/disable_api_stop.json")
  attribute_json=$(aws_json ec2 describe-instance-attribute --instance-id "$new_instance_id" --attribute disableApiStop)
  new_stop=$(jq -r '.DisableApiStop.Value // false' <<<"$attribute_json")
  [[ "$old_stop" == "$new_stop" ]] && report_pass "停止保護一致: $new_stop" \
    || report_fail "停止保護不一致: old=$old_stop new=$new_stop"

  old_value=$(jq -r '.' "$dir/shutdown_behavior.json")
  attribute_json=$(aws_json ec2 describe-instance-attribute --instance-id "$new_instance_id" --attribute instanceInitiatedShutdownBehavior)
  new_value=$(jq -r '.InstanceInitiatedShutdownBehavior.Value // "stop"' <<<"$attribute_json")
  [[ "$old_value" == "$new_value" ]] && report_pass "InstanceInitiatedShutdownBehavior 一致: $new_value" \
    || report_fail "InstanceInitiatedShutdownBehavior 不一致: old=$old_value new=$new_value"

  old_value=$(jq -r '.AutoRecovery // empty' "$dir/maintenance_options.json")
  if [[ -z "$old_value" ]]; then
    report_info "MaintenanceOptions.AutoRecovery は保存値が null のため検証をスキップ"
  else
    new_value=$(jq -r '.Reservations[0].Instances[0].MaintenanceOptions.AutoRecovery // empty' "$new_file")
    [[ "$old_value" == "$new_value" ]] && report_pass "MaintenanceOptions.AutoRecovery 一致: $new_value" \
      || report_fail "MaintenanceOptions.AutoRecovery 不一致: old=$old_value new=${new_value:-空}"
  fi

  if [[ "$(jq -r 'type' "$dir/private_dns_name_options.json")" == "null" ]]; then
    report_info "PrivateDnsNameOptions は保存値が null のため検証をスキップ"
  else
    old_value=$(jq -cS . "$dir/private_dns_name_options.json")
    new_value=$(jq -cS '.Reservations[0].Instances[0].PrivateDnsNameOptions // null' "$new_file")
    [[ "$old_value" == "$new_value" ]] && report_pass "PrivateDnsNameOptions 一致" \
      || report_fail "PrivateDnsNameOptions 不一致: old=$old_value new=$new_value"
  fi

  old_value=$(jq -cS '.Reservations[0].Instances[0].CpuOptions | {CoreCount, ThreadsPerCore}' "$dir/instance.json")
  new_value=$(jq -cS '.Reservations[0].Instances[0].CpuOptions | {CoreCount, ThreadsPerCore}' "$new_file")
  [[ "$old_value" == "$new_value" ]] && report_pass "CpuOptions 一致: $new_value" \
    || report_fail "CpuOptions 不一致: old=$old_value new=$new_value"

  if [[ "$(jq -r 'type' "$dir/capacity_reservation.json")" == "null" ]]; then
    report_info "CapacityReservationSpecification は保存値が null のため検証をスキップ"
  else
    old_value=$(jq -cS . "$dir/capacity_reservation.json")
    new_value=$(jq -cS '.Reservations[0].Instances[0].CapacityReservationSpecification // null' "$new_file")
    [[ "$old_value" == "$new_value" ]] && report_pass "CapacityReservationSpecification 一致" \
      || report_fail "CapacityReservationSpecification 不一致: old=$old_value new=$new_value"
  fi

  if [[ "$COPY_USER_DATA" == "true" ]]; then
    old_value=$(<"$dir/user_data.b64.txt")
    attribute_json=$(aws_json ec2 describe-instance-attribute --instance-id "$new_instance_id" --attribute userData)
    new_value=$(jq -r '.UserData.Value // empty' <<<"$attribute_json")
    [[ "$old_value" == "$new_value" ]] && report_pass "UserData 一致" \
      || report_fail "UserData 不一致"
  elif [[ -s "$dir/user_data.b64.txt" ]]; then
    report_info "UserData は引き継いでいない（COPY_USER_DATA=false）"
  fi

  # --- ステップ8: OS 内実測検証の案内 ---
  report_info "ディスクUUIDとOSバージョンの実測検証は踏み台EC2上で ec2-side/compare_disk_info.sh を実行して確認すること"

  # --- ステップ9: 対象単位の検証サマリ ---
  if [[ "$verify_failed" == "0" ]]; then
    printf '[SUMMARY] %s -> %s PASS\n' "$old_instance_id" "$new_instance_id"
    return 0
  fi
  printf '[SUMMARY] %s -> %s FAIL\n' "$old_instance_id" "$new_instance_id"
  return 1
}

# 目的: 引数・設定を読み込み、targets.txt の全対象へ verify 処理を適用する。
# 引数: --yes, --help / 出力: 対象ごとの検証レポートと verify_* 状態ファイル。
main() {
  parse_yes_flag "$@"
  load_config
  run_targets process_target
}

main "$@"
