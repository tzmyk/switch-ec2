#!/usr/bin/env bash
set -euo pipefail

# 踏み台EC2側のディスク情報比較スクリプト。
# 役割: 切替前後に踏み台EC2で収集した lsblk/redhat-release を比較し、旧EBS/旧OSディスクで起動していることを確認する。
# 前提: collect_disk_info.sh before と collect_disk_info.sh after が同じ hosts.txt に対して完了していること。
# 生成する状態ファイル: work/<ホスト>/before_volume_uuid_map.txt, after_volume_uuid_map.txt。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK_DIR="$SCRIPT_DIR/work"
HOSTS_FILE="$SCRIPT_DIR/hosts.txt"

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

# 目的: lsblk の KEY="value" ペア出力（-P）を EBSボリュームID -> UUID の対応表へ正規化する。
# 引数: lsblk出力ファイル / 出力: stdout に "vol-... UUID" をソート済みで出力。
# 入力例: NAME="nvme0n1p1" SERIAL="" UUID="abcd-1234" FSTYPE="xfs" SIZE="8588886016"
# 出力例: vol-0abc123... abcd-1234
normalize_volume_uuid_map() {
  local file=$1
  awk '
    # 目的: KEY="value" 形式の行から指定キーの値を取り出す（値が空なら空文字を返す）。
    function kv(key) {
      if (match($0, key "=\"[^\"]*\"")) {
        return substr($0, RSTART + length(key) + 2, RLENGTH - length(key) - 3)
      }
      return ""
    }
    {
      name = kv("NAME")
      serial = kv("SERIAL")
      uuid = kv("UUID")
      if (serial ~ /^vol/) {
        # NVMe の SERIAL は "vol0abc..." 形式で、EBS API のボリュームID "vol-0abc..." に対応する。
        volume_id = "vol-" substr(serial, 4)
        # パーティション行の引き当て用に、ディスク名 -> ボリュームID を記録しておく（lsblk はディスク行が先に出力される）。
        disk_volume[name] = volume_id
      } else {
        # パーティション行（例: nvme0n1p1）は SERIAL が空のため、名前の前方一致で親ディスク（nvme0n1）の所属ボリュームを引き当てる。
        volume_id = ""
        matched_len = 0
        for (disk_name in disk_volume) {
          if (name != disk_name && index(name, disk_name) == 1 && length(disk_name) > matched_len) {
            volume_id = disk_volume[disk_name]
            matched_len = length(disk_name)
          }
        }
      }
      # ファイルシステムを持つ行（UUIDあり）だけを比較対象にする。
      if (volume_id != "" && uuid != "") {
        print volume_id, uuid
      }
    }
  ' "$file" | sort
}

# 目的: 必須収集ファイルが存在することを確認する。
# 引数: ファイルパス / 出力: 不足時はエラー。
need_file() {
  [[ -f "$1" ]] || {
    printf '[FAIL] 必須ファイルがありません: %s\n' "$1"
    return 1
  }
}

# 目的: 1台の対象EC2について before/after のUUID対応表とOSリリースを比較する。
# 引数: ホスト名/IP / 出力: ホストごとの PASS/FAIL と差分。
compare_host() {
  local host=$1
  local safe_host out_dir before_lsblk after_lsblk before_os after_os before_map after_map host_failed=0
  safe_host=$(host_dir_name "$host")
  out_dir="$WORK_DIR/$safe_host"
  before_lsblk="$out_dir/before_lsblk.txt"
  after_lsblk="$out_dir/after_lsblk.txt"
  before_os="$out_dir/before_os_release.txt"
  after_os="$out_dir/after_os_release.txt"
  before_map="$out_dir/before_volume_uuid_map.txt"
  after_map="$out_dir/after_volume_uuid_map.txt"

  printf '\n=== %s 検証 ===\n' "$host"
  need_file "$before_lsblk" || host_failed=1
  need_file "$after_lsblk" || host_failed=1
  need_file "$before_os" || host_failed=1
  need_file "$after_os" || host_failed=1
  if [[ "$host_failed" == "1" ]]; then
    printf '[FAIL] %s 収集ファイル不足\n' "$host"
    return 1
  fi

  normalize_volume_uuid_map "$before_lsblk" > "$before_map"
  normalize_volume_uuid_map "$after_lsblk" > "$after_map"

  if [[ ! -s "$before_map" || ! -s "$after_map" ]]; then
    printf '[FAIL] %s UUID対応表が空。NVMe 以外のインスタンスタイプ（Xen 世代）では SERIAL からボリュームIDを特定できない\n' "$host"
    host_failed=1
  elif diff -u "$before_map" "$after_map"; then
    printf '[PASS] %s EBSボリュームIDごとのファイルシステムUUID一致\n' "$host"
  else
    printf '[FAIL] %s EBSボリュームIDごとのファイルシステムUUID不一致\n' "$host"
    host_failed=1
  fi

  if diff -u "$before_os" "$after_os"; then
    printf '[PASS] %s /etc/redhat-release 完全一致: %s\n' "$host" "$(awk 'NR==1 {print; exit}' "$before_os")"
  else
    printf '[FAIL] %s /etc/redhat-release 不一致\n' "$host"
    host_failed=1
  fi

  if [[ "$host_failed" == "0" ]]; then
    printf '[SUMMARY] %s PASS\n' "$host"
    return 0
  fi
  printf '[SUMMARY] %s FAIL\n' "$host"
  return 1
}

# 目的: hosts.txt の全対象について比較し、全体サマリを返す。
# 引数: なし / 出力: 全体PASS/FAIL、失敗が1台以上あれば終了コード1。
main() {
  if [[ ! -f "$HOSTS_FILE" ]]; then
    printf '[FAIL] hosts.txt がありません。hosts.txt.example をコピーして対象ホストを記載してください。\n' >&2
    return 1
  fi

  local successes=()
  local failures=()
  local host rc
  while IFS= read -r host; do
    [[ -n "$host" ]] || continue
    set +e
    compare_host "$host"
    rc=$?
    set -e
    if [[ "$rc" == "0" ]]; then
      successes+=("$host")
    else
      failures+=("$host")
    fi
  done < <(read_hosts)

  printf '\n[SUMMARY] 全体: PASS=%s FAIL=%s\n' "${#successes[@]}" "${#failures[@]}"
  if ((${#failures[@]} > 0)); then
    printf '[SUMMARY] 全体FAIL: %s\n' "${failures[*]}"
    return 1
  fi
  printf '[SUMMARY] 全体PASS\n'
  return 0
}

main "$@"
