#!/usr/bin/env bash
set -euo pipefail

# 新規作成リソースのタグ付けスクリプト（オプショナルな後処理）。
# 役割: 01〜04 の正常系で新規作成された AWS リソース（バックアップAMI、そのスナップショット、
#       切替後の新EC2、新AMI由来の破棄予定ルートEBS）へ運用タグを付与する。
# 前提: 01_prepare.sh → 02_backup.sh → 03_switch.sh → 04_verify.sh を完走していること。
#       切り戻し（05_rollback.sh）が実行された対象は対象外。
# 生成する状態ファイル: tag_denylist.txt, tag_allowlist.tsv, tag_plan.json, tag_applied.json,
# tag_backup_ami.json, 90_tag_resources.log, timings_90_tag_resources.tsv。
#
# 既存リソース（旧EBS・旧ENI・旧EC2）には一切タグを付けない。これは運用ルールではなく
# allowlist ∧ ¬denylist の二重判定として実装で強制する（下の assert_taggable を参照）。
#
# 番号を 90 にしているのは、このスクリプトが必須フロー（01〜06）ではなく
# 任意の後処理であることを実行順の見た目で示すため。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# ===== タグ定義（運用タグ体系が確定したらこのブロックだけを書き換える）=====
#
# 目的: 90 が付与するタグのキーと値を一箇所に集約する。
# 引数: 役割名, 旧EC2インスタンスID, 状態ディレクトリ（固定タグのため未使用）
# 出力: stdout に "Key=K,Value=V" を1行ずつ。
# 注意: 全リソースに同じ固定タグを付ける。タグを増やすときはキーと値の組を printf の引数に追加する。
#       値にカンマ・空白は使えない（create-tags の Key=,Value= ショートハンドの制約）。
build_tags() {
  printf 'Key=%s,Value=%s\n' \
    MyTag "MyValue"
}

# 02/03 が作成時に付与済みのタグキー。90 はこれらを絶対に書き換えない。
# 02_backup.sh:48-49 の Purpose/SourceInstanceId/CreatedAt、03_switch.sh:399-404 の
# Name/Purpose/DeleteAfterVerification/SourceOldInstanceId/NewInstanceId を保護する。
RESERVED_TAG_KEYS=(
  Name Purpose CreatedAt SourceInstanceId SourceOldInstanceId
  NewInstanceId DeleteAfterVerification
)
# ===== タグ定義ここまで =====

# 目的: 90 専用のコマンドラインオプションを解釈する。
# 引数: コマンドライン引数 / 出力: グローバル YES, DRY_RUN, SKIP_ORDER_CHECK, TAG_INSTANCES を設定。
# 注意: parse_yes_flag は 01/02/04/06 と共用のため拡張しない。固有オプションを持つスクリプトが
#       専用パーサを持つのは 03/05 と同じ方針（03_switch.sh:23 のコメント参照）。
parse_tag_flags() {
  YES=false
  DRY_RUN=false
  SKIP_ORDER_CHECK=false
  TAG_INSTANCES=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) YES=true ;;
      --dry-run) DRY_RUN=true ;;
      --skip-order-check) SKIP_ORDER_CHECK=true ;;
      --no-instance-tags) TAG_INSTANCES=false ;;
      -h|--help)
        printf 'Usage: %s [--yes] [--dry-run] [--no-instance-tags] [--skip-order-check]\n' "$0"
        printf '  --yes                確認プロンプトを省略する\n'
        printf '  --dry-run            付与予定のタグを表示するだけで create-tags を発行しない\n'
        printf '  --no-instance-tags   EC2 インスタンスへのタグ付けを行わない\n'
        printf '                       （04_verify.sh のタグ一致判定に影響しなくなるため実行順の制約が外れる）\n'
        printf '  --skip-order-check   04_verify.sh の完了証跡チェックを警告に格下げする\n'
        exit 0
        ;;
      *) die "不明なオプションです: $1" ;;
    esac
    shift
  done
}

# 目的: 正常系（01〜04）を完走した状態であることを確認し、切り戻し済みの対象を弾く。
# 引数: 状態ディレクトリ / 出力: 前提を満たさない場合はエラー。
# 注意1: 05_rollback.sh は新EC2を terminate する（05_rollback.sh:321-331）。切り戻し後は
#        new_instance_id.txt の指す先が存在しないため、そこへ create-tags を打つと必ず失敗する。
#        90 は正常系専用の後処理であり、切り戻しが発生した対象は無条件で対象外とする。
# 注意2: 04_verify.sh は PASS/FAIL を標準出力に出すだけで状態ファイルに残さないため、90 が
#        判定できるのは「04 が最後まで走った」ことまでで、「全項目 PASS だった」かは判定できない。
#        この限界は main の確認プロンプトで運用者に明示し、目視確認を促す。
assert_normal_flow_done() {
  local dir=$1
  if [[ -e "$dir/rollback_instance_id.txt" ]]; then
    die "切り戻し済みのため対象外です（90 は正常系完走時のみ実行できます）: $dir/rollback_instance_id.txt が存在します"
  fi

  local -a missing=()
  # timings_04_verify.tsv は setup_target_logging が対象処理の開始時に必ず作る（中身は空でも可）。
  # verify_new_tags.normalized.json は 04 のステップ4（タグ比較）まで到達した証拠。
  [[ -f "$dir/timings_04_verify.tsv" ]]           || missing+=("timings_04_verify.tsv")
  [[ -f "$dir/verify_new_tags.normalized.json" ]] || missing+=("verify_new_tags.normalized.json")
  # ((...)) は条件が偽のとき終了コード1を返す。&& で繋ぐと set -e でサブシェルごと落ちるため if で書く。
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  if [[ "$SKIP_ORDER_CHECK" == "true" ]]; then
    log_warn "04_verify.sh の完了証跡がありません（--skip-order-check により続行）: ${missing[*]}"
    return 0
  fi
  die "04_verify.sh の完了証跡がありません: ${missing[*]}
90 が新EC2へタグを追加すると 04_verify.sh のタグ一致判定（04_verify.sh:131-137）が FAIL するため、
必ず 04_verify.sh の完了後に実行してください。
AMI・スナップショット・EBS だけにタグを付ける場合は --no-instance-tags で実行順の制約を回避できます。"
}

# 目的: 絶対にタグを付けてはいけない既存リソースIDを状態ファイルから列挙する。
# 引数: 旧EC2インスタンスID, 状態ディレクトリ / 出力: stdout にID1行ずつ（重複排除・ソート済み）。
# 注意: 03_switch.sh は ENI を新規作成せず、既存IDを --network-interfaces で再利用するだけ
#       （03_switch.sh:288）。したがって登場する ENI は常に既存リソースであり全件が denylist に入る。
build_denylist() {
  local old_instance_id=$1
  local dir=$2
  {
    printf '%s\n' "$old_instance_id"
    jq -r '.[].VolumeId'           "$dir/block_devices.json"
    jq -r '.[].NetworkInterfaceId' "$dir/enis.json"
    # 状態ファイルの取りこぼしに備え、旧EC2の describe 全文からも直接拾う。
    jq -r '.Reservations[0].Instances[0].BlockDeviceMappings[]?.Ebs.VolumeId // empty'   "$dir/instance.json"
    jq -r '.Reservations[0].Instances[0].NetworkInterfaces[]?.NetworkInterfaceId // empty' "$dir/instance.json"
  } | awk 'NF' | sort -u
}

# 目的: denylist が保護すべき既存リソースを取りこぼしていないことを確認する。
# 引数: 旧EC2インスタンスID, 状態ディレクトリ / 出力: 取りこぼしがあればエラー。
# 注意: denylist は「作れたこと」ではなく「完全であること」が安全性の根拠になる。jq の失敗や
#       状態ファイルの切り詰めで一部が欠けると、その分だけ既存リソースが無防備になるため、
#       旧EBS・旧ENI・旧EC2が1件残らず登録されたことをここで突き合わせる。
# 注意: DENYLIST は process_target が local -A で宣言する（bash の動的スコープで参照する）。
assert_denylist_complete() {
  local old_instance_id=$1
  local dir=$2
  local expected
  local -a missing=()
  if [[ -z "${DENYLIST[$old_instance_id]:-}" ]]; then
    missing+=("$old_instance_id")
  fi
  while IFS= read -r expected; do
    [[ -n "$expected" ]] || continue
    if [[ -z "${DENYLIST[$expected]:-}" ]]; then
      missing+=("$expected")
    fi
  done < <(
    jq -r '.[].VolumeId'           "$dir/block_devices.json"
    jq -r '.[].NetworkInterfaceId' "$dir/enis.json"
  )
  # ((...)) は条件が偽のとき終了コード1を返す。&& で繋ぐと set -e で落ちるため if で書く。
  if ((${#missing[@]} > 0)); then
    die "denylist に登録されていない既存リソースがあります。状態ファイル破損の疑いがあるため中止します: ${missing[*]}"
  fi
}

# 目的: 新規作成されたリソースだけを役割付きで列挙する。
# 引数: 旧EC2インスタンスID, 状態ディレクトリ / 出力: stdout に "role<TAB>resource_id" を1行ずつ。
# 注意: 新EC2の describe から BlockDeviceMappings を舐めてはいけない。03 の方式では切替後の
#       新EC2にぶら下がる EBS は旧EBS（既存リソース）そのものであり、列挙すると対象に混入する。
#       新規作成分は必ず「作成時に記録された状態ファイル」から特定する。
collect_allowlist() {
  local dir=$1
  local backup_ami_id image_json

  # --- バックアップAMI と配下スナップショット ---
  backup_ami_id=$(<"$dir/backup_ami_id.txt")
  printf 'backup-ami\t%s\n' "$backup_ami_id"
  if image_json=$(aws_json ec2 describe-images --image-ids "$backup_ami_id" 2>/dev/null); then
    printf '%s\n' "$image_json" > "$dir/tag_backup_ami.json"
    jq -r '.Images[0].BlockDeviceMappings[]?.Ebs.SnapshotId // empty' "$dir/tag_backup_ami.json" \
      | awk 'NF { print "backup-snapshot\t" $0 }'
  else
    # deregister 済みなどで参照できない場合、スナップショットは特定できないが AMI 以外の処理は続行する。
    log_warn "バックアップAMIを describe できません。スナップショットへのタグ付けはスキップします: $backup_ami_id"
    jq -n '{Images: []}' > "$dir/tag_backup_ami.json"
  fi

  # --- 切替後の新EC2 ---
  if [[ "$TAG_INSTANCES" == "true" ]]; then
    need_file "$dir/new_instance_id.txt"
    printf 'new-instance\t%s\n' "$(<"$dir/new_instance_id.txt")"
  fi

  # --- run-instances が暗黙生成し 03 が切り離した新AMI由来のルートEBS ---
  if [[ -s "$dir/discarded_root_volume_id.txt" ]]; then
    printf 'discarded-root-volume\t%s\n' "$(<"$dir/discarded_root_volume_id.txt")"
  else
    log_warn "discarded_root_volume_id.txt がないため破棄予定ルートEBSはタグ付け対象外です: $dir"
  fi
}

# 目的: タグ付け対象IDが新規作成分であることを、ID形式・ENI除外・denylist の3観点で検査する。
# 引数: 役割名, リソースID / 出力: 違反時はエラー。
# 注意: DENYLIST は process_target が local -A で宣言する。bash の動的スコープでここから参照できる。
assert_taggable() {
  local role=$1
  local resource_id=$2
  local expected_prefix
  if [[ -z "$resource_id" || "$resource_id" == "null" ]]; then
    die "リソースIDが空です（状態ファイル破損の疑い）: role=$role"
  fi
  case "$role" in
    backup-ami)            expected_prefix="ami-"  ;;
    backup-snapshot)       expected_prefix="snap-" ;;
    new-instance)          expected_prefix="i-"    ;;
    discarded-root-volume) expected_prefix="vol-"  ;;
    *) die "未知の役割です: $role" ;;
  esac
  if [[ "$resource_id" != "$expected_prefix"* ]]; then
    die "役割とリソースIDの型が一致しません: role=$role id=$resource_id"
  fi
  # ENI は新規作成されない。混入した時点で状態ファイルかロジックの破綻なので必ず止める。
  if [[ "$resource_id" == eni-* ]]; then
    die "ENI はタグ付け対象外です（既存リソースの再利用のみ）: $resource_id"
  fi
  if [[ -n "${DENYLIST[$resource_id]:-}" ]]; then
    die "既存リソース（旧EBS/旧ENI/旧EC2）へタグを付けようとしました。中止します: role=$role id=$resource_id"
  fi
}

# 目的: 破棄予定ルートEBSが本当に切替先AMI由来かをAPI実測で証明する。
# 引数: ボリュームID / 出力: 由来を確認できない場合はエラー。
# 注意: denylist は「既知の既存リソースでないこと」しか言えない。こちらは「新規作成分であること」の
#       積極的証明であり、状態ファイル破損で allowlist が暴走した場合の最後の砦になる。
assert_created_from_new_ami() {
  local volume_id=$1
  local image_json volumes_json
  if ! image_json=$(aws_json ec2 describe-images --image-ids "$NEW_AMI_ID" 2>/dev/null); then
    log_warn "切替先AMI ($NEW_AMI_ID) を describe できないため、破棄予定ルートEBSの由来証明をスキップします。"
    return 0
  fi
  volumes_json=$(aws_json ec2 describe-volumes --volume-ids "$volume_id")
  # index(...) の中では . が $snaps（配列）を指すため、ボリューム側の SnapshotId を先に変数へ束縛する。
  # 直接 index(.SnapshotId) と書くと "Cannot index array with string" で落ちる。
  if ! jq -e --argjson ami "$image_json" '
      [$ami.Images[0].BlockDeviceMappings[]?.Ebs.SnapshotId // empty] as $snaps
      | [ .Volumes[]
          | (.SnapshotId // "") as $vol_snapshot
          | select(($snaps | index($vol_snapshot)) == null)
          | .VolumeId ]
      | length == 0
    ' <<<"$volumes_json" >/dev/null; then
    die "切替先AMI ($NEW_AMI_ID) 由来でないボリュームが対象に含まれています。タグ付けを中止します: $volume_id"
  fi
}

# 目的: config.env の TAG_EXTRA_TAGS を "Key=K,Value=V" 形式へ展開する。
# 引数: なし / 出力: stdout に "Key=K,Value=V" を1行ずつ（未設定なら何も出さない）。
# 注意: aws ec2 create-tags の Key=,Value= ショートハンドは値にカンマや空白を含められないため、
#       使用できる文字を絞って検証する。許可外の文字が来たら黙って壊れるより止める。
parse_extra_tags() {
  local spec=${TAG_EXTRA_TAGS:-}
  [[ -n "$spec" ]] || return 0
  if [[ ! "$spec" =~ ^[A-Za-z0-9._:/+@=,-]+$ ]]; then
    die "TAG_EXTRA_TAGS に使用できない文字が含まれています（許可: 英数 . _ : / + @ = , -）: $spec"
  fi
  local pair key value
  local IFS=,
  for pair in $spec; do
    [[ -n "$pair" ]] || continue
    key=${pair%%=*}
    value=${pair#*=}
    if [[ -z "$key" || "$key" == "$pair" ]]; then
      die "TAG_EXTRA_TAGS の形式が不正です（Key=Value をカンマ区切りで指定）: $pair"
    fi
    printf 'Key=%s,Value=%s\n' "$key" "$value"
  done
}

# 目的: 1リソースへ付与するタグ一式（定義ブロック + TAG_EXTRA_TAGS）を組み立てる。
# 引数: 役割名, 旧EC2インスタンスID, 状態ディレクトリ / 出力: stdout に "Key=K,Value=V" を1行ずつ。
# 注意: 純粋関数であること（同じ入力なら常に同じ出力）。計画の書き出しと実際の付与で2回呼ぶため、
#       ここに実行時依存の値が入ると計画と実結果がずれる。
build_all_tags() {
  local role=$1
  local old_instance_id=$2
  local dir=$3
  build_tags "$role" "$old_instance_id" "$dir"
  parse_extra_tags
}

# 目的: 付与しようとしているタグが 02/03 の管理キーや AWS 予約キーを侵していないか検査する。
# 引数: "Key=K,Value=V" 形式のタグ列 / 出力: 違反時はエラー。
# 注意: リソースID側の denylist と対になる「タグキー側の denylist」。02 の Purpose=switch-ec2-backup、
#       03 の Purpose=switch-ec2-discarded-root や DeleteAfterVerification を 90 が壊さないための歯止め。
assert_no_reserved_keys() {
  local spec key reserved
  for spec in "$@"; do
    key=${spec#Key=}
    key=${key%%,Value=*}
    if [[ -z "$key" ]]; then
      die "タグキーが空です: $spec"
    fi
    if [[ "$key" == aws:* ]]; then
      die "aws: で始まるタグキーは付与できません（AWS 予約タグ）: $key"
    fi
    for reserved in "${RESERVED_TAG_KEYS[@]}"; do
      if [[ "$key" == "$reserved" ]]; then
        die "02/03 が管理するタグキーを上書きしようとしました: $key"
      fi
    done
  done
}

# 目的: 1リソース分の付与計画を JSON オブジェクトとして出力する。
# 引数: 役割名, リソースID, "Key=K,Value=V" 形式のタグ列 / 出力: stdout に JSON 1行。
tag_plan_entry() {
  local role=$1
  local resource_id=$2
  shift 2
  printf '%s\n' "$@" | jq -R -s --arg role "$role" --arg id "$resource_id" '
    {
      Role: $role,
      ResourceId: $id,
      Tags: (split("\n") | map(select(length > 0)) | map(capture("^Key=(?<Key>[^,]+),Value=(?<Value>.*)$")))
    }'
}

# 目的: 1リソースへタグを付与する（dry-run 時は発行せず表示だけ）。
# 引数: 役割名, リソースID, "Key=K,Value=V" 形式のタグ列 / 出力: create-tags 発行とログ。
# 注意: アサートは dry-run でも必ず通す。dry-run の価値は「本番と同じガードを通した結果」を
#       事前に見せることにあるため、検査を飛ばすと意味がなくなる。
apply_tags() {
  local role=$1
  local resource_id=$2
  shift 2
  local -a tags=("$@")
  assert_taggable "$role" "$resource_id"
  assert_no_reserved_keys "${tags[@]}"
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[DRY-RUN] %-22s %-23s %s\n' "$role" "$resource_id" "${tags[*]}"
    return 0
  fi
  aws_json ec2 create-tags --resources "$resource_id" --tags "${tags[@]}" >/dev/null
  log_info "タグ付与: role=$role id=$resource_id"
}

# 目的: 1台分の新規作成リソースを特定し、ガードを通してタグを付与する。
# 引数: 旧EC2インスタンスID / 出力: tag_* 状態ファイルと create-tags の発行。
process_target() {
  local old_instance_id=$1
  local dir resource_id role
  local -a allow_lines=() tags=()
  # denylist は対象ごとに作り直す。assert_taggable が bash の動的スコープでこれを参照する。
  local -A DENYLIST=()

  dir=$(state_dir "$old_instance_id")
  need_file "$dir/instance.json"
  need_file "$dir/block_devices.json"
  need_file "$dir/enis.json"
  need_file "$dir/backup_ami_id.txt"
  need_file "$dir/backup_created_at.txt"

  # --- ステップ0: 前提条件と保護対象IDのガードを構築 ---
  timer_start step0_guard
  assert_normal_flow_done "$dir"
  build_denylist "$old_instance_id" "$dir" > "$dir/tag_denylist.txt"
  while IFS= read -r resource_id; do
    [[ -n "$resource_id" ]] || continue
    DENYLIST["$resource_id"]=1
  done < "$dir/tag_denylist.txt"
  assert_denylist_complete "$old_instance_id" "$dir"
  log_info "保護対象 ${#DENYLIST[@]} 件を denylist に登録しました: $dir/tag_denylist.txt"
  timer_end step0_guard "ステップ0 ガード構築"

  # --- ステップ1: 新規作成リソースを allowlist として特定 ---
  timer_start step1_collect
  mapfile -t allow_lines < <(collect_allowlist "$dir")
  if ((${#allow_lines[@]} == 0)); then
    die "タグ付け対象の新規リソースを特定できませんでした: $dir"
  fi
  printf '%s\n' "${allow_lines[@]}" > "$dir/tag_allowlist.tsv"
  log_info "タグ付け対象 ${#allow_lines[@]} 件を特定しました: $dir/tag_allowlist.tsv"
  timer_end step1_collect "ステップ1 新規リソース特定"

  # --- ステップ2: 破棄予定ルートEBSが切替先AMI由来であることをAPI実測で証明 ---
  timer_start step2_verify_origin
  while IFS=$'\t' read -r role resource_id; do
    [[ "$role" == "discarded-root-volume" ]] || continue
    assert_created_from_new_ami "$resource_id"
  done < "$dir/tag_allowlist.tsv"
  timer_end step2_verify_origin "ステップ2 由来証明"

  # --- ステップ3: 付与計画を書き出す（dry-run でも残す監査証跡） ---
  timer_start step3_plan
  : > "$dir/tag_plan.jsonl"
  while IFS=$'\t' read -r role resource_id; do
    [[ -n "$role" ]] || continue
    mapfile -t tags < <(build_all_tags "$role" "$old_instance_id" "$dir")
    tag_plan_entry "$role" "$resource_id" "${tags[@]}" >> "$dir/tag_plan.jsonl"
  done < "$dir/tag_allowlist.tsv"
  jq -s . "$dir/tag_plan.jsonl" > "$dir/tag_plan.json"
  rm -f "$dir/tag_plan.jsonl"
  timer_end step3_plan "ステップ3 付与計画の作成"

  # --- ステップ4: タグを付与 ---
  timer_start step4_apply
  while IFS=$'\t' read -r role resource_id; do
    [[ -n "$role" ]] || continue
    # build_all_tags は純粋関数なので、ステップ3で計画に書いた内容とここで付与する内容は一致する。
    mapfile -t tags < <(build_all_tags "$role" "$old_instance_id" "$dir")
    apply_tags "$role" "$resource_id" "${tags[@]}"
  done < "$dir/tag_allowlist.tsv"
  if [[ "$DRY_RUN" == "true" ]]; then
    # dry-run では実付与がないため tag_applied.json を作らない。前回の実行結果を誤って残さないよう消す。
    rm -f "$dir/tag_applied.json"
  else
    cp -- "$dir/tag_plan.json" "$dir/tag_applied.json"
  fi
  timer_end step4_apply "ステップ4 タグ付与"

  timings_summary "$TIMINGS_FILE" "タグ付け所要時間 内訳: $old_instance_id"
  printf '[SUMMARY] %s タグ付け対象 %d 件%s\n' \
    "$old_instance_id" "${#allow_lines[@]}" "$(if [[ "$DRY_RUN" == "true" ]]; then printf '（dry-run: 未付与）'; fi)"
}

# 目的: 引数・設定を読み込み、targets.txt の全対象へタグ付けを適用する。
# 引数: --yes, --dry-run, --no-instance-tags, --skip-order-check, --help
# 出力: 対象ごとの tag_* 状態ファイルと create-tags の発行。
main() {
  parse_tag_flags "$@"
  load_config
  # 90 専用の設定。lib/common.sh と config.env.example を変更せずに config.env へ追記できるよう、
  # ここで既定値を与える（05_rollback.sh:205 の ROLLBACK_ALLOW_EXTRA_VOLUMES と同じ方式）。
  : "${TAG_EXTRA_TAGS:=}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "dry-run モード: create-tags は発行しません。"
  else
    # run_targets の while ループへ入る前に1回だけ確認する（対象ごとには聞かない）。
    confirm_or_exit "$YES" "新規作成リソース（バックアップAMI/スナップショット、切替後の新EC2、破棄予定ルートEBS）へタグを付与します。
旧EBS・旧ENI・旧EC2などの既存リソースは denylist で保護され、対象になりません。
04_verify.sh が全項目 PASS だったことを目視で確認してから続行してください（90 側では PASS/FAIL を判定できません）。"
  fi

  run_targets process_target
}

main "$@"
