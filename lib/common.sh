#!/usr/bin/env bash
set -euo pipefail

# 共通ライブラリ。
# 役割: 各スクリプトから使う設定読込、AWS CLI ラッパー、待機、対象一覧処理を集約する。
# 前提: 呼び出し元が config.env と targets.txt を同じディレクトリ基準で用意し、load_config 後に使う。
# 生成する状態ファイル: なし（呼び出し元スクリプトが状態ファイルを生成する）。

# 目的: ログ時刻をローカルタイムゾーン付きで返す。
# 引数: なし / 出力: stdout に YYYY-MM-DD HH:MM:SS+TZ。
log_ts() { date '+%Y-%m-%d %H:%M:%S%z'; }
# 目的: 情報ログを stderr に出す。
# 引数: メッセージ / 出力: stderr。
log_info() { printf '[%s] [INFO] %s\n' "$(log_ts)" "$*" >&2; }
# 目的: 警告ログを stderr に出す。
# 引数: メッセージ / 出力: stderr。
log_warn() { printf '[%s] [WARN] %s\n' "$(log_ts)" "$*" >&2; }
# 目的: エラーログを stderr に出す。
# 引数: メッセージ / 出力: stderr。
log_error() { printf '[%s] [ERROR] %s\n' "$(log_ts)" "$*" >&2; }

# 目的: エラーを記録して呼び出し元の set -e に失敗を伝える。
# 引数: メッセージ / 出力: stderr。
die() {
  log_error "$*"
  return 1
}

# 目的: config.env を読み込み、必須値と待機タイムアウト既定値を初期化する。
# 引数: なし / 出力: WORK_DIR を作成。
load_config() {
  if [[ ! -f config.env ]]; then
    die "config.env がありません。config.env.example をコピーして設定してください。"
  fi
  # shellcheck source=/dev/null
  source config.env

  : "${AWS_REGION:=}"
  : "${NEW_AMI_ID:=}"
  : "${BACKUP_NO_REBOOT:=false}"
  : "${ALLOW_UEFI_PREFERRED_ON_BIOS:=false}"
  : "${ALLOW_INSTANCE_STORE_LOSS:=false}"
  : "${COPY_USER_DATA:=false}"
  : "${EXPECTED_NEW_USAGE_OPERATION:=}"
  : "${WORK_DIR:=./work}"
  : "${WAIT_IMAGE_AVAILABLE_TIMEOUT:=3600}"
  : "${WAIT_INSTANCE_STATE_TIMEOUT:=1800}"
  : "${WAIT_VOLUME_STATE_TIMEOUT:=1800}"
  : "${WAIT_ENI_AVAILABLE_TIMEOUT:=900}"
  : "${WAIT_STATUS_OK_TIMEOUT:=1800}"

  if [[ -z "$NEW_AMI_ID" ]]; then
    die "NEW_AMI_ID が未設定です。"
  fi
  mkdir -p "$WORK_DIR"
}

# 目的: AWS_REGION が指定されている場合だけ AWS CLI 用の --region 引数列を返す。
# 引数: なし / 出力: stdout に引数を1要素1行で出力。
aws_region_args() {
  if [[ -n "${AWS_REGION:-}" ]]; then
    printf '%s\n' --region "$AWS_REGION"
  fi
}

# 目的: AWS CLI を JSON 出力で実行し、リージョン指定を共通化する。
# 引数: aws サブコマンド以降 / 出力: stdout に JSON。
# 注意: stdin は必ず /dev/null に切り離す。run_targets の while ループ内で aws が stdin を読むと
#       （エラー時の auto-prompt 等）、対象一覧の残り行を吸い込んで後続対象が未処理になるため。
aws_json() {
  local region_args=()
  mapfile -t region_args < <(aws_region_args)
  aws "${region_args[@]}" "$@" --output json </dev/null
}

# 目的: AWS CLI を text 出力で実行し、リージョン指定を共通化する。
# 引数: aws サブコマンド以降 / 出力: stdout に text。stdin 切り離しの理由は aws_json と同じ。
aws_text() {
  local region_args=()
  mapfile -t region_args < <(aws_region_args)
  aws "${region_args[@]}" "$@" --output text </dev/null
}

# 目的: 対象インスタンスごとの状態ディレクトリパスを組み立てる。
# 引数: インスタンスID / 出力: stdout に WORK_DIR/インスタンスID。
state_dir() {
  printf '%s/%s\n' "$WORK_DIR" "$1"
}

# 目的: 後続ステップに必要な状態ファイルが存在することを確認する。
# 引数: ファイルパス / 出力: 不足時はエラー。
need_file() {
  [[ -f "$1" ]] || die "必須状態ファイルがありません: $1"
}

# 目的: JSON ファイルから jq フィルタで値を取り出すための小さな補助。
# 引数: ファイルパス, jq フィルタ / 出力: stdout に jq -r の結果。
json_get() {
  local file=$1
  local filter=$2
  jq -r "$filter" "$file"
}

# 目的: targets.txt から空行とコメント行を除いて対象インスタンスIDを列挙する。
# 引数: なし / 出力: stdout に対象IDを1行ずつ。
read_targets() {
  if [[ ! -f targets.txt ]]; then
    die "targets.txt がありません。targets.txt.example をコピーして対象インスタンスIDを記載してください。"
    return 1
  fi
  local targets=()
  local target
  local -A seen=()
  mapfile -t targets < <(awk '!/^[[:space:]]*($|#)/ { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }' targets.txt)
  for target in "${targets[@]}"; do
    if [[ ! "$target" =~ ^i-[0-9a-f]+$ ]]; then
      die "不正なインスタンスIDです: $target"
      return 1
    fi
    if [[ -n "${seen[$target]:-}" ]]; then
      die "targets.txt に重複したインスタンスIDがあります: $target"
      return 1
    fi
    seen[$target]=1
  done
  printf '%s\n' "${targets[@]}"
}

# 目的: 破壊的操作の前に明示確認し、--yes の場合だけ確認を省略する。
# 引数: yesフラグ, 表示メッセージ / 出力: stderr に確認文、不承認時はエラー。
confirm_or_exit() {
  local yes=$1
  local message=$2
  if [[ "$yes" == "true" ]]; then
    log_warn "確認省略 (--yes): $message"
    return 0
  fi
  printf '%s\n' "$message" >&2
  printf '続行する場合は yes と入力してください: ' >&2
  local answer
  # run_targets の while ループでは stdin が targets.txt 相当の読み取りに使われている。
  # ここで通常の read を使うと次の対象IDを確認応答として消費するため、可能なら /dev/tty から読む。
  if [[ -r /dev/tty ]]; then
    read -r answer < /dev/tty
  else
    read -r answer
  fi
  [[ "$answer" == "yes" ]] || die "ユーザー確認で中止しました。"
}

# 目的: 各スクリプト共通の --yes と --help を解釈する。
# 引数: コマンドライン引数 / 出力: グローバル YES を設定、help は stdout。
parse_yes_flag() {
  YES=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) YES=true ;;
      -h|--help)
        printf 'Usage: %s [--yes]\n' "$0"
        exit 0
        ;;
      *) die "不明なオプションです: $1" ;;
    esac
    shift
  done
}

# 目的: AWS 側の非同期状態変化を任意条件で待つ。
# 引数: timeout秒, interval秒, 説明, 条件関数とその引数 / 出力: タイムアウト時はエラー。
wait_until() {
  local timeout=$1
  local interval=$2
  local description=$3
  shift 3
  local start now rc
  start=$(date +%s)
  while true; do
    if "$@"; then
      return 0
    else
      rc=$?
      if [[ "$rc" == "2" ]]; then
        die "期待状態へ到達不能な終端状態です: $description"
        return 1
      fi
    fi
    now=$(date +%s)
    if (( now - start >= timeout )); then
      die "タイムアウトしました: $description"
      return 1
    fi
    sleep "$interval"
  done
}

# 目的: EC2 インスタンスの State.Name が期待値になったか判定する。
# 引数: インスタンスID, 期待状態 / 出力: 終了コードで真偽。
instance_state_is() {
  local instance_id=$1
  local expected=$2
  local state
  if ! state=$(aws_json ec2 describe-instances --instance-ids "$instance_id" | jq -r '.Reservations[0].Instances[0].State.Name // empty'); then
    return 1
  fi
  if [[ "$expected" != "terminated" && "$state" == "terminated" ]]; then
    log_error "インスタンスが期待状態 $expected に到達できません: instance=$instance_id state=$state"
    return 2
  fi
  [[ "$state" == "$expected" ]]
}

# 目的: EBS ボリュームの State が期待値になったか判定する。
# 引数: ボリュームID, 期待状態 / 出力: 終了コードで真偽。
volume_state_is() {
  local volume_id=$1
  local expected=$2
  local volume_json state
  if ! volume_json=$(aws_json ec2 describe-volumes --volume-ids "$volume_id" 2>&1); then
    if [[ "$volume_json" == *"InvalidVolume.NotFound"* ]]; then
      log_error "ボリュームが削除済みです: volume=$volume_id"
      return 2
    fi
    printf '%s\n' "$volume_json" >&2
    return 1
  fi
  if [[ "$(jq '.Volumes | length' <<<"$volume_json")" == "0" ]]; then
    log_error "ボリュームが見つかりません（削除済みの可能性）: volume=$volume_id"
    return 2
  fi
  if ! state=$(jq -r '.Volumes[0].State // empty' <<<"$volume_json"); then
    return 1
  fi
  if [[ "$state" == "error" || "$state" == "deleted" ]]; then
    log_error "ボリュームが期待状態 $expected に到達できません: volume=$volume_id state=$state"
    return 2
  fi
  [[ "$state" == "$expected" ]]
}

# 目的: EBS ボリュームに指定インスタンス・デバイス名の attached アタッチメントがあるか判定する。
# 引数: ボリュームID, インスタンスID, デバイス名 / 出力: 終了コードで真偽。
volume_attachment_is_attached() {
  local volume_id=$1
  local instance_id=$2
  local device_name=$3
  local volume_json state
  if ! volume_json=$(aws_json ec2 describe-volumes --volume-ids "$volume_id" 2>&1); then
    if [[ "$volume_json" == *"InvalidVolume.NotFound"* ]]; then
      log_error "ボリュームが削除済みです: volume=$volume_id"
      return 2
    fi
    printf '%s\n' "$volume_json" >&2
    return 1
  fi
  if ! state=$(jq -r '.Volumes[0].State // empty' <<<"$volume_json"); then
    return 1
  fi
  if [[ "$(jq '.Volumes | length' <<<"$volume_json")" == "0" ]]; then
    log_error "ボリュームが見つかりません（削除済みの可能性）: volume=$volume_id"
    return 2
  fi
  if [[ "$state" == "error" || "$state" == "deleted" ]]; then
    log_error "ボリュームをアタッチできない終端状態です: volume=$volume_id state=$state"
    return 2
  fi
  jq -e --arg instance "$instance_id" --arg device "$device_name" '
    .Volumes[0].Attachments[]?
    | select(.InstanceId == $instance and .Device == $device and .State == "attached")
  ' <<<"$volume_json" >/dev/null
}

# 目的: ENI の Status が期待値になったか判定する。
# 引数: ENI ID, 期待状態 / 出力: 終了コードで真偽。
eni_status_is() {
  local eni_id=$1
  local expected=$2
  local status
  status=$(aws_json ec2 describe-network-interfaces --network-interface-ids "$eni_id" | jq -r '.NetworkInterfaces[0].Status // empty')
  [[ "$status" == "$expected" ]]
}

# 目的: AMI の State が期待値になったか判定する。
# 引数: AMI ID, 期待状態 / 出力: 終了コードで真偽。
image_state_is() {
  local image_id=$1
  local expected=$2
  local image_json state
  if ! image_json=$(aws_json ec2 describe-images --image-ids "$image_id" 2>&1); then
    if [[ "$image_json" == *"InvalidAMIID.NotFound"* ]]; then
      log_error "AMI が deregister 済みです: image=$image_id"
      return 2
    fi
    printf '%s\n' "$image_json" >&2
    return 1
  fi
  if ! state=$(jq -r '.Images[0].State // empty' <<<"$image_json"); then
    return 1
  fi
  if [[ -z "$state" ]]; then
    log_error "AMI が見つかりません（deregister 済みの可能性）: image=$image_id"
    return 2
  fi
  if [[ "$state" == "failed" || "$state" == "deregistered" ]]; then
    log_error "AMI が期待状態 $expected に到達できません: image=$image_id state=$state"
    return 2
  fi
  [[ "$state" == "$expected" ]]
}

# 目的: EC2 の SystemStatus と InstanceStatus がともに ok か判定する。
# 引数: インスタンスID / 出力: 終了コードで真偽。
status_ok() {
  local instance_id=$1
  local status system instance
  status=$(aws_json ec2 describe-instance-status --instance-ids "$instance_id" --include-all-instances)
  system=$(jq -r '.InstanceStatuses[0].SystemStatus.Status // empty' <<<"$status")
  instance=$(jq -r '.InstanceStatuses[0].InstanceStatus.Status // empty' <<<"$status")
  [[ "$system" == "ok" && "$instance" == "ok" ]]
}

# 目的: Name タグをファイル名に使える形へ正規化し、なければフォールバックを使う。
# 引数: instance.json, フォールバック文字列 / 出力: stdout に安全な名前。
instance_name_for_file() {
  local instance_file=$1
  local fallback=$2
  local name
  name=$(jq -r '.Reservations[0].Instances[0].Tags[]? | select(.Key=="Name") | .Value' "$instance_file" | head -n 1)
  if [[ -z "$name" || "$name" == "null" ]]; then
    name=$fallback
  fi
  printf '%s\n' "$name" | tr -cs '[:alnum:]._-' '-'
}

# 目的: targets.txt の各対象に同じハンドラを適用し、1台失敗しても残りを処理して最後にサマリを返す。
# 引数: ハンドラ関数名 / 出力: stderr に成功/失敗サマリ、失敗が1台以上あれば終了コード1。
run_targets() {
  local handler=$1
  local successes=()
  local failures=()
  local target
  local target_output
  local rc
  if ! target_output=$(read_targets); then
    return 1
  fi
  # 複数台の一括切替では、途中の1台失敗で全体を止めるより、成功/失敗を最後に一覧化する方が復旧判断しやすい。
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    log_info "処理開始: $target"
    set +e
    ( set -eEuo pipefail; "$handler" "$target" )
    rc=$?
    set -e
    if [[ "$rc" == "0" ]]; then
      log_info "処理成功: $target"
      successes+=("$target")
    else
      log_error "処理失敗: $target"
      failures+=("$target")
    fi
  done <<< "$target_output"

  log_info "成功: ${#successes[@]} 台 / 失敗: ${#failures[@]} 台"
  if ((${#successes[@]} > 0)); then
    printf '成功: %s\n' "${successes[*]}" >&2
  fi
  if ((${#failures[@]} > 0)); then
    printf '失敗: %s\n' "${failures[*]}" >&2
    return 1
  fi
  return 0
}
