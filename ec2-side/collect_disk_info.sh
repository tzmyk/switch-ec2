#!/usr/bin/env bash
set -euo pipefail

# 踏み台EC2側のディスク情報収集スクリプト。
# 役割: CloudShell からOS接続できない制約下で、踏み台EC2から対象EC2へSSHし、UUID/blkid/OS情報を実測保存する。
# 前提: hosts.txt と ssh.env が ec2-side/ 配下に存在し、踏み台EC2から全対象EC2へSSH可能であること。
# 生成する状態ファイル: work/<ホスト>/<phase>_lsblk.txt, <phase>_blkid.txt, <phase>_os_release.txt。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK_DIR="$SCRIPT_DIR/work"
HOSTS_FILE="$SCRIPT_DIR/hosts.txt"
SSH_ENV_FILE="$SCRIPT_DIR/ssh.env"

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

# 目的: hosts.txt から空行とコメント行を除いて対象ホストを列挙する。
# 引数: なし / 出力: stdout に対象ホストを1行ずつ。
read_hosts() {
  awk '!/^[[:space:]]*($|#)/ { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }' "$HOSTS_FILE"
}

# 目的: ホスト名/IPをディレクトリ名として安全な文字列へ寄せる。
# 引数: ホスト名/IP / 出力: stdout にディレクトリ名。
host_dir_name() {
  local host=$1
  printf '%s\n' "${host//[^[:alnum:]._-]/_}"
}

# 目的: ssh コマンドの共通引数を配列に組み立てる。
# 引数: なし / 出力: グローバル SSH_ARGS。
build_ssh_args() {
  # -n: ssh の stdin を必ず /dev/null に切り離す。
  # これが無いと、呼び出し元 while ループの stdin（hosts.txt の残り）を ssh が吸い込み、2台目以降のホストが処理されない。
  SSH_ARGS=(-n -p "$SSH_PORT")
  if [[ -n "${SSH_KEY:-}" ]]; then
    SSH_ARGS+=(-i "$SSH_KEY")
  fi
  if [[ -n "${SSH_OPTS:-}" ]]; then
    # SSH_OPTS は単純な空白区切りを想定する。クォートが必要な複雑な値は ssh_config 側へ寄せる。
    read -r -a extra_opts <<< "$SSH_OPTS"
    SSH_ARGS+=("${extra_opts[@]}")
  fi
}

# 目的: 同 phase の既存ファイルがある場合に上書き警告を出す。
# 引数: ファイルパス / 出力: stderr に警告。
warn_if_overwrite() {
  local file=$1
  if [[ -f "$file" ]]; then
    log_warn "既存ファイルを上書きします: $file"
  fi
}

# 目的: 1台の対象EC2から lsblk/blkid/redhat-release を収集する。
# 引数: phase, ホスト名/IP / 出力: work/<ホスト>/ 配下に収集ファイル。
collect_host() {
  local phase=$1
  local host=$2
  local safe_host out_dir target lsblk_file blkid_file os_file lsblk_tmp blkid_tmp os_tmp
  safe_host=$(host_dir_name "$host")
  out_dir="$WORK_DIR/$safe_host"
  target="${SSH_USER}@${host}"
  lsblk_file="$out_dir/${phase}_lsblk.txt"
  blkid_file="$out_dir/${phase}_blkid.txt"
  os_file="$out_dir/${phase}_os_release.txt"
  mkdir -p "$out_dir"

  if [[ "$phase" == "before" && "$FORCE" != "true" \
    && ( -f "$lsblk_file" || -f "$blkid_file" || -f "$os_file" ) ]]; then
    log_error "before の既存収集結果があります。上書きする場合のみ第2引数に --force を指定してください: $out_dir"
    return 1
  fi
  warn_if_overwrite "$lsblk_file"
  warn_if_overwrite "$blkid_file"
  warn_if_overwrite "$os_file"

  lsblk_tmp="${lsblk_file}.tmp.$$"
  blkid_tmp="${blkid_file}.tmp.$$"
  os_tmp="${os_file}.tmp.$$"
  rm -f "$lsblk_tmp" "$blkid_tmp" "$os_tmp"

  log_info "収集開始: host=$host phase=$phase"
  # lsblk はUUID比較の主情報。ここが取れない場合は対象ホスト失敗として扱う。
  # -P は KEY="value" ペア形式。-r（raw）だと SERIAL/UUID が空の行で列がずれ、パースが曖昧になるため使わない。
  if ! ssh "${SSH_ARGS[@]}" "$target" 'lsblk -nP -b -o NAME,SERIAL,UUID,FSTYPE,SIZE' > "$lsblk_tmp"; then
    rm -f "$lsblk_tmp" "$blkid_tmp" "$os_tmp"
    return 1
  fi
  # blkid は補助情報。sudo 不可や権限不足でも全体処理は継続する。
  if ! ssh "${SSH_ARGS[@]}" "$target" 'sudo -n blkid 2>/dev/null || blkid 2>/dev/null || true' > "$blkid_tmp"; then
    rm -f "$lsblk_tmp" "$blkid_tmp" "$os_tmp"
    return 1
  fi
  # 旧OSディスクで起動している証跡として、redhat-release は完全一致比較に使う。
  if ! ssh "${SSH_ARGS[@]}" "$target" 'cat /etc/redhat-release' > "$os_tmp"; then
    rm -f "$lsblk_tmp" "$blkid_tmp" "$os_tmp"
    return 1
  fi
  if [[ ! -s "$lsblk_tmp" || ! -s "$os_tmp" ]]; then
    log_error "必須収集結果が空です: host=$host phase=$phase"
    rm -f "$lsblk_tmp" "$blkid_tmp" "$os_tmp"
    return 1
  fi
  mv -f "$lsblk_tmp" "$lsblk_file"
  mv -f "$blkid_tmp" "$blkid_file"
  mv -f "$os_tmp" "$os_file"
  log_info "収集成功: host=$host phase=$phase"
}

# 目的: 引数・設定を読み込み、hosts.txt の全対象へ収集処理を適用する。
# 引数: before|after, 任意の --force / 出力: 成功/失敗サマリ、失敗が1台以上あれば終了コード1。
main() {
  if [[ $# -lt 1 || $# -gt 2 || ! "$1" =~ ^(before|after)$ || ( $# -eq 2 && "$2" != "--force" ) ]]; then
    printf 'Usage: %s <before|after> [--force]\n' "$0" >&2
    return 2
  fi
  if [[ ! -f "$HOSTS_FILE" ]]; then
    log_error "hosts.txt がありません。hosts.txt.example をコピーして対象ホストを記載してください。"
    return 1
  fi
  if [[ ! -f "$SSH_ENV_FILE" ]]; then
    log_error "ssh.env がありません。ssh.env.example をコピーしてSSH設定を記載してください。"
    return 1
  fi

  # shellcheck source=/dev/null
  source "$SSH_ENV_FILE"
  : "${SSH_USER:=ec2-user}"
  : "${SSH_KEY:=}"
  : "${SSH_PORT:=22}"
  : "${SSH_OPTS:=}"
  build_ssh_args

  local phase=$1
  FORCE=false
  if [[ "${2:-}" == "--force" ]]; then
    FORCE=true
    log_warn "--force を指定したため既存の収集結果を上書きします。"
  fi
  local successes=()
  local failures=()
  local host rc
  mkdir -p "$WORK_DIR"
  while IFS= read -r host; do
    [[ -n "$host" ]] || continue
    # サブシェルで errexit を復元して実行する。
    # set +e のまま関数を直接呼ぶと関数内部でも errexit が無効になり、ssh 失敗が最後の log_info の終了コード0に握り潰される。
    set +e
    ( set -eEuo pipefail; collect_host "$phase" "$host" )
    rc=$?
    set -e
    if [[ "$rc" == "0" ]]; then
      successes+=("$host")
    else
      log_error "収集失敗: host=$host phase=$phase"
      failures+=("$host")
    fi
  done < <(read_hosts)

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

main "$@"
