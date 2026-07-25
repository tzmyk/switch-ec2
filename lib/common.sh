#!/usr/bin/env bash
set -euo pipefail

# 共通ライブラリ。
# 役割: 各スクリプトから使う設定読込、ログ・時間計測、AWS CLI ラッパー、待機、対象一覧処理（逐次/並行）を集約する。
# 前提: 呼び出し元が config.env と targets.txt を同じディレクトリ基準で用意し、load_config 後に使う。
# 生成する状態ファイル: 対象ごとの <SCRIPT_NAME>.log と timings_<SCRIPT_NAME>.tsv（run_targets 系が作成）。
# それ以外の状態ファイルは呼び出し元スクリプトが生成する。

# --- ログ・時間計測用のグローバル ---
# SCRIPT_START_EPOCH: ライブラリ読込時刻。ログ行の経過秒 [+123s] の基準。
# SCRIPT_NAME: ログファイル名・計測ファイル名に使うスクリプト名。
# LOG_PREFIX: ログ行に入れる対象識別子。並行実行時に対象インスタンスIDを入れる。
# LOG_FILES: ログ行を追記するファイルの配列。全体ログと対象別ログの両方へ書けるよう配列にする。
# TIMINGS_FILE: ステップ所要時間を TSV で追記するファイル。
SCRIPT_START_EPOCH=$(date +%s)
SCRIPT_NAME=${SCRIPT_NAME:-$(basename -- "${0%.sh}")}
LOG_PREFIX=${LOG_PREFIX:-}
LOG_FILES=()
TIMINGS_FILE=${TIMINGS_FILE:-}
declare -A _TIMER_START=()

# 目的: ログ時刻をローカルタイムゾーン付きで返す。
# 引数: なし / 出力: stdout に YYYY-MM-DD HH:MM:SS+TZ。
log_ts() { date '+%Y-%m-%d %H:%M:%S%z'; }

# 目的: スクリプト開始からの経過秒を返す。
# 引数: なし / 出力: stdout に経過秒。
log_elapsed() { printf '%s\n' "$(( $(date +%s) - SCRIPT_START_EPOCH ))"; }

# 目的: 整形済みの1行を stderr と LOG_FILES の各ファイルへ出す。
# 引数: 出力する行 / 出力: stderr と LOG_FILES。
# 注意: 並行実行では複数プロセスが同じログファイルへ追記する。追記モード（>>）の1行 printf は
#       PIPE_BUF 以下ならほぼ原子的に書かれるため、ロックや tee は使わずに済ませる。
_log_raw() {
  local line=$1
  local file
  printf '%s\n' "$line" >&2
  # 空配列でも set -u で落ちないよう :- を付ける。展開結果の空要素は下でスキップする。
  for file in "${LOG_FILES[@]:-}"; do
    [[ -n "$file" ]] || continue
    printf '%s\n' "$line" >> "$file"
  done
}

# 目的: 日時・経過秒・レベル・対象を付けたログ1行を出す。
# 引数: レベル文字列, メッセージ / 出力: stderr と LOG_FILES。
_log_emit() {
  local level=$1
  shift
  _log_raw "$(printf '[%s] [+%ss] [%s]%s %s' \
    "$(log_ts)" "$(log_elapsed)" "$level" "${LOG_PREFIX:+ [$LOG_PREFIX]}" "$*")"
}

# 目的: 情報ログを出す。
# 引数: メッセージ / 出力: stderr と LOG_FILES。
log_info() { _log_emit INFO "$*"; }
# 目的: 警告ログを出す。
# 引数: メッセージ / 出力: stderr と LOG_FILES。
log_warn() { _log_emit WARN "$*"; }
# 目的: エラーログを出す。
# 引数: メッセージ / 出力: stderr と LOG_FILES。
log_error() { _log_emit ERROR "$*"; }

# 目的: 名前付きタイマーを開始する。
# 引数: タイマー名 / 出力: なし。
timer_start() {
  _TIMER_START[$1]=$(date +%s)
}

# 目的: 名前付きタイマーを終了し、所要秒をログと TIMINGS_FILE へ記録する。
# 引数: タイマー名, 表示名（省略時はタイマー名） / 出力: stderr のログと TIMINGS_FILE への追記。
# 注意: 計測漏れで本処理を止めないため、未開始タイマーは警告だけ出して成功扱いで返す。
timer_end() {
  local name=$1
  local label=${2:-$1}
  local start seconds
  start=${_TIMER_START[$name]:-}
  if [[ -z "$start" ]]; then
    log_warn "タイマーが開始されていません: $name"
    return 0
  fi
  unset "_TIMER_START[$name]"
  seconds=$(( $(date +%s) - start ))
  log_info "$label 完了 (${seconds}s)"
  if [[ -n "${TIMINGS_FILE:-}" ]]; then
    printf '%s\t%s\n' "$name" "$seconds" >> "$TIMINGS_FILE"
  fi
}

# 目的: 計測結果 TSV の内訳と合計を表示する。
# 引数: TSVファイルパス, 見出し（省略可） / 出力: stderr と LOG_FILES に整形済みサマリ。
# 注意: 桁揃えが崩れないよう、内訳の項目名と合計ラベルは ASCII に揃える。
timings_summary() {
  local file=${1:-}
  local heading=${2:-所要時間 内訳}
  [[ -n "$file" && -f "$file" ]] || return 0
  local name seconds
  local total=0
  log_info "$heading"
  while IFS=$'\t' read -r name seconds; do
    [[ -n "$name" ]] || continue
    _log_raw "$(printf '  %-30s %6ss' "$name" "$seconds")"
    total=$(( total + seconds ))
  done < "$file"
  _log_raw "$(printf '  %-30s %6ss' "TOTAL" "$total")"
}

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
  : "${MAX_PARALLEL:=4}"

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

# 目的: describe 結果を切替前後の手動 diff に耐える安定順序へ正規化する。
# 引数: 種別（instances|volumes|enis） / 入力: stdin に describe JSON / 出力: stdout に正規化 JSON。
# 注意: 差分確認が目的なので、フィールドの削除も追加もしない。キー順は jq -S に任せ、
#       AWS が順序を保証しない配列だけを並べ替える。
#       ヘルパー sk は「そのキーが実際に配列で存在するときだけ並べ替える」。単純な .Key |= f だと
#       キーが無い入力に null のキーを作ってしまい、describe 全文としての正確さが崩れるため。
normalize_describe_json() {
  local kind=$1
  case "$kind" in
    instances)
      jq -S '
        def sk(k; f): if (type == "object" and has(k) and (.[k] | type) == "array") then .[k] |= sort_by(f) else . end;
        sk("Reservations";
          [.Instances[]?.InstanceId]
        )
        | if (type == "object" and has("Reservations") and (.Reservations | type) == "array") then
            .Reservations |= map(
              sk("Instances"; .InstanceId)
              | if (has("Instances") and (.Instances | type) == "array") then
                  .Instances |= map(
                      sk("BlockDeviceMappings"; .DeviceName)
                    | sk("SecurityGroups"; .GroupId)
                    | sk("ProductCodes"; .ProductCodeId)
                    | sk("Tags"; [.Key, .Value])
                    | if (has("NetworkInterfaces") and (.NetworkInterfaces | type) == "array") then
                        .NetworkInterfaces |= (
                          map(
                              sk("Groups"; .GroupId)
                            | sk("PrivateIpAddresses"; .PrivateIpAddress)
                            | sk("Ipv6Addresses"; .Ipv6Address)
                          )
                          | sort_by([.Attachment.DeviceIndex, .NetworkInterfaceId])
                        )
                      else . end
                  )
                else . end
            )
          else . end
      '
      ;;
    volumes)
      jq -S '
        def sk(k; f): if (type == "object" and has(k) and (.[k] | type) == "array") then .[k] |= sort_by(f) else . end;
        if (type == "object" and has("Volumes") and (.Volumes | type) == "array") then
          .Volumes |= (
            map(
                sk("Attachments"; [.Device, .InstanceId])
              | sk("Tags"; [.Key, .Value])
            )
            | sort_by(.VolumeId)
          )
        else . end
      '
      ;;
    enis)
      jq -S '
        def sk(k; f): if (type == "object" and has(k) and (.[k] | type) == "array") then .[k] |= sort_by(f) else . end;
        if (type == "object" and has("NetworkInterfaces") and (.NetworkInterfaces | type) == "array") then
          .NetworkInterfaces |= (
            map(
                sk("Groups"; .GroupId)
              | sk("PrivateIpAddresses"; .PrivateIpAddress)
              | sk("Ipv6Addresses"; .Ipv6Address)
              | sk("TagSet"; [.Key, .Value])
            )
            | sort_by(.NetworkInterfaceId)
          )
        else . end
      '
      ;;
    *)
      die "normalize_describe_json: 不明な種別です: $kind"
      ;;
  esac
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

# 目的: 対象1台分のログ出力先と計測ファイルを設定する。
# 引数: 対象インスタンスID / 出力: LOG_PREFIX, LOG_FILES, TIMINGS_FILE を設定し状態ディレクトリを作成。
# 注意: 対象ごとのサブシェル内で呼ぶこと。並行実行時に画面のログが混ざっても、
#       対象別ログファイルだけを読めば1台分の流れを追えるようにするため。
setup_target_logging() {
  local target=$1
  local dir
  dir=$(state_dir "$target")
  mkdir -p "$dir"
  LOG_PREFIX="$target"
  LOG_FILES+=("$dir/${SCRIPT_NAME}.log")
  TIMINGS_FILE="$dir/timings_${SCRIPT_NAME}.tsv"
  # 再実行時に前回の計測値と混ざらないよう、対象単位で作り直す。
  : > "$TIMINGS_FILE"
}

# 目的: 逐次・並行の両実行方式で共通の成功/失敗サマリを出力する。
# 引数: 全体所要秒, 成功ID列（空白区切り）, 失敗ID列（空白区切り）
# 出力: stderr にサマリ、失敗が1台以上あれば終了コード1。
report_targets_summary() {
  local total_seconds=$1
  local successes_str=${2:-}
  local failures_str=${3:-}
  local -a successes=() failures=()
  # インスタンスIDに空白は含まれないため、空白区切りの再分割で安全に扱える。
  read -r -a successes <<< "$successes_str"
  read -r -a failures <<< "$failures_str"
  log_info "成功: ${#successes[@]} 台 / 失敗: ${#failures[@]} 台 / 全体 ${total_seconds}s"
  if ((${#successes[@]} > 0)); then
    printf '成功: %s\n' "${successes[*]}" >&2
  fi
  if ((${#failures[@]} > 0)); then
    printf '失敗: %s\n' "${failures[*]}" >&2
    return 1
  fi
  return 0
}

# 目的: targets.txt の各対象に同じハンドラを逐次適用し、1台失敗しても残りを処理して最後にサマリを返す。
# 引数: ハンドラ関数名 / 出力: stderr に成功/失敗サマリ、失敗が1台以上あれば終了コード1。
# 注意: この関数を if や || の条件として呼ばないこと。bash は条件文脈で errexit を抑止し、その抑止が
#       下のサブシェルへ伝播して set -e を無効化するため、ハンドラ内の途中失敗を見逃す（bash 5.0 で確認）。
#       main から直接呼び、終了コードはスクリプトの終了コードとして扱うこと。
run_targets() {
  # local - でシェルオプションの変更を関数内に閉じる。下の set +e / set -e が呼び出し元へ漏れると、
  # 呼び出し元が終了コードで分岐しようとしても errexit でシェルごと終了してしまうため。
  local -
  local handler=$1
  local successes=()
  local failures=()
  local target
  local target_output
  local rc start_epoch elapsed
  if ! target_output=$(read_targets); then
    return 1
  fi
  local run_start
  run_start=$(date +%s)
  # 複数台の一括切替では、途中の1台失敗で全体を止めるより、成功/失敗を最後に一覧化する方が復旧判断しやすい。
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    log_info "処理開始: $target"
    start_epoch=$(date +%s)
    set +e
    ( set -eEuo pipefail; setup_target_logging "$target"; "$handler" "$target" )
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
  done <<< "$target_output"

  # ここは set -e が有効なので、サマリの失敗（=1台以上失敗）でシェルが即終了しないよう
  # || で受けて明示的に return する。呼び出し元が終了コードで分岐できるようにするため。
  local summary_rc=0
  report_targets_summary "$(( $(date +%s) - run_start ))" "${successes[*]:-}" "${failures[*]:-}" || summary_rc=$?
  return "$summary_rc"
}

# 目的: targets.txt の各対象を最大 max 台まで並行処理する。
# 引数: 最大同時実行数, 子プロセスのコマンド列（末尾に対象IDを付けて実行される）
# 出力: stderr に成功/失敗サマリ、失敗が1台以上あれば終了コード1。
# 注意1: 対象ごとの処理はサブシェル ( ... ) & ではなく独立した子プロセスとして起動する。
#        bash は if や || の条件として関数を呼ぶと errexit を一時的に抑止し、その抑止が
#        サブシェルへ伝播して内側の set -e を無効化する（bash 5.0 で確認。$- では検出できない）。
#        破壊的操作の途中失敗を見逃さないため、プロセス境界で errexit の状態を切り離す。
# 注意2: 同時実行数の制御に jobs -rp を使うため、呼び出し元がこの関数以外のバックグラウンド
#        ジョブを持たないこと。
# 注意3: 子プロセスは stdin を /dev/null へ切り離して起動する。対象一覧や /dev/tty を複数
#        プロセスで奪い合わないようにするため（対話確認は呼び出し元が fan-out 前に済ませる前提）。
run_targets_parallel() {
  # シェルオプションの変更を関数内に閉じる（理由は run_targets と同じ）。
  local -
  local max=$1
  shift
  local -a child_cmd=("$@")
  local target target_output rc i
  local -a targets=() pids=() names=()
  local successes=() failures=()
  if ! target_output=$(read_targets); then
    return 1
  fi
  mapfile -t targets <<< "$target_output"
  local run_start
  run_start=$(date +%s)
  log_info "並行実行モード: 同時実行数=$max"
  for target in "${targets[@]}"; do
    [[ -n "$target" ]] || continue
    while (( $(jobs -rp | wc -l) >= max )); do
      sleep 1
    done
    log_info "処理開始: $target"
    "${child_cmd[@]}" "$target" </dev/null &
    pids+=("$!")
    names+=("$target")
  done
  # 起動順に wait して個別の終了コードを回収する（一時ファイル不要）。
  for i in "${!pids[@]}"; do
    set +e
    wait "${pids[$i]}"
    rc=$?
    set -e
    if [[ "$rc" == "0" ]]; then
      log_info "処理成功: ${names[$i]}"
      successes+=("${names[$i]}")
    else
      log_error "処理失敗: ${names[$i]} (終了コード $rc)"
      failures+=("${names[$i]}")
    fi
  done

  local summary_rc=0
  report_targets_summary "$(( $(date +%s) - run_start ))" "${successes[*]:-}" "${failures[*]:-}" || summary_rc=$?
  return "$summary_rc"
}
