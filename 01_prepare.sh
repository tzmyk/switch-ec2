#!/usr/bin/env bash
set -euo pipefail

# 事前準備スクリプト。
# 役割: RHEL PAYG の旧 EC2 を ELC/BYOS 系 AMI 起動の新 EC2へ置き換える前に、互換性と復元に必要な情報を保存する。
# 前提: config.env に NEW_AMI_ID、targets.txt に旧 EC2 ID が設定済み。先行スクリプトなし。
# 生成する状態ファイル: instance.json, instance_type.json, key_name.json, iam_instance_profile.json, enis.json, block_devices.json,
# root_device_name.json, placement.json, ebs_optimized.json, monitoring.json, metadata_options.json, tags.json,
# usage_operation.json, boot_mode.json, disable_api_termination.json, disable_api_stop.json, credit_specification.json,
# shutdown_behavior.json, maintenance_options.json, private_dns_name_options.json, cpu_options.json,
# capacity_reservation.json, user_data.b64.txt, new_ami_boot_mode.txt, instance_boot_mode.txt,
# before_instance.json, before_volumes.json, before_enis.json（切替前後の手動 diff 用 describe 全文）,
# 01_prepare.log, timings_01_prepare.tsv。
# ディスクUUIDとOSバージョンの実測検証は、踏み台EC2側の ec2-side/ で実施する。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

NEW_AMI_JSON=

# 目的: NEW_AMI_ID の存在と available 状態を1回だけ確認し、AMI JSON をキャッシュする。
# 引数: なし / 出力: グローバル NEW_AMI_JSON。
prepare_new_ami_once() {
  if [[ -n "$NEW_AMI_JSON" ]]; then
    return 0
  fi
  NEW_AMI_JSON=$(aws_json ec2 describe-images --image-ids "$NEW_AMI_ID")
  local count state
  count=$(jq '.Images | length' <<<"$NEW_AMI_JSON")
  state=$(jq -r '.Images[0].State // empty' <<<"$NEW_AMI_JSON")
  [[ "$count" == "1" ]] || die "NEW_AMI_ID が見つかりません: $NEW_AMI_ID"
  [[ "$state" == "available" ]] || die "NEW_AMI_ID が available ではありません: $NEW_AMI_ID state=$state"
}

# 目的: EC2 API の空/null BootMode を比較しやすい legacy-bios に正規化する。
# 引数: BootMode文字列 / 出力: stdout に正規化済み BootMode。
normalize_boot_mode() {
  local value=$1
  case "$value" in
    ""|"null") printf 'legacy-bios\n' ;;
    uefi-preferred) printf 'uefi-preferred\n' ;;
    *) printf '%s\n' "$value" ;;
  esac
}

# 目的: 1台の旧 EC2 について切替前検査と状態ファイル作成を行う。
# 引数: 旧 EC2 インスタンスID / 出力: WORK_DIR/<instance-id>/ 配下にベースライン状態ファイル一式。
process_target() {
  local instance_id=$1
  local dir instance_json instance state image_arch instance_arch image_boot instance_boot
  local disable_term_json disable_stop_json shutdown_json user_data_json credit_json volumes_json instance_type
  local instance_type_json default_cores default_threads current_cores current_threads cpu_options_json user_data
  local -a volume_ids=()
  dir=$(state_dir "$instance_id")
  if [[ -f "$dir/new_instance_id.txt" ]]; then
    die "この対象は切替済みのため prepare 再実行禁止です: $instance_id"
  fi
  mkdir -p "$dir"

  # --- ステップ1: 新 AMI と旧 EC2 の基本情報を取得 ---
  prepare_new_ami_once
  instance_json=$(aws_json ec2 describe-instances --instance-ids "$instance_id")
  if [[ "$(jq '.Reservations | length' <<<"$instance_json")" == "0" ]]; then
    die "インスタンスが見つかりません: $instance_id"
  fi

  # --- ステップ2: 状態ファイルを書き換える前に切替前提を安全確認 ---
  instance=$(jq -c '.Reservations[0].Instances[0]' <<<"$instance_json")
  state=$(jq -r '.State.Name' <<<"$instance")
  [[ "$state" == "running" ]] || die "インスタンスが running ではありません: state=$state"

  image_arch=$(jq -r '.Images[0].Architecture' <<<"$NEW_AMI_JSON")
  instance_arch=$(jq -r '.Architecture' <<<"$instance")
  [[ "$image_arch" == "$instance_arch" ]] || die "アーキテクチャ不一致: instance=$instance_arch ami=$image_arch"

  image_boot=$(normalize_boot_mode "$(jq -r '.Images[0].BootMode // empty' <<<"$NEW_AMI_JSON")")
  instance_boot=$(normalize_boot_mode "$(jq -r '.CurrentInstanceBootMode // .BootMode // empty' <<<"$instance")")
  # BootMode 互換性チェック。
  # インスタンス側の CurrentInstanceBootMode は実効値（uefi / legacy-bios）だが、
  # RHEL 9 系など uefi-preferred の AMI は BIOS/UEFI 両対応（ハイブリッドブート）のため、
  # 単純な文字列一致だと「uefi vs uefi-preferred」の正常な組み合わせを誤検知してしまう。
  if [[ "$image_boot" == "$instance_boot" ]]; then
    log_info "BootMode 一致: instance=$instance_boot ami=$image_boot"
  elif [[ "$image_boot" == "uefi-preferred" && "$instance_boot" == "uefi" ]]; then
    log_info "BootMode 互換: instance=$instance_boot ami=$image_boot（uefi-preferred は UEFI 起動可能なため問題なし）"
  elif [[ "$image_boot" == "uefi-preferred" && "$instance_boot" == "legacy-bios" ]]; then
    # 新AMI起動の新EC2は（UEFI対応インスタンスタイプなら）UEFIで起動するため、
    # 旧OSディスクがハイブリッドブート構成（BIOS Boot + EFI パーティション両方あり）でないと起動できない。
    if [[ "$ALLOW_UEFI_PREFERRED_ON_BIOS" == "true" ]]; then
      log_warn "BootMode 差異を設定で許可: instance=$instance_boot ami=$image_boot。旧OSディスクがハイブリッドブート構成であることを事前確認すること。"
    else
      die "uefi-preferred AMI と legacy-bios インスタンスの組み合わせは許可されていません。確認済みの場合のみ ALLOW_UEFI_PREFERRED_ON_BIOS=true を設定してください。"
    fi
  else
    die "BootMode 不一致です。起動不能リスクがあるため中止: instance=$instance_boot ami=$image_boot"
  fi

  # --- ステップ3: 非対応構成と引き継げないストレージを検出 ---
  [[ "$(jq -r '.InstanceLifecycle // empty' <<<"$instance")" != "spot" ]] || die "Spot インスタンスは非対応です"
  [[ -z "$(jq -r '.Placement.GroupName // empty' <<<"$instance")" ]] || die "placement group 構成は非対応です: $instance_id"
  if [[ -n "$(jq -r '.Placement.HostId // empty' <<<"$instance")" \
    || "$(jq -r '.Placement.Affinity // empty' <<<"$instance")" == "host" \
    || "$(jq -r '.Placement.Tenancy // empty' <<<"$instance")" == "host" ]]; then
    die "Dedicated Host 構成は非対応です: $instance_id"
  fi
  if jq -e '.NetworkInterfaces[]? | select((.Attachment.NetworkCardIndex // 0) > 0)' <<<"$instance" >/dev/null; then
    die "マルチネットワークカード構成は非対応です: $instance_id"
  fi
  [[ "$(jq -r '.HibernationOptions.Configured // false' <<<"$instance")" != "true" ]] || die "hibernation 構成は非対応です: $instance_id"
  [[ "$(jq -r '.EnclaveOptions.Enabled // false' <<<"$instance")" != "true" ]] || die "Nitro Enclaves 構成は非対応です: $instance_id"

  if jq -e '.BlockDeviceMappings[]? | select(.Ebs? | not)' <<<"$instance" >/dev/null; then
    if [[ "$ALLOW_INSTANCE_STORE_LOSS" == "true" ]]; then
      log_warn "$instance_id のインスタンスストア消失を設定で許可します。EBS 以外は引き継げません。"
    else
      die "$instance_id にインスタンスストアがあります。確認済みの場合のみ ALLOW_INSTANCE_STORE_LOSS=true を設定してください。"
    fi
  fi

  mapfile -t volume_ids < <(jq -r '.BlockDeviceMappings[]?.Ebs.VolumeId // empty' <<<"$instance")
  if ((${#volume_ids[@]} > 0)); then
    volumes_json=$(aws_json ec2 describe-volumes --volume-ids "${volume_ids[@]}")
    if jq -e '.Volumes[]? | select(.MultiAttachEnabled == true)' <<<"$volumes_json" >/dev/null; then
      die "Multi-Attach EBS 構成は非対応です: $instance_id"
    fi
  fi

  # --- ステップ4: 検証完了後に追加属性を取得し、状態ファイルを確定 ---
  disable_term_json=$(aws_json ec2 describe-instance-attribute --instance-id "$instance_id" --attribute disableApiTermination)
  disable_stop_json=$(aws_json ec2 describe-instance-attribute --instance-id "$instance_id" --attribute disableApiStop)
  shutdown_json=$(aws_json ec2 describe-instance-attribute --instance-id "$instance_id" --attribute instanceInitiatedShutdownBehavior)
  user_data_json=$(aws_json ec2 describe-instance-attribute --instance-id "$instance_id" --attribute userData)
  instance_type=$(jq -r '.InstanceType' <<<"$instance")
  instance_type_json=$(aws_json ec2 describe-instance-types --instance-types "$instance_type")
  default_cores=$(jq -r '.InstanceTypes[0].VCpuInfo.DefaultCores' <<<"$instance_type_json")
  default_threads=$(jq -r '.InstanceTypes[0].VCpuInfo.DefaultThreadsPerCore' <<<"$instance_type_json")
  current_cores=$(jq -r '.CpuOptions.CoreCount' <<<"$instance")
  current_threads=$(jq -r '.CpuOptions.ThreadsPerCore' <<<"$instance")
  # タイプ標準値を常に --cpu-options で渡すと非対応タイプの run-instances が失敗し得るため、
  # 標準値との差分があるカスタム CPU options だけを保存して起動時に再指定する。
  if [[ "$current_cores" == "$default_cores" && "$current_threads" == "$default_threads" ]]; then
    cpu_options_json='null'
  else
    cpu_options_json=$(jq -n --argjson cores "$current_cores" --argjson threads "$current_threads" \
      '{CoreCount: $cores, ThreadsPerCore: $threads}')
  fi
  user_data=$(jq -r '.UserData.Value // empty' <<<"$user_data_json")
  if [[ -n "$user_data" && "$COPY_USER_DATA" != "true" ]]; then
    log_warn "UserData が設定されているが COPY_USER_DATA=false のため引き継がない"
  fi
  if [[ "$instance_type" =~ ^t(2|3|3a|4g)\. ]]; then
    credit_json=$(aws_json ec2 describe-instance-credit-specifications --instance-ids "$instance_id")
  else
    credit_json='null'
  fi

  printf '%s\n' "$instance_json" > "$dir/instance.json"
  jq '.InstanceType' <<<"$instance" > "$dir/instance_type.json"
  jq '.KeyName // null' <<<"$instance" > "$dir/key_name.json"
  jq '.IamInstanceProfile // null' <<<"$instance" > "$dir/iam_instance_profile.json"
  jq '.NetworkInterfaces | map({NetworkInterfaceId, DeviceIndex: .Attachment.DeviceIndex, AttachmentId: .Attachment.AttachmentId, DeleteOnTermination: .Attachment.DeleteOnTermination, PrimaryPrivateIpAddress: .PrivateIpAddress, Groups: [.Groups[].GroupId]}) | sort_by(.DeviceIndex)' <<<"$instance" > "$dir/enis.json"
  jq '.BlockDeviceMappings | map(select(.Ebs != null) | {DeviceName, VolumeId: .Ebs.VolumeId, DeleteOnTermination: .Ebs.DeleteOnTermination})' <<<"$instance" > "$dir/block_devices.json"
  jq '.RootDeviceName' <<<"$instance" > "$dir/root_device_name.json"
  jq '.Placement' <<<"$instance" > "$dir/placement.json"
  jq '.EbsOptimized // false' <<<"$instance" > "$dir/ebs_optimized.json"
  jq '.Monitoring' <<<"$instance" > "$dir/monitoring.json"
  jq '.MetadataOptions' <<<"$instance" > "$dir/metadata_options.json"
  jq '.Tags // []' <<<"$instance" > "$dir/tags.json"
  jq '.UsageOperation // null' <<<"$instance" > "$dir/usage_operation.json"
  jq '{BootMode: (.BootMode // null), CurrentInstanceBootMode: (.CurrentInstanceBootMode // null)}' <<<"$instance" > "$dir/boot_mode.json"
  jq '.DisableApiTermination.Value // false' <<<"$disable_term_json" > "$dir/disable_api_termination.json"
  jq '.DisableApiStop.Value // false' <<<"$disable_stop_json" > "$dir/disable_api_stop.json"
  jq '.InstanceInitiatedShutdownBehavior.Value // "stop"' <<<"$shutdown_json" > "$dir/shutdown_behavior.json"
  jq '.MaintenanceOptions // null' <<<"$instance" > "$dir/maintenance_options.json"
  jq '.PrivateDnsNameOptions // null' <<<"$instance" > "$dir/private_dns_name_options.json"
  printf '%s\n' "$cpu_options_json" > "$dir/cpu_options.json"
  jq '.CapacityReservationSpecification // null' <<<"$instance" > "$dir/capacity_reservation.json"
  printf '%s' "$user_data" > "$dir/user_data.b64.txt"
  if [[ "$credit_json" == "null" ]]; then
    printf 'null\n' > "$dir/credit_specification.json"
  else
    jq '.InstanceCreditSpecifications[0] // null' <<<"$credit_json" > "$dir/credit_specification.json"
  fi
  printf '%s\n' "$image_boot" > "$dir/new_ami_boot_mode.txt"
  printf '%s\n' "$instance_boot" > "$dir/instance_boot_mode.txt"

  # --- ステップ5: 切替前後の手動 diff 用に describe 全文を保存 ---
  # 上の状態ファイル群は切替に必要な属性だけを抜き出したものなので、想定外の差分まで確認できるように
  # instance/volume/ENI の describe 全文も残す。切替後の同形式は 04_verify.sh が after_*.json に保存する。
  # フィールドは間引かず、normalize_describe_json でキー順と配列順だけを安定させる。
  local -a eni_ids=()
  local enis_json
  printf '%s\n' "$instance_json" | normalize_describe_json instances > "$dir/before_instance.json"
  if ((${#volume_ids[@]} > 0)); then
    # Multi-Attach 検査で取得済みの describe-volumes をそのまま再利用する。
    printf '%s\n' "$volumes_json" | normalize_describe_json volumes > "$dir/before_volumes.json"
  else
    jq -n '{Volumes: []}' > "$dir/before_volumes.json"
  fi
  mapfile -t eni_ids < <(jq -r '.NetworkInterfaces[]?.NetworkInterfaceId // empty' <<<"$instance")
  if ((${#eni_ids[@]} > 0)); then
    enis_json=$(aws_json ec2 describe-network-interfaces --network-interface-ids "${eni_ids[@]}")
    printf '%s\n' "$enis_json" | normalize_describe_json enis > "$dir/before_enis.json"
  else
    jq -n '{NetworkInterfaces: []}' > "$dir/before_enis.json"
  fi

  # --- ステップ6: 取得結果の要約を表示 ---
  local ip volume_count
  ip=$(jq -r '.PrivateIpAddress // "-"' <<<"$instance")
  volume_count=$(jq 'length' "$dir/block_devices.json")
  log_info "サマリ: $instance_id IP=$ip EBSボリューム数=$volume_count"
}

# 目的: 引数・設定を読み込み、targets.txt の全対象へ prepare 処理を適用する。
# 引数: --yes, --help / 出力: 対象ごとの状態ディレクトリ。
main() {
  parse_yes_flag "$@"
  load_config
  run_targets process_target
}

main "$@"
