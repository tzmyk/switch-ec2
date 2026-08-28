# switch-ec2 仕様書

RHEL PAYG ライセンスの EC2 を、ELC/BYOS 系 AMI から起動した新 EC2 へ置き換えるスクリプト群の仕様書。

- 操作手順は `README.md` を参照
- 検証環境と検証実績は `test-env/`（リポジトリ管理外・ローカル検証用）を参照
- 本書はスクリプトの方式・処理・入出力・安全ガードの仕様を定義する

## 1. 背景と目的

### 1.1 課題

RHEL の PAYG（Pay As You Go）ライセンスで稼働中の EC2 を、ELC（Extended Life Cycle）等の
別ライセンス契約へ切り替えたい。しかし EC2 の課金コード（`UsageOperation`）は
**インスタンス起動時に指定した AMI で確定し、後から変更できない**。

### 1.2 解決方式

この性質を逆手に取り、次の方式でライセンスだけを切り替える。

1. 切替先ライセンスの AMI（ELC/BYOS 系）から新 EC2 を起動する（この時点で課金コードが確定）
2. 新 AMI 由来のルートボリュームを破棄予定として切り離す
3. 旧 EC2 の全 EBS（OS ディスク含む）と全 ENI を新 EC2 へ付け替える

### 1.3 保証する性質

| 項目 | 保証内容 | 根拠 |
|---|---|---|
| OS・データ | 旧 EC2 と完全同一 | EBS ボリューム自体を移設（再作成しない） |
| ファイルシステム UUID | 不変 | 同上 |
| プライマリ/セカンダリ IP・MAC | 不変 | ENI ごと移設 |
| Elastic IP | 不変 | EIP は ENI に紐付くため ENI 移設で自動追随 |
| タグ・インスタンスタイプ・IAM ロール等 | 引き継ぎ | 01 で保存した属性を 03 の起動時に再指定 |
| UsageOperation | 新 AMI 由来の値へ変化 | 起動時 AMI で確定する仕様 |

### 1.4 方式上の必然的制約

- **旧 EC2 は terminate される。** プライマリ ENI（DeviceIndex 0）は running/stopped の
  インスタンスから単独デタッチできないため、同一 IP を引き継ぐには terminate が唯一の手段。
- **インスタンス ID は変わる。** cloud-init が新規インスタンスと判定するため、
  OS 内事前作業（SSH ホスト鍵保持・ホスト名保持）が必要（README「OS内想定作業」参照）。
- **切替後は RHUI が使えなくなる。** PAYG 用リポジトリは ELC インスタンスで認可されないため、
  サブスクリプションの再登録が必要（本案件では Satellite を使用。手順は別途）。

## 2. システム構成

### 2.1 実行環境

| 環境 | 役割 | 使用コンポーネント | 必要条件 |
|---|---|---|---|
| CloudShell（または同等の bash 環境） | AWS API 操作の全て | `01`〜`06`、`lib/common.sh` | AWS CLI v2、`jq`、admin 相当権限 |

### 2.2 コンポーネント一覧

| ファイル | 役割 |
|---|---|
| `lib/common.sh` | 設定読込、AWS CLI ラッパー、待機、対象一覧処理の共通ライブラリ |
| `01_prepare.sh` | 事前検査とベースライン状態ファイルの保存 |
| `02_backup.sh` | バックアップ AMI の作成（2フェーズ: 発行→待機） |
| `03_switch.sh` | 切替本体（破壊的操作を含む） |
| `04_verify.sh` | AWS API 側の切替後検証 |
| `05_rollback.sh` | バックアップ AMI のスナップショットからの切り戻し（破壊的操作を含む） |
| `06_verify_rollback.sh` | AWS API 側の切り戻し後検証 |
| `config.env` / `targets.txt` | CloudShell 側の設定・対象一覧（`.example` から作成） |
| `docs/operator.html` / `docs/developer.html` | 人間向け参照ドキュメント（操作手順 / 内部構造）。実装判断の根拠は本書と `README.md` を優先 |
| `test-env/` | 検証専用 Terraform 環境（本番手順外・リポジトリ管理外） |

### 2.3 データフロー

```
01_prepare ──→ work/<旧ID>/ ベースライン状態ファイル ──┬─→ 03_switch が入力として使用
02_backup  ──→ work/<旧ID>/backup_ami_id.txt ─────────┤
                                                       └─→ 04_verify が期待値として使用
03_switch  ──→ work/<旧ID>/new_instance_id.txt ほか ────→ 04_verify が対象特定に使用
05_rollback ─→ work/<旧ID>/rollback_instance_id.txt ほか ─→ 06_verify_rollback が対象特定に使用
```

## 3. 対応範囲

### 3.1 前提条件

- 対象インスタンスが `running` であること（01 で検査）
- `NEW_AMI_ID` が同一リージョンに存在し `available` であること（01・03 で検査)
- 新 AMI と旧インスタンスのアーキテクチャが一致すること（01・03 で検査)
- 新 AMI と旧インスタンスの BootMode が互換であること（§5.2）

### 3.2 非対応構成（01 が検出して中止する）

| 構成 | 検出方法 |
|---|---|
| placement group | `Placement.GroupName` が非空 |
| Dedicated Host | `Placement.HostId` 非空、`Affinity=host`、または `Tenancy=host` |
| マルチネットワークカード | いずれかの ENI の `Attachment.NetworkCardIndex` > 0 |
| hibernation | `HibernationOptions.Configured == true` |
| Nitro Enclaves | `EnclaveOptions.Enabled == true` |
| Multi-Attach EBS | いずれかのボリュームの `MultiAttachEnabled == true` |
| インスタンスストア | BlockDeviceMappings に EBS 以外が存在（`ALLOW_INSTANCE_STORE_LOSS=true` で警告に緩和可） |
| Spot インスタンス | `InstanceLifecycle == spot` |

### 3.3 引き継ぎ対象属性

インスタンスタイプ、KeyName、IAM インスタンスプロファイル、全 ENI（DeviceIndex 維持）、
全 EBS（デバイス名維持。旧ルートのみ §5.4）、Placement（AZ・Tenancy）、EbsOptimized、
Monitoring、MetadataOptions、ユーザー管理タグ、終了保護・停止保護、
InstanceInitiatedShutdownBehavior、MaintenanceOptions、PrivateDnsNameOptions、
カスタム CPU options（タイプ標準値との差分がある場合）、CapacityReservationSpecification、
UserData（`COPY_USER_DATA=true` の opt-in）、t2/t3/t3a/t4g の CreditSpecification。

**引き継がないもの**: `aws:` で始まる予約タグ（API 仕様上コピー不可）、
`COPY_USER_DATA=false` の場合の UserData、上記以外の属性（起動時デフォルトになる）。

## 4. 設定仕様

### 4.1 config.env（CloudShell 側）

| 変数 | デフォルト | 仕様 |
|---|---|---|
| `NEW_AMI_ID` | なし（必須） | 切替先ライセンスの AMI ID |
| `AWS_REGION` | 空 | 空なら AWS CLI のデフォルトリージョン。非空なら全コマンドに `--region` 付与 |
| `BACKUP_NO_REBOOT` | `false` | `true` で `create-image --no-reboot`（整合性は実行時状態依存） |
| `ALLOW_UEFI_PREFERRED_ON_BIOS` | `false` | §5.2 の危険な組み合わせを opt-in で許可 |
| `ALLOW_INSTANCE_STORE_LOSS` | `false` | インスタンスストア消失を opt-in で許可 |
| `COPY_USER_DATA` | `false` | `true` で旧 EC2 の UserData を引き継ぐ。新インスタンス ID 検知後に cloud-init が再実行するため、冪等性確認済みの場合のみ有効化 |
| `EXPECTED_NEW_USAGE_OPERATION` | 空 | 04 の期待値判定（§7.1）。空なら「変化したこと」のみ判定 |
| `WORK_DIR` | `./work` | 状態ファイル保存先 |
| `MAX_PARALLEL` | `4` | `03_switch.sh --parallel`（同時数省略時）の同時実行台数。EC2 API のスロットリングと同時復旧負荷を考慮した既定値。逐次が既定なので `--parallel` 未指定なら未使用 |
| `WAIT_IMAGE_AVAILABLE_TIMEOUT` | 3600 | AMI available 待機タイムアウト（秒）。ポーリング間隔 30 秒 |
| `WAIT_INSTANCE_STATE_TIMEOUT` | 1800 | インスタンス状態待機（秒）。間隔 15 秒 |
| `WAIT_VOLUME_STATE_TIMEOUT` | 1800 | ボリューム状態待機（秒）。間隔 10 秒 |
| `WAIT_ENI_AVAILABLE_TIMEOUT` | 900 | ENI available 待機（秒）。間隔 10 秒 |
| `WAIT_STATUS_OK_TIMEOUT` | 1800 | 2/2 ステータスチェック待機（秒）。間隔 20 秒 |

### 4.2 targets.txt（CloudShell 側）

- 1 行 1 インスタンス ID。空行・`#` コメント行は無視。前後空白は除去
- 全行が `^i-[0-9a-f]+$` に一致しない場合、または重複がある場合は**処理開始前に全体エラー**

## 5. 処理仕様

### 5.1 共通仕様（lib/common.sh）

- 全スクリプト `set -euo pipefail`。エラーは `die`（ログ＋非ゼロ return）で伝播
  - `03_switch.sh` と `05_rollback.sh` は `set -eEuo pipefail`。`-E`（errtrace）が無いと、`process_target` が仕掛ける
    ERR トラップ（terminate 前の失敗で対象 EC2 の保護を復元する）が関数内の失敗で発火しないため
- **ログ（`log_info`/`log_warn`/`log_error`）**: 形式は
  `[日時+TZ] [+経過秒] [レベル] [対象ID] メッセージ`。出力先は stderr と `LOG_FILES` の各ファイル。
  経過秒はプロセス開始（ライブラリ読込時）からの秒数
- **時間計測（`timer_start`/`timer_end`/`timings_summary`）**: 名前付きタイマーで区間所要秒を計測し、
  ログへ出力しつつ `TIMINGS_FILE`（`名前<TAB>秒` の TSV）へ追記。`timings_summary` が内訳と TOTAL を表示。
  未開始タイマーの `timer_end` は警告のみで処理を止めない
- **対象別ログ・計測の設定（`setup_target_logging`）**: 対象ごとに
  `WORK_DIR/<対象ID>/<スクリプト名>.log`（追記）と `timings_<スクリプト名>.tsv`（対象単位で作り直し）を設定
- **describe 正規化（`normalize_describe_json`）**: 種別（`instances`/`volumes`/`enis`）ごとに、
  フィールドを増減させずキー順（`jq -S`）と AWS が順序を保証しない配列の順序だけを安定化する。
  切替前後の全文 diff（§6.1 の `before_*`/`after_*`）を成立させるための正規化
- **対象一覧処理（`run_targets`）**: 対象を 1 台ずつサブシェル（`set -eEuo pipefail`）で処理。
  1 台の失敗は記録して次の対象へ進み、最後に成功/失敗サマリを表示。
  失敗が 1 台でもあれば終了コード 1
- **並行対象一覧処理（`run_targets_parallel`）**: `03_switch.sh --parallel` 専用。
  対象ごとに**独立した子プロセス**を最大 N 個まで起動し、`wait` で個別に終了コードを回収する。
  サマリと終了コードの契約は `run_targets` と同じ
  - サブシェルではなく子プロセスにするのは、bash が `if`/`||` の条件文脈で errexit を抑止し、
    その抑止がサブシェルへ伝播して内側の `set -e` を無効化するため（`$-` では検出できない）。
    破壊的操作の途中失敗を見逃さないよう、プロセス境界で errexit の状態を切り離す
  - 同時実行数の制御は `jobs -rp` のポーリング。この関数以外のバックグラウンドジョブがない前提
  - `run_targets`/`run_targets_parallel` はともに `local -` でシェルオプション変更を関数内に閉じる
    （内部の `set +e`/`set -e` が呼び出し元へ漏れないようにするため）
- **AWS CLI ラッパー（`aws_json`/`aws_text`）**: `--output` とリージョンを共通化し、
  stdin を `/dev/null` に切り離す（エラー時の auto-prompt が対象一覧を吸い込む事故の防止）
- **確認プロンプト（`confirm_or_exit`）**: 破壊的操作前に `yes` 入力を要求。
  `--yes` で省略可。読み取りは可能な限り `/dev/tty` から行う（stdin 競合の防止）
- **待機（`wait_until`）**: 条件関数をポーリング。条件関数の戻り値で分岐する
  - `0`: 条件成立、待機終了
  - `1`: 未達（AWS API の一時エラー含む）、リトライ継続
  - `2`: **到達不能な終端状態、即時失敗**（タイムアウトを待たない）
- **終端状態の定義**: インスタンス待機中の `terminated`（terminated 待ち以外）、
  ボリュームの `error`/`deleted`/削除済み、AMI の `failed`/`deregistered`/削除済み
- **EBS アタッチ完了判定**: `Volume.State` ではなく
  `Attachments[]` に「対象インスタンス ID・デバイス名・`State=attached`」のエントリが
  あることを確認する（`volume_attachment_is_attached`）

### 5.2 01_prepare.sh

**目的**: 切替可否の検査と、03・04 が使うベースライン状態ファイルの保存。

**処理順序**（検証が先、書き込みは後。失敗した prepare が既存ベースラインを壊さない）:

1. 切替済みガード: `new_instance_id.txt` が存在する対象は再 prepare 禁止（die）
2. NEW_AMI の存在・`available` 確認（プロセス内 1 回だけ実行しキャッシュ）
3. 対象の describe 取得、`running` 確認、アーキテクチャ一致確認
4. BootMode 互換性判定（下表）
5. Spot を含む非対応構成の検出（§3.2）
6. 全検証通過後に追加属性、UserData、インスタンスタイプ標準 CPU 値を取得。UserData が非空かつ `COPY_USER_DATA=false` なら警告
7. CPU options はタイプ標準値と一致すれば `null`、差分があれば CoreCount/ThreadsPerCore を保存
8. 状態ファイル一式を書き出し（§6.1）

**BootMode 互換性マトリクス**（空/null は `legacy-bios` に正規化。インスタンス側は
実効値 `CurrentInstanceBootMode` を優先):

| AMI \ インスタンス | uefi | legacy-bios |
|---|---|---|
| uefi | 一致: OK | 不一致: die |
| legacy-bios | 不一致: die | 一致: OK |
| uefi-preferred | 互換: OK | **既定 die**。`ALLOW_UEFI_PREFERRED_ON_BIOS=true` で警告に緩和（旧 OS ディスクのハイブリッドブート構成確認が前提） |

### 5.3 02_backup.sh

**目的**: 切替失敗時の復旧点となるバックアップ AMI の作成。

- **2 フェーズ構成**: フェーズ 1 で全対象へ `create-image` を発行（数秒/台）、
  フェーズ 2 で全 AMI の `available` を待機。作成は AWS 側で並列に進むため、
  所要時間は台数比例でなく「最も遅い 1 台分」に近い
- 発行前に古い `backup_ami_id.txt` を削除する（発行失敗時に stale な AMI ID が残り、
  03 のガードをすり抜けるのを防ぐ)
- AMI 名: `<Name タグ or インスタンス ID>-backup-<YYYYMMDD-HHMMSS>`
- AMI・スナップショット両方に付与するタグ:
  `Purpose=switch-ec2-backup`、`SourceInstanceId=<旧ID>`、`CreatedAt=<タイムスタンプ>`
- 既定は reboot あり（整合性優先）。**フェーズ 1 で全対象の再起動がほぼ同時に発生**する点に注意
  （クラスタ構成では targets.txt の分割か `BACKUP_NO_REBOOT=true` を検討）
- `aws ec2 wait image-available`（固定 約10分）は使わず、
  `WAIT_IMAGE_AVAILABLE_TIMEOUT` に従い独自ポーリング

### 5.4 03_switch.sh

**目的**: 切替本体。破壊的操作（旧 EC2 の terminate）を含む。

**事前検証**（すべて破壊的操作の前に実施。1 つでも失敗したら対象を中止）:

1. 必要な JSON 状態ファイル（20 ファイル）の存在・非空・JSON 妥当性と、
   `user_data.b64.txt`・`backup_ami_id.txt` の存在を検証（`null`/`false` 単体は正当値として許容）。
   UserData を引き継ぐ場合は破壊操作前に base64 妥当性も検証
2. NEW_AMI の存在・`available`・アーキテクチャ一致の再確認（01 との間の deregister・差し替え対策）
3. バックアップ AMI の `available` と `SourceInstanceId` タグが処理対象と一致することの確認
4. 確認プロンプト（`--yes` で省略可）

1〜3 は `preflight_target` として関数化されており、AWS 側は describe のみで変更を行わない。

**実行方式**:

| 方式 | 起動方法 | 確認プロンプト | 対象処理の単位 |
|---|---|---|---|
| 逐次（既定） | 引数なし | 対象ごとに 1 回 | サブシェル（`run_targets`） |
| 並行 | `--parallel[=N]`（N 省略時は `MAX_PARALLEL`） | **fan-out 前に 1 回だけ** | 子プロセス（`run_targets_parallel`） |

- 並行モードは fan-out 前に**全対象へ `preflight_target` を実施**し、その後 1 回だけ確認を取る。
  1 台でも事前検証に失敗すれば破壊的操作は 1 台も実行されない
- 子プロセスは内部オプション `--single-target-confirmed <対象ID>` で起動される（確認済みを表す）。
  子プロセスでも `preflight_target` を再実行する（describe のみで冪等。逐次モードと同じ
  「確認直前の状態で検証する」保証を保つため）
- `N` は 1 以上の整数。1 なら逐次と同じ経路になる

**切替シーケンス**（タイマー名は `timings_03_switch.tsv` のキー。コード内のステップ番号に対応するため、
本表の # とは 1 つずれる箇所がある）:

| # | タイマー名 | 処理 | 補足 |
|---|---|---|---|
| 1 | `step1_disable_protection` | 終了保護・停止保護を一時無効化（有効な場合のみ） | ERR trap を設定。**terminate 発行前に失敗した場合は保護を元の値へ自動復元** |
| 2 | `step2_stop_old` | 旧 EC2 を停止 | |
| 3 | `step2b_drift_check` | **現物再照合**: 停止後の実際の EBS（VolumeId+DeviceName）と ENI（ID+DeviceIndex）が prepare 時と完全一致することを確認 | 不一致なら die（prepare 後の構成変更検出。この時点なら旧 EC2 は無傷で復旧可能） |
| 4 | `step3_dot_false` | 全 EBS・全 ENI の `DeleteOnTermination=false` | terminate 時の巻き添え削除防止 |
| 5 | `step4_detach_ebs` | 全 EBS をデタッチし `available` を待機 | |
| 6 | `step5_terminate_old` | 旧 EC2 を terminate、全 ENI の `available` を待機 | 以降 ERR trap 解除（保護復元は不能なため） |
| 7 | `step6_run_new` | 新 EC2 を起動し `running` を待機 | 旧 ENI を DeviceIndex 維持で指定。`--client-token switch-ec2-<旧ID>`（応答喪失時に describe のフィルタで新 EC2 を特定可能）。§3.3 の属性を再指定。標準値と異なる CPU options のみ指定し、UserData は opt-in 時だけ `fileb://` で指定 |
| 8 | `step7_stop_new` | 新 EC2 を停止 | |
| 9 | `step8_detach_discard_root` | 新 AMI 由来ルートをデタッチし、破棄予定タグを付与 | タグ: `Purpose=switch-ec2-discarded-root`、`DeleteAfterVerification=true`、`SourceOldInstanceId`、`NewInstanceId`。**削除はしない**（検証完了後に手動削除） |
| 10 | `step9_attach_old_ebs` | 旧 EBS を新 EC2 へアタッチ | 旧ルートのみ**新 AMI の RootDeviceName** にアタッチ（AMI 世代間の `/dev/sda1` と `/dev/xvda` の差異を吸収）。他は元のデバイス名。attached 完了を厳密判定 |
| 11 | `step10_restore_dot` | EBS・ENI の `DeleteOnTermination` を prepare 時の値へ復元 | |
| 12 | `step11_start_new` | 新 EC2 を起動し 2/2 ステータスチェック OK を待機。停止保護を復元 | 終了保護は起動時に指定済み |

対象の切替完了時に `timings_summary` が内訳と TOTAL を表示する。並行モードでは対象単位の総所要時間
（タイマー名 `target_total`）も記録する。

**リラン非対応**: 途中失敗後の同一対象への再実行はサポートしない（設計判断）。
失敗フェーズ別の復旧は README「手動復旧 runbook」に従う。

### 5.5 04_verify.sh

**目的**: AWS API 側の切替結果検証。判定項目は §7.1。

- 対象ごとに `[PASS]`/`[FAIL]`/`[INFO]` を出力し、1 項目でも FAIL なら対象 FAIL
- 読み取り専用（AWS 側の変更は行わない）

### 5.6 05_rollback.sh

**目的**: `02_backup.sh` のバックアップ AMI から PAYG 相当の復旧 EC2 を起動し、ELC 新 EC2 を終了する。

**方式**: バックアップ AMI の BDM をそのまま使い、全 EBS を AMI スナップショットから新規作成する
完全復元（方式B）。ELC 新 EC2 に付く EBS は使わず `available` で残置し、保全 ENI は
DeviceIndex 維持で復旧 EC2 に再利用する。データは AMI 取得時点へ巻き戻る。逐次実行のみで、
`--target <旧ID>` を複数指定可能。`--parallel` は持たない。

**事前検証**: 二重実行禁止、01〜03 の状態ファイルと `new_instance_after_switch.json`、
バックアップ AMI の available・SourceInstanceId・Architecture・BootMode・旧 UsageOperation、
BDM の DeviceName 集合・全 SnapshotId・全スナップショット completed、ELC 新 EC2 の状態、
既知 EBS と ENI の現物構成をすべて破壊操作前に確認する。追加 EBS は既定 die、環境変数
`ROLLBACK_ALLOW_EXTRA_VOLUMES=true` の場合だけ警告して DOT=false 化・デタッチまで行いタグは付けない。

**処理順序**:

1. read-only preflight と、巻き戻り時点・失われる期間・残置 EBS を含む確認
2. ELC 新 EC2 の終了/停止保護を一時解除し停止
3. 現物の全 EBS/ENI の DOT=false 化を describe-instances と describe-network-interfaces でアサート
4. 現物の全 EBS をデタッチして available を待機
5. ELC 新 EC2 を terminate し全 ENI の available を待機
6. client token `switch-ec2-rollback-<旧ID>` と保全 ENI を指定しバックアップ AMI から起動
7. running と 2/2 ステータス OK を待機
8. EBS/ENI の DOT を01の値へ復元
9. 停止保護を復元
10. 既知の保全 EBS に `Purpose=switch-ec2-rollback-preserved` と UUID 重複警告タグを付与（自動削除しない）
11. 最終 describe と所要時間を保存

terminate 前の失敗は ERR trap が ELC 新 EC2 の保護を復元する。terminate 後は不可逆であり、
README の手動復旧 runbook に従う。

### 5.7 06_verify_rollback.sh

**目的**: 復旧 EC2 が旧ベースラインと一致し、UsageOperation が旧 PAYG 値へ戻ったことを読み取り専用で検証する。

- VolumeId は比較しない。DeviceName・DeleteOnTermination・バックアップ AMI の SnapshotId を照合し、
  Size・VolumeType・Iops・Throughput・Encrypted は `before_volumes.json` と比較する
- ENI ID・DeviceIndex・IP、タグ、インスタンスタイプ、起動属性、終了/停止保護、BootMode、UserData を比較する
- 保全 EBS の available と Purpose タグ、ELC 新 EC2 の terminated、復旧 EC2 の2/2、保全 ENI の全件アタッチを確認する
- OS 内の状態確認はスコープ外。別途の運用手順に従う
- **EBS ボリュームのタグは検証対象外**。`create-image` はボリュームのタグをスナップショットへ
  コピーせず、`run-instances` も AMI 由来ボリュームにタグを付けないため、復旧 EC2 のボリュームは
  タグが空になる（実機検証で確認済み）。ボリュームタグを条件にした外部の自動化がある場合は
  `before_volumes.json` を参照して手動で復元する運用とする

## 6. 状態ファイル仕様

### 6.1 `work/<旧インスタンスID>/`（CloudShell 側）

| ファイル | 生成 | 内容 | 主な利用先 |
|---|---|---|---|
| `instance.json` | 01 | 旧 EC2 の describe-instances 全量 | 03（Name 参照）、04（IP・タグ期待値） |
| `instance_type.json` / `key_name.json` / `iam_instance_profile.json` / `ebs_optimized.json` / `monitoring.json` / `placement.json` / `metadata_options.json` / `credit_specification.json` | 01 | 新 EC2 起動時に再現する属性 | 03（run-instances 引数）、04（期待値） |
| `enis.json` | 01 | ENI の ID・DeviceIndex・AttachmentId・DeleteOnTermination・プライマリ IP・SG（DeviceIndex 順） | 03（保全・起動・DOT 復元）、04 |
| `block_devices.json` | 01 | EBS の DeviceName・VolumeId・DeleteOnTermination（EBS のみ） | 03（保全・移設・DOT 復元）、04 |
| `root_device_name.json` | 01 | 旧ルートデバイス名 | 03（ルート付け替え）、04 |
| `tags.json` / `usage_operation.json` / `boot_mode.json` | 01 | タグ・課金コード・BootMode | 03・04 |
| `disable_api_termination.json` / `disable_api_stop.json` | 01 | 終了/停止保護の元値 | 03（解除・復元）、04 |
| `shutdown_behavior.json` / `maintenance_options.json` / `private_dns_name_options.json` | 01 | シャットダウン動作・メンテナンス・プライベート DNS 名のオプション | 03（run-instances 引数）、04 |
| `cpu_options.json` | 01 | タイプ標準値との差分がある場合の CoreCount/ThreadsPerCore。標準値なら `null` | 03（条件付き run-instances 引数）、04 |
| `capacity_reservation.json` | 01 | CapacityReservationSpecification | 03（run-instances 引数）、04 |
| `user_data.b64.txt` | 01 | UserData の base64。未設定なら空ファイル | 03（`COPY_USER_DATA=true` 時）、04 |
| `new_ami_boot_mode.txt` / `instance_boot_mode.txt` | 01 | 正規化済み BootMode（記録用） | 人間の確認用 |
| `backup_ami_id.txt` / `backup_created_at.txt` | 02 | バックアップ AMI ID・作成時刻 | 03（ガード）、切り戻し |
| `new_instance_run.json` / `new_instance_id.txt` | 03 | run-instances 応答・新インスタンス ID | 04、手動復旧 |
| `new_instance_before_attach.json` / `new_root_device_name.txt` / `discarded_root_volume_id.txt` | 03 | アタッチ前の新 EC2 describe・新ルート名・破棄予定ボリューム ID | 手動復旧・破棄ルート削除 |
| `new_instance_after_switch.json` | 03 | 切替完了後の新 EC2 describe | 記録用 |
| `verify_*.json` | 04 | 検証時の正規化済み比較データ | 差分調査用 |
| `rollback_instance_run.json` / `rollback_instance_id.txt` | 05 | 復旧 run-instances 応答・復旧インスタンス ID | 06、手動復旧 |
| `rollback_preserved_volume_ids.txt` | 05 | ELC 新 EC2 からデタッチして残置した全 EBS ID | 06、手動削除 |
| `rollback_instance_after.json` | 05 | 切り戻し完了後の復旧 EC2 describe | 記録用 |
| `verify_rollback_*.json` | 06 | AMI・復旧 EC2・EBS・ENI・タグの検証用データ | 差分調査用 |
| `before_instance.json` / `before_volumes.json` / `before_enis.json` | 01 | 切替前の instance・EBS・ENI の describe 全文。`normalize_describe_json` でキー順と配列順のみ安定化（フィールドの増減なし） | `after_*` との手動 diff（§7.2） |
| `after_instance.json` / `after_volumes.json` / `after_enis.json` | 04 | 切替後の同形式。volume・ENI は新 EC2 に実際に付いているものを対象とするため、`before_*` と同じ集合になる | `before_*` との手動 diff（§7.2） |
| `after_rollback_instance.json` / `after_rollback_volumes.json` / `after_rollback_enis.json` | 06 | 切り戻し後の正規化済み describe 全文。EBS は全 VolumeId が新規 | `before_*` との手動 diff（§7.3） |
| `<スクリプト名>.log` | 01〜06 | 対象単位のログ（追記）。画面出力と同内容 | 障害調査 |
| `timings_<スクリプト名>.tsv` | 01〜06 | `名前<TAB>秒` の所要時間。対象単位で実行ごとに作り直す。03・05・06 はステップ単位 | 所要時間の見積り |

## 7. 検証仕様

### 7.1 04_verify.sh の判定項目

| # | 項目 | 判定 |
|---|---|---|
| 1 | プライマリプライベート IP | 完全一致 |
| 2 | ENI の ID・DeviceIndex・DeleteOnTermination | 全件一致（DeviceIndex 順で正規化比較） |
| 3 | EBS の VolumeId・DeviceName・DeleteOnTermination | 全件一致。旧ルートのデバイス名のみ新ルート名への差し替えを期待値として許容 |
| 4 | タグ | `aws:` 予約タグを除き完全一致 |
| 5 | インスタンスタイプ | 完全一致 |
| 6 | **UsageOperation** | 新値が空でなく、**旧値から変化していること**。`EXPECTED_NEW_USAGE_OPERATION` 設定時はその値との完全一致も必須 |
| 7 | MetadataOptions（HttpTokens・HttpEndpoint） | 一致 |
| 8 | IamInstanceProfile.Arn | 一致（両方なしも一致扱い） |
| 9 | EbsOptimized・Monitoring.State・KeyName | 一致 |
| 10 | 終了保護・停止保護 | describe-instance-attribute の実値が旧値と一致 |
| 11 | InstanceInitiatedShutdownBehavior | describe-instance-attribute の実値が保存値と一致 |
| 12 | MaintenanceOptions.AutoRecovery | 保存値が非 null の場合に一致。null は INFO でスキップ |
| 13 | PrivateDnsNameOptions | 保存値が非 null の場合にキー順を正規化して一致。null は INFO でスキップ |
| 14 | CpuOptions（CoreCount・ThreadsPerCore） | `instance.json` の旧値と新 describe の値が常に一致 |
| 15 | CapacityReservationSpecification | 保存値が非 null の場合にキー順を正規化して一致。null は INFO でスキップ |
| 16 | UserData | `COPY_USER_DATA=true` なら base64 完全一致。false かつ保存値が非空なら引き継いでいない旨を INFO 表示 |

補足: 検証環境（test-env）は新旧とも PAYG のため #6 は FAIL が期待値
（`test-env/README.md` 参照)。

### 7.2 切替前後 describe の手動 diff（自動判定なし）

§7.1 は「見るべき項目を見る」検証であり、**想定していない箇所が変化していないこと**は保証しない。
これを人間が確認するため、instance・EBS・ENI の describe 全文を切替前後で保存する（§6.1 の
`before_*.json` / `after_*.json`）。判定は自動化せず、運用者が `diff -u` で確認する。

- 保存形式: フィールドの増減なし。`jq -S` によるキー順ソートと、AWS が順序を保証しない配列
  （`BlockDeviceMappings`・`NetworkInterfaces`・`SecurityGroups`・`Tags`/`TagSet`・`Attachments`・
  `Groups`・`PrivateIpAddresses`・`Ipv6Addresses`・`ProductCodes`）の ID 順ソートのみを適用
- 想定される差分の一覧（instance / volumes / eni それぞれ）は README「切替前後 describe の想定 diff」
  に記載する。ここに無い差分が出た場合は想定外として原因調査する
- `04_verify.sh` は実行末尾に diff コマンドを `[INFO]` で案内する

### 7.3 06_verify_rollback.sh の判定と手動 diff

判定項目は、プライマリ IP、ENI ID/DeviceIndex/DOT、EBS の DeviceName/DOT/SnapshotId と属性、
旧 PAYG UsageOperation、タグ、インスタンスタイプ、MetadataOptions、IAM、EbsOptimized、Monitoring、
KeyName、終了/停止保護、shutdown behavior、MaintenanceOptions、PrivateDnsNameOptions、CpuOptions、
CapacityReservation、BootMode、保全 EBS、ELC 新 EC2 の terminated、UserData、2/2、保全 ENI である。
1項目でも不一致なら対象 FAIL。`EXPECTED_NEW_USAGE_OPERATION` は使用しない。

`before_instance.json` → `after_rollback_instance.json` で必ず変わるものは、InstanceId、LaunchTime、
ImageId、ClientToken、ReservationId、AmiLaunchIndex、StateTransitionReason、全 EBS VolumeId、AttachTime、
ENI AttachmentId、UsageOperationUpdateTime、PrivateDnsName 関連、`aws:` 予約タグ。詳細は README の
「切り戻し前後 describe の想定 diff」に記載する。

## 8. 安全ガード一覧

| ガード | 実装箇所 | 防止する事故 |
|---|---|---|
| targets.txt の ID 形式・重複検証 | lib（処理開始前） | 不正 ID による対象単位の失敗、二重処理 |
| 切替済み対象の prepare 再実行禁止 | 01 | 正常ベースラインの上書き破壊 |
| 検証先行・書き込み後行 | 01 | 失敗した prepare による既存ベースラインの部分破壊 |
| 非対応構成の検出（§3.2） | 01 | 起動失敗・構成の暗黙変化・データ消失 |
| Spot 検出 | 01 | 非対応の購入形態をオンデマンド起動へ暗黙変更する事故 |
| BootMode 互換性マトリクス | 01 | 起動不能な新 EC2 の作成 |
| stale バックアップ ID の事前削除 | 02 | 発行失敗時に古い AMI が復旧点として誤採用される |
| 全入力ファイルの存在・JSON 検証 | 03（破壊操作前） | terminate 後の入力不備による長時間停止 |
| NEW_AMI・バックアップ AMI の再検証（SourceInstanceId 照合含む） | 03（破壊操作前） | deregister 済み AMI・他対象のバックアップでの切替強行 |
| 確認プロンプト | 03 | 意図しない破壊的操作 |
| 並行モードの fan-out 前一括事前検証 | 03（並行時） | 1 台の検証漏れに気付かないまま複数台の破壊的操作を開始する |
| 対象処理をサブシェルではなく子プロセスで実行 | lib（並行時） | errexit 抑止の伝播による途中失敗の見逃し（停止失敗のまま terminate へ進む等） |
| `set -eEuo pipefail`（errtrace） | 03・05 | ERR trap が関数内の失敗で発火せず保護復元が動かない |
| 停止後の EBS/ENI 現物再照合 | 03（terminate 前） | prepare 後に追加されたリソースの巻き添え削除 |
| `DeleteOnTermination=false` 化 | 03（terminate 前） | terminate と同時の EBS/ENI 削除 |
| 保護設定の ERR trap 復元 | 03（terminate 前まで） | 失敗後に保護解除されたまま放置 |
| client token | 03 | run-instances 応答喪失時の新 EC2 迷子・二重起動 |
| アタッチ完了の厳密判定 | lib/03 | アタッチ未完了での起動進行 |
| 終端状態の即時失敗 | lib | 到達不能な待機をタイムアウトまで隠す |
| before 証跡の上書き保護・原子的収集 | collect | 切替前証跡の消失・空ファイル化 |
| 空 UUID 対応表の FAIL 化 | compare | 比較不能構成での見せかけ PASS |
| 03 完走証跡・バックアップ AMI/BDM/スナップショット検証 | 05（破壊操作前） | 不完全な AMI や途中切替状態からの復旧強行 |
| ELC 新 EC2 の EBS/ENI 現物再照合と追加 EBS opt-in | 05（terminate 前） | 運用中の構成変更・追加データの巻き添え削除 |
| EBS/ENI DOT=false の API 実測アサート | 05（terminate 前） | EBS、プライマリ IP、EIP の永久喪失 |
| EBS 先行デタッチ | 05 | DOT 反映漏れ時の EBS 削除に対する二重防御 |
| 二重実行禁止と専用 client token | 05 | 復旧 EC2 の二重起動・03 の冪等性キーとの衝突 |
| 保全 EBS の UUID 重複警告タグ | 05 | 復旧 EC2 への誤アタッチ・誤マウント |

## 9. 終了コードとエラー時の状態

### 9.1 終了コード

| コード | 意味 |
|---|---|
| 0 | 全対象成功 |
| 1 | 1 台以上失敗（成功分は処理済み）、または設定・対象一覧の全体エラー |

### 9.2 途中失敗時の状態と復旧

03 の失敗位置により旧 EC2 の状態が異なる。**いずれの場合も EBS・ENI はデータごと保全される**
（terminate 前は DOT=false 化とデタッチが先行し、terminate 後は既にインスタンスから独立しているため）。

| 失敗位置 | 旧 EC2 | 復旧方法 |
|---|---|---|
| terminate 前 | stopped で残存 | 保護復元＋（デタッチ済みなら）再アタッチ＋起動（runbook 参照） |
| terminate 後〜run 前 | 消失 | 保全済み ENI/EBS でステップ 7 以降を手動実行（runbook 参照） |
| run 応答喪失 | 消失 | client token で新 EC2 を特定して手動継続（runbook 参照） |
| attach 以降 | 消失 | `new_instance_id.txt` 等を参照して手動継続（runbook 参照） |
| 全滅時の最終手段 | — | 方式Bの `05_rollback.sh` でバックアップ AMI のスナップショットから復旧 |

05 の失敗位置別の状態:

| 失敗位置 | ELC 新 EC2 | 復旧方法 |
|---|---|---|
| terminate 前 | stopped で残存。ERR trap が保護を復元 | デタッチ済み EBS を再アタッチして起動 |
| terminate 後〜run 前 | terminated | 保全 ENI とバックアップ AMI から05ステップ6を手動実行 |
| run 応答喪失 | terminated | client token `switch-ec2-rollback-<旧ID>` で復旧 EC2 を特定し後続を手動継続 |
| run 成功後 | terminated | `rollback_instance_id.txt` と AWS 現物を確認して DOT・保護・タグ・保存を手動完了 |

既存表の「全滅時の最終手段」は、方式Bを実装した `05_rollback.sh` を使う。保全済み旧 EBS を
復旧 EC2 へ付け替える旧方式は使用しない。

## 10. セキュリティ・運用上の考慮

- 必要権限は EC2 のフル操作相当（describe/start/stop/terminate/run-instances、
  create-image、ボリューム・ENI・タグ操作、instance-attribute 変更）。
  IAM PassRole は IAM インスタンスプロファイル付き対象の切替に必要
- `config.env`・`targets.txt`・`work/` 配下の状態ファイルは環境情報を含むため
  リポジトリにコミットしない（`.gitignore` 済み）
- 02 の reboot、03 の停止〜2/2 チェック完了（実測 6〜8 分/台）はサービス停止を伴う。
  停止時間帯の調整は運用側の責務。所要時間の実測は `timings_03_switch.tsv`（§6.1）で確認する
- 並行モード（`--parallel`）は総所要時間を短縮するが、失敗時に複数台の手動復旧が同時に必要になる。
  EC2 API のスロットリングも増えるため、`MAX_PARALLEL` は小さい値から検証する
- 検証完了後の手動作業: 破棄予定ルートボリューム（`DeleteAfterVerification=true` タグ）の削除、
  バックアップ AMI の保持期間管理
- 05 の停止〜復旧 EC2 2/2 完了は約9分/台を見込み、逐次のみ。AMI 取得時点以降の書き込みは失われる
- 05 後も、保全 EBS、03 由来破棄ルート、バックアップ AMI/スナップショット、opt-in のタグなし追加 EBSを自動削除しない
- 復旧 EBS と保全 EBS はファイルシステム UUID が同一のため、同一インスタンスへ同時アタッチしない
- 復旧後はサブスクリプション登録状態（別途の Satellite 手順に従う）と、instance-id をキーにする外部リソースを再確認する

## 11. 変更履歴

| コミット | 内容 |
|---|---|
| `0e48096` | 初版（スクリプト一式） |
| `6aad608` | 批判的レビュー反映（安全ガード・検証強化。§8 の大半を追加） |
| `c736fa1` | test-env の cleanup 存在判定修正・README 注記 |
| `30154d9` | 再検証結果をレポートに追記 |
| `c3b020b` | 仕様書 SPEC.md 新規作成 |
| `c58e30e` | 引き継ぎ属性の拡充（shutdown behavior・MaintenanceOptions・PrivateDnsNameOptions・CPU options・CapacityReservation・UserData opt-in）＋ Spot 検出 |
| 未コミット | ログへの経過秒付与とファイル保存、03 のステップ所要時間計測（§5.1・§6.1）、03 の並行実行モード `--parallel[=N]`（§5.4）、切替前後 describe 全文の保存と手動 diff（§6.1・§7.2）、03 の errtrace 有効化（§8） |
