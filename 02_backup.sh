#!/usr/bin/env bash
set -euo pipefail

# バックアップAMI作成スクリプト。
# 役割: 旧 EC2 の切替直前バックアップ AMI を作成し、切替失敗時に復旧できる退避点を残す。
# 前提: 01_prepare.sh 済み。各対象の instance.json と block_devices.json が存在すること。
# 生成する状態ファイル: backup_ami_id.txt, backup_created_at.txt。
#
# 実行は2フェーズ構成:
#   フェーズ1: 全対象へ create-image を発行するだけ（API呼び出しのみで数秒/台）
#   フェーズ2: 全対象の AMI が available になるまで待機
# AMI 作成自体は AWS 側で並列に進むため、所要時間は「対象台数 × 作成時間」ではなく
# 「最も遅い1台の作成時間」に近くなる（台数比例の直列待ちを避けるための構成）。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# 目的: 1台の旧 EC2 に対してバックアップ AMI の作成を発行する（available は待たない）。
# 引数: 旧 EC2 インスタンスID / 出力: backup_ami_id.txt, backup_created_at.txt。
create_backup() {
  local instance_id=$1
  local dir name timestamp no_reboot_arg image_json image_id
  dir=$(state_dir "$instance_id")

  # create-image が失敗しても前回の ID を後続処理が誤採用しないよう、発行前に古い値を除去する。
  rm -f "$dir/backup_ami_id.txt"

  need_file "$dir/instance.json"
  need_file "$dir/block_devices.json"

  # --- AMI 名と作成オプションを決定 ---
  name=$(instance_name_for_file "$dir/instance.json" "$instance_id")
  timestamp=$(date '+%Y%m%d-%H%M%S')
  no_reboot_arg=()
  if [[ "${BACKUP_NO_REBOOT}" == "true" ]]; then
    no_reboot_arg=(--no-reboot)
    log_warn "$instance_id は --no-reboot で AMI を作成します。ファイルシステム整合性はアプリ側停止状態に依存します。"
  fi

  # --- バックアップ AMI とスナップショットの作成を発行 ---
  # 既定（reboot あり）の場合、全対象の再起動がほぼ同時に走る点に注意（README 参照）。
  image_json=$(aws_json ec2 create-image \
    --instance-id "$instance_id" \
    --name "${name}-backup-${timestamp}" \
    --description "switch-ec2 backup for ${instance_id} at ${timestamp}" \
    "${no_reboot_arg[@]}" \
    --tag-specifications "ResourceType=image,Tags=[{Key=Purpose,Value=switch-ec2-backup},{Key=SourceInstanceId,Value=${instance_id}},{Key=CreatedAt,Value=${timestamp}}]" \
      "ResourceType=snapshot,Tags=[{Key=Purpose,Value=switch-ec2-backup},{Key=SourceInstanceId,Value=${instance_id}},{Key=CreatedAt,Value=${timestamp}}]")
  image_id=$(jq -r '.ImageId' <<<"$image_json")
  printf '%s\n' "$image_id" > "$dir/backup_ami_id.txt"
  printf '%s\n' "$timestamp" > "$dir/backup_created_at.txt"
  log_info "AMI 作成を発行しました: $instance_id -> $image_id"
}

# 目的: 発行済みバックアップ AMI が available になるまで待機する。
# 引数: 旧 EC2 インスタンスID / 出力: なし（タイムアウト・作成失敗時はエラー）。
wait_backup() {
  local instance_id=$1
  local dir image_id
  dir=$(state_dir "$instance_id")
  # フェーズ1で作成発行に失敗した対象はここで必須ファイル不足となり、失敗として計上される
  need_file "$dir/backup_ami_id.txt"
  image_id=$(<"$dir/backup_ami_id.txt")

  # aws ec2 wait image-available は既定で約10分でタイムアウトするため、大容量EBSでも待てるよう WAIT_IMAGE_AVAILABLE_TIMEOUT を使う。
  wait_until "$WAIT_IMAGE_AVAILABLE_TIMEOUT" 30 "AMI available: $image_id" image_state_is "$image_id" "available"
  log_info "AMI が available になりました: $instance_id -> $image_id"
}

# 目的: 引数・設定を読み込み、作成発行→待機の2フェーズで全対象を処理する。
# 引数: --yes, --help / 出力: 対象ごとのバックアップAMI状態ファイル。
main() {
  parse_yes_flag "$@"
  load_config

  # フェーズ1で一部の対象が失敗しても、発行に成功した対象の待機（フェーズ2）は続行する。
  # そのため即時終了させず、両フェーズの結果を合算して終了コードを決める。
  local phase1_rc=0 phase2_rc=0

  log_info "=== フェーズ1/2: 全対象へバックアップAMI作成を発行します ==="
  run_targets create_backup || phase1_rc=$?

  log_info "=== フェーズ2/2: 全AMIが available になるまで待機します ==="
  run_targets wait_backup || phase2_rc=$?

  if (( phase1_rc != 0 || phase2_rc != 0 )); then
    return 1
  fi
  return 0
}

main "$@"
