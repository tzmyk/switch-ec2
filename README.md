# switch-ec2

RHEL PAYG ライセンスの EC2 を、ELC/BYOS 系 AMI から起動した新 EC2 へ置き換えるための bash スクリプト一式です。

## 全体像

EC2 の課金コード/UsageOperation は、インスタンス起動時に指定した AMI によって決まります。この性質を利用し、ELC/BYOS 系 AMI から新 EC2 を起動したあと、旧 EC2 の全 EBS ボリューム（OS ディスク含む）と ENI を新 EC2 に付け替えます。

旧 OS ディスクをそのまま移すため、起動後の OS は旧 EC2 と同じ RHEL 9.4 のままです。EBS ボリューム自体を再作成しないため、ファイルシステム UUID も保持されます。プライマリ IP、Elastic IP、ENI、タグも引き継ぎます。新 AMI 由来の RHEL 9.8 ルートボリュームは検証完了まで残し、手動削除対象としてタグ付けします。

## ファイル

- `SPEC.md`: 仕様書（方式・処理・状態ファイル・安全ガードの定義）
- `config.env.example`: 設定ファイル例
- `targets.txt.example`: 対象インスタンスIDの例
- `lib/common.sh`: 共通関数
- `01_prepare.sh`: 事前情報取得と検証
- `02_backup.sh`: バックアップ AMI 作成
- `03_switch.sh`: EC2 切替
- `04_verify.sh`: 切替後確認
- `05_rollback.sh`: バックアップ AMI からの切り戻し
- `06_verify_rollback.sh`: 切り戻し後確認
- `docs/operator.html`: 操作者向けドキュメント（手順・注意点・トラブル時の対応）
- `docs/developer.html`: 開発者向けドキュメント（内部構造・設計判断・状態ファイル仕様）

## 実行環境

スクリプトはすべて CloudShell（または同等の bash 環境）で実行します。**本スクリプト群は AWS API 操作のみを行い、対象EC2のOS内には一切ログインしません。**

| 環境 | 役割 | スクリプト | 必要な接続/権限 |
| --- | --- | --- | --- |
| CloudShell | AWS API による情報取得、AMI作成、EC2/ENI/EBS切替、AWS側検証、切り戻し | `01_prepare.sh`〜`06_verify_rollback.sh` | AWS CLI 実行権限 |

OS内の事前作業・事後作業（後述）は別途 SSH で実施します。踏み台EC2などの接続経路は本手順の対象外です。

## 前提条件

- AWS CloudShell または同等の bash 環境
- AWS CLI v2 と `jq`
- 対象リソースを操作できる admin 相当の権限
- OS内の事前作業を実施するため、対象EC2へSSHできる経路があること
- `NEW_AMI_ID` の AMI が対象インスタンスと同じリージョンに存在し、`available`
- 新 AMI と旧インスタンスのアーキテクチャが一致
- 新 AMI と旧インスタンスの BootMode が一致（`legacy-bios` / `uefi`）

## 準備

```bash
cp config.env.example config.env
cp targets.txt.example targets.txt
vi config.env
vi targets.txt
```

`config.env` の主な項目:

- `NEW_AMI_ID`: ELC/BYOS 系の起動元 AMI ID
- `AWS_REGION`: 空なら AWS CLI のデフォルトリージョンを使用
- `BACKUP_NO_REBOOT`: `false` がデフォルト。`create-image` 時に再起動を許可し、整合性を優先します。`true` は `--no-reboot` を使うため停止時間を抑えられますが、ファイルシステムやアプリケーションの整合性は実行時状態に依存します。
- `ALLOW_UEFI_PREFERRED_ON_BIOS`: デフォルト `false`。`uefi-preferred` AMI と `legacy-bios` の旧インスタンスの組み合わせを、旧OSディスクのハイブリッドブート対応確認後に限って許可する opt-in です。
- `ALLOW_INSTANCE_STORE_LOSS`: デフォルト `false`。引き継げないインスタンスストアの消失を確認済みの場合だけ `true` にします。
- `COPY_USER_DATA`: デフォルト `false`。`true` にすると旧 EC2 の UserData を引き継ぎます。切替後の初回起動で cloud-init が新インスタンス ID を検知してスクリプトを再実行するため、UserData の冪等性を確認済みの場合だけ有効化します。
- `EXPECTED_NEW_USAGE_OPERATION`: 新 EC2 に期待する UsageOperation（例: `RunInstances:00g0`）。空なら、新値が空でなく旧値から変化したことだけを検証します。
- `WORK_DIR`: 状態ファイル保存先
- `WAIT_*_TIMEOUT`: 各種待機タイムアウト秒
- `MAX_PARALLEL`: デフォルト `4`。`03_switch.sh --parallel`（同時数を省略した場合）で使う同時実行数です。EC2 API のスロットリングと、失敗時に複数台の復旧が同時に必要になる負荷を考えて控えめな値にしています。

`targets.txt` は 1 行 1 インスタンスIDです。空行と `#` コメントは無視されます。

## 実行手順

必ず次の順番で実行してください。

```bash
# AWS側の事前情報取得とバックアップAMI作成
./01_prepare.sh
./02_backup.sh

# EC2切替とAWS側検証
./03_switch.sh
./04_verify.sh
```

切替後に切り戻す場合は CloudShell で次を実行します。`05_rollback.sh` は逐次実行のみです。

```bash
./05_rollback.sh
./06_verify_rollback.sh

# 緊急時に1台だけ対象とする場合（複数回指定可）
./05_rollback.sh --target i-0123456789abcdef0
```

`05_rollback.sh` の確認画面には terminate する ELC 新 EC2、バックアップ AMI、巻き戻り時点、
失われる書き込み期間、残置 EBS が表示されます。内容を確認して `yes` と入力してください。
自動実行時のみ `--yes` を指定します。

破壊的操作を含む `03_switch.sh` は確認プロンプトを出します。自動実行する場合は `--yes` を付けます。

```bash
./03_switch.sh --yes
```

各スクリプトは `config.env` と `targets.txt` を読み、対象インスタンスを 1 台ずつ処理します。1 台で失敗した場合、そのインスタンスの処理を中断して次の対象へ進み、最後に成功/失敗サマリを表示します。失敗が 1 台でもあれば非 0 で終了します。

状態ファイルは `${WORK_DIR}/<instance-id>/` に保存されます。後続スクリプトは前段の状態ファイルを必須として参照します。

### 03_switch.sh の並行実行モード

`03_switch.sh` だけは複数台を並行処理できます。既定は従来どおり逐次で、`--parallel` を明示したときだけ並行になります。

```bash
./03_switch.sh --parallel        # config.env の MAX_PARALLEL 台まで同時実行
./03_switch.sh --parallel=2      # 2 台まで同時実行
./03_switch.sh --parallel 2      # 同上
```

1 台あたりの所要時間はほぼ全部が EC2 の停止・terminate・起動・2/2 ステータスチェックの待ち時間なので、並行化すると総所要時間は台数比例から「最も遅い1台分＋順番待ち」に近づきます。

並行モードの挙動と注意点:

- **確認プロンプトは開始前に 1 回だけ。** 対象ごとに `/dev/tty` から読むと入力が競合するため、fan-out 前に全対象の read-only 事前確認（状態ファイル・新AMI・バックアップAMI）を通してから、対象一覧を提示して 1 回だけ確認します。ここで 1 台でも検証に失敗すれば破壊的操作は 1 台も実行されません。`--yes` を併用すれば確認を省略できます。
- **失敗時は複数台の復旧が同時に必要になり得ます。** `03_switch.sh` は terminate 発行後のリランに対応していません。並行台数を増やすほど、同時に手動復旧 runbook を適用する対象が増えます。初回や本番では小さい値から試してください。
- **ログは対象別に分離されます。** 画面には全対象のログが `[<インスタンスID>]` 付きで混ざって流れますが、`${WORK_DIR}/<instance-id>/03_switch.log` を読めば 1 台分の流れだけを追えます。
- 対象ごとの処理は独立した子プロセスとして起動されます（内部オプション `--single-target-confirmed` を使用）。これは bash の errexit が条件文脈でサブシェルへ抑止伝播し、途中失敗を見逃す挙動を避けるためです。

### ログと所要時間の計測

全スクリプト共通で、ログは `[日時] [+経過秒] [レベル] [対象ID] メッセージ` 形式です。経過秒はそのプロセスの開始からの秒数です（並行モードの子プロセスでは、その対象の処理開始からの秒数になります）。

ログは画面（stderr）と同時に `${WORK_DIR}/<instance-id>/<スクリプト名>.log` へ追記されます。

`03_switch.sh`、`05_rollback.sh`、`06_verify_rollback.sh` はステップごとの所要時間を計測し、対象の処理完了時に内訳を表示します。同じ内容は `${WORK_DIR}/<instance-id>/timings_<スクリプト名>.tsv`（`ステップ名<TAB>秒` の TSV）に保存されるので、メンテナンスウィンドウの見積りに使えます。

```
[INFO] [i-0abc] 切替所要時間 内訳: i-0abc -> i-0xyz
  step1_disable_protection             0s
  step2_stop_old                      43s
  step2b_drift_check                   2s
  step3_dot_false                      3s
  step4_detach_ebs                    28s
  step5_terminate_old                112s
  step6_run_new                       95s
  step7_stop_new                      41s
  step8_detach_discard_root           22s
  step9_attach_old_ebs                18s
  step10_restore_dot                   5s
  step11_start_new                   260s
  TOTAL                              629s
```

## CloudShell で実行する際の制約

本スクリプト群は CloudShell での実行を想定していますが、CloudShell には**セッションが自動終了する**
制約があります。破壊的操作を含む `03_switch.sh` と `05_rollback.sh` は 1 台あたり 5〜11 分かかるため、
実行中に中断される可能性を前提に運用してください。

### 何が起きるか

- CloudShell は**キーボード・ポインタ操作がない状態が約 20〜30 分続くとセッションを終了**します。
  **スクリプトが動いていることは「操作」とみなされません。**放置すると実行中でも切られます。
- セッションが終了するとコンテナごと破棄され、実行中のプロセスは停止します。
  `nohup` や `tmux` を使ってもコンテナ停止には耐えられません。
- 永続化されるのは **`$HOME` 配下（リージョンごとに 1GB）だけ**です。

### 必ず守ること

1. **リポジトリと `WORK_DIR` を `$HOME` 配下に置く。** 実行前に `pwd` が `/home/cloudshell-user` 配下
   であることを確認してください。`/tmp` などで作業すると、セッション終了時に状態ファイルが消え、
   **後述の手動復旧 runbook がほぼ使えなくなります**（どのボリュームがどのデバイスに対応するかを
   人間が推測することになります）。ここが CloudShell 運用の単一障害点です。
2. **実行中はターミナルを操作し続ける。** 待っているだけでは操作とみなされません。
   **これが中断を防ぐ唯一の実効的な手段です。**複数台をまとめて処理する場合、
   実行時間は台数に応じて長くなるため、放置しないでください。

### 複数台・並行実行について

対象台数と切替可能な時間枠の都合上、**1 回の実行で複数台を対象にすること、および `--parallel` の
使用は許容されます。**そのうえで、次の点を理解して運用してください。

- **中断リスクは実行時間に比例します。** 逐次で 3 台なら約 20〜35 分となり、
  タイムアウト窓を超えます。前述のとおりターミナルを操作し続けてください。
- **`--parallel` は総所要時間を「最も遅い 1 台分＋順番待ち」に近づけます。**
  台数が多い場合は、逐次より並行のほうが中断リスクの窓を短くできます。
- **並行実行中に中断されると、手動復旧が必要な対象が同時に複数発生します。**
  `MAX_PARALLEL` は小さい値（既定 4）から始め、復旧体制と相談して決めてください。
- **状態ファイルとログは対象ごとに独立しています。**
  中断後は `${WORK_DIR}/<instance-id>/03_switch.log` を対象ごとに読めば、
  どの対象がどこまで進んだかを個別に判定できます。復旧も対象ごとに独立して行えます。
- **並行モードの確認プロンプトは開始前に 1 回だけです。** fan-out 前に全対象の read-only 事前確認を
  通すため、**1 台でも検証に失敗すれば破壊的操作は 1 台も実行されません。**

### 中断後の切り分け（複数台の場合）

```bash
# 各対象がどこまで進んだかを一覧する
for d in work/*/; do
  printf '%s: %s\n' "$(basename "$d")" "$(tail -1 "$d/03_switch.log" 2>/dev/null)"
done
```

### 中断されてもデータは失われない

`03_switch.sh` と `05_rollback.sh` は、**terminate より前に全 EBS と全 ENI の
`DeleteOnTermination=false` を設定し、全 EBS をデタッチしてから** terminate を発行します。
そのため、どのタイミングで中断されても EBS と ENI はデータごと残ります。
また、リソースを識別できなくする操作（デタッチ・terminate）の**前に**状態ファイルを書くため、
中断後も対象を特定できます。

ただし**自動では復旧しません。**中断後は必ず手動復旧 runbook に従ってください。

### 中断後にまず行うこと

```bash
# 1. どのステップまで完了したかを確認する（ログは即時追記されるので必ず残っています）
tail -20 work/<old-instance-id>/03_switch.log

# 2. terminate が発行済みかを確認する（stopped なら未発行、shutting-down/terminated なら発行済み）
aws ec2 describe-instances --instance-ids <old-instance-id> \
  --query 'Reservations[].Instances[].State.Name' --output text
```

そのうえで「手動復旧 runbook」の該当する節に進んでください。**そのまま再実行しないでください。**
（再実行しても構成ドリフト検査やインスタンス状態チェックが破壊的操作の前に停止させますが、
到達位置を確認してから対処するのが正しい手順です。）

### 中断時に個別に注意が必要な箇所

- **保護属性が戻りません。** 終了保護・停止保護を一時解除した直後に中断されると、
  復元処理（ERR トラップ）は動きません。セッション終了はシェルのエラーではないためです。
  再接続後に `disable_api_termination.json` / `disable_api_stop.json` の値と実際の属性を比較し、
  必要なら手動で戻してください。
- **`03_switch.sh` のステップ11（最長・実測 178〜260 秒）で中断されると、`05_rollback.sh` が
  起動を拒否します。** ステップ11の最後に書かれる `new_instance_after_switch.json` が
  05 の完走証跡として必須のためです。`04_verify.sh` で切替の完了を確認したうえで、
  次のコマンドで証跡を作成してから 05 を実行してください。

```bash
aws ec2 describe-instances --instance-ids "$(cat work/<old-instance-id>/new_instance_id.txt)" \
  > work/<old-instance-id>/new_instance_after_switch.json
```

## 各ステップ

### 01_prepare.sh

旧インスタンスの完全な `describe-instances` JSON と、インスタンスタイプ、KeyName、IAM インスタンスプロファイル、ENI、EBS、RootDeviceName、Placement、EbsOptimized、Monitoring、MetadataOptions、タグ、UsageOperation、BootMode、終了保護、停止保護、シャットダウン動作、MaintenanceOptions、PrivateDnsNameOptions、カスタム CPU options、CapacityReservationSpecification、UserData、t 系インスタンスの CreditSpecification を保存します。

また、以下を検証します。

- インスタンスが `running`
- `NEW_AMI_ID` が存在し `available`
- 新 AMI と旧インスタンスのアーキテクチャ一致
- 新 AMI と旧インスタンスの BootMode 一致
- Spot、placement group、Dedicated Host、マルチネットワークカード、hibernation、Nitro Enclaves、Multi-Attach EBS を使用していないこと
- インスタンスストアがないこと（`ALLOW_INSTANCE_STORE_LOSS=true` の明示的な opt-in を除く）

さらに、切替前後の手動 diff 用に `describe` の全文を `before_instance.json` / `before_volumes.json` / `before_enis.json` として保存します（後述の「切替前後 describe の手動 diff」を参照）。

### 02_backup.sh

`create-image` でバックアップ AMI を作成します。名前は `<Nameタグ or インスタンスID>-backup-<YYYYMMDD-HHMMSS>` です。AMI とスナップショットには用途、元インスタンスID、作成日時のタグを付与します。

複数台の場合は2フェーズで動作します。フェーズ1で全対象に `create-image` を発行し（数秒/台）、フェーズ2で全 AMI の `available` をまとめて待ちます。AMI 作成は AWS 側で並列に進むため、所要時間は台数比例ではなく「最も遅い1台分」に近くなります。

注意: デフォルト（reboot あり）では、フェーズ1で**全対象の再起動がほぼ同時に発生**します。同時再起動を避けたいシステム構成（クラスタの過半数維持が必要な場合など）では、`targets.txt` を分けて実行するか `BACKUP_NO_REBOOT=true` を検討してください。

`aws ec2 wait image-available` は固定待機で短いため使わず、`WAIT_IMAGE_AVAILABLE_TIMEOUT` に従って独自ポーリングします。デフォルトは 60 分です。

`02_backup.sh` を再実行すると、各対象の古い `backup_ami_id.txt` を削除してから新しい `create-image` を発行します。発行に失敗した場合は stale な AMI ID を残さないため、再実行前の AMI を使う必要があるときは AWS 側のタグ `SourceInstanceId` から確認してください。`03_switch.sh` は AMI が `available` で、同タグが処理対象IDと一致することを必須確認します。

### 03_switch.sh

中核の切替処理です。

1. 必要に応じて終了保護、停止保護を一時的に無効化
2. 旧 EC2 を停止
3. EBS/ENI の現物が prepare 時の構成と完全一致することを再確認し、全 EBS と全 ENI の `DeleteOnTermination=false`
4. 全 EBS をデタッチ
5. 旧 EC2 を terminate
6. 旧 ENI を DeviceIndex そのままで指定し、新 AMI から新 EC2 を起動
7. 新 EC2 を停止
8. 新 AMI 由来のルートボリュームをデタッチし、削除予定タグを付与
9. 旧 EBS を新 EC2 にアタッチ。旧ルートボリュームは新 AMI の `RootDeviceName` に合わせてアタッチ
10. EBS/ENI の `DeleteOnTermination` を元の値に復元
11. 新 EC2 を起動し、2/2 ステータスチェック OK まで待機

新インスタンスIDと破棄予定ルートボリュームIDは状態ファイルに保存されます。
新 EC2 の起動には client token `switch-ec2-<旧インスタンスID>` を使用します。終了/停止保護を無効化してから terminate を発行する前に失敗した場合は、元の保護値を復元します。

### 04_verify.sh

新旧比較レポートを表示します。

- プライマリプライベート IP 一致
- DeviceIndex ごとの ENI ID 一致
- アタッチ済みボリュームIDとデバイス名一致（ルートはデバイス名差異を許容）
- タグ一致
- インスタンスタイプ一致
- UsageOperation が空でなく旧値から変化したこと、および設定時は `EXPECTED_NEW_USAGE_OPERATION` と一致すること
- EBS/ENI の `DeleteOnTermination` 一致
- MetadataOptions の `HttpTokens` / `HttpEndpoint`、IAMプロファイルArn、EbsOptimized、Monitoring、KeyName の一致
- 終了保護・停止保護の復元
- InstanceInitiatedShutdownBehavior の一致
- MaintenanceOptions.AutoRecovery の一致（保存値が null の場合はスキップ）
- PrivateDnsNameOptions の正規化比較（保存値が null の場合はスキップ）
- CpuOptions の CoreCount / ThreadsPerCore の一致
- CapacityReservationSpecification の正規化比較（保存値が null の場合はスキップ）
- `COPY_USER_DATA=true` の場合は UserData の base64 完全一致

あわせて、切替後の `describe` 全文を `after_instance.json` / `after_volumes.json` / `after_enis.json` として保存します（後述の「切替前後 describe の手動 diff」を参照）。


### 05_rollback.sh

`02_backup.sh` が旧 PAYG EC2 から作成したバックアップ AMI の Block Device Mapping をそのまま使い、
スナップショット由来の新規 EBS を持つ復旧 EC2 を起動します。ELC 新 EC2 の全 EBS は
`DeleteOnTermination=false` を実測確認してからデタッチし、`available` のまま残置します。
保全 ENI は DeviceIndex を維持して復旧 EC2 に再利用するため、IP、EIP、MAC、SG を維持します。

破壊操作前に、バックアップ AMI の SourceInstanceId・Architecture・BootMode・UsageOperation、
AMI の全 BDM と SnapshotId、スナップショットの `completed`、ELC 新 EC2 の EBS/ENI 現物構成を確認します。
追加 EBS は既定で中止し、確認済みの場合だけ環境変数 `ROLLBACK_ALLOW_EXTRA_VOLUMES=true` で保全して続行します。
この追加 EBS は DOT=false 化とデタッチを行いますが、ロールバック用タグは付けません。

### 06_verify_rollback.sh

復旧 EC2 の IP、ENI、起動属性、保護設定、タグ、インスタンスタイプを旧ベースラインと照合し、
`UsageOperation` が `usage_operation.json` の旧 PAYG 値へ戻ったことを確認します。方式上 VolumeId は
必ず変わるため、EBS はデバイス名、DeleteOnTermination、バックアップ AMI の SnapshotId、
サイズ、タイプ、IOPS、Throughput、暗号化属性で照合します。保全 EBS の残置、ELC 新 EC2 の
terminated、復旧 EC2 の 2/2 ステータス、全 ENI のアタッチも独立に再確認します。

## 切替前後 describe の手動 diff

`04_verify.sh` の項目別チェックは「見るべき項目を見る」検証です。それとは別に、**想定していない箇所が変化していないか**を目視で確認するため、instance / volume / ENI の `describe` 全文を切替前後で保存しています。

| 取得タイミング | ファイル |
| --- | --- |
| 切替前（`01_prepare.sh`） | `before_instance.json` / `before_volumes.json` / `before_enis.json` |
| 切替後（`04_verify.sh`） | `after_instance.json` / `after_volumes.json` / `after_enis.json` |

いずれも `${WORK_DIR}/<instance-id>/` に保存されます。フィールドは一切間引いておらず、`jq -S` によるキー順ソートと、AWS が順序を保証しない配列（`BlockDeviceMappings`、`NetworkInterfaces`、`SecurityGroups`、`Tags`、`Attachments` など）の ID 順ソートだけを適用しているので、そのまま `diff` が取れます。

```bash
diff -u work/<old-instance-id>/before_instance.json work/<old-instance-id>/after_instance.json
diff -u work/<old-instance-id>/before_volumes.json  work/<old-instance-id>/after_volumes.json
diff -u work/<old-instance-id>/before_enis.json     work/<old-instance-id>/after_enis.json
```

volume / ENI は「新インスタンスに実際に付いているもの」を対象に取得するため、破棄した新AMI由来ルートは含まれず、before 側と同じ集合になります。

### 切替前後 describe の想定 diff

以下は切替の設計上**必ず、または環境により変化する**箇所です。これ以外に差分が出た場合は想定外なので、原因を確認してください。

instance（`before_instance.json` → `after_instance.json`）:

| キー | 変化する理由 |
| --- | --- |
| `InstanceId` | 新 EC2 に置き換わるため |
| `LaunchTime` | 新 EC2 の起動時刻 |
| `ImageId` | 起動元が `NEW_AMI_ID` になるため |
| `ClientToken` | `switch-ec2-<旧インスタンスID>` が入る |
| `ReservationId` / `RequesterId` | 新しい RunInstances の予約 |
| `BlockDeviceMappings[].Ebs.AttachTime` | 新 EC2 へのアタッチ時刻 |
| `NetworkInterfaces[].Attachment.AttachmentId` / `AttachTime` | ENI の再アタッチ |
| `UsageOperation` / `UsageOperationUpdateTime` | ライセンス切替の本来の目的。旧 PAYG から新 AMI 由来の値へ変化する |
| `AmiLaunchIndex` / `StateTransitionReason` | 新規起動に伴い再設定される |
| 旧ルートの `BlockDeviceMappings[].DeviceName` | 旧ルート名と新 AMI の `RootDeviceName` が異なる場合のみ（例 `/dev/sda1` → `/dev/xvda`） |
| `PrivateDnsName` / `PrivateDnsNameOptions` 関連 | 新インスタンスIDで再生成される環境がある |
| `BootMode` / `CurrentInstanceBootMode` | 新 AMI の BootMode に従う（`uefi-preferred` AMI など） |
| `aws:` 予約タグ | ユーザーがコピーできないため引き継がれない |

volumes（`before_volumes.json` → `after_volumes.json`）:

| キー | 変化する理由 |
| --- | --- |
| `Attachments[].InstanceId` | 新 EC2 に付け替わるため |
| `Attachments[].AttachTime` | 再アタッチ時刻 |
| `Attachments[].Device` | 旧ルートのみ、新 `RootDeviceName` に合わせる場合 |
| `State` | 取得タイミングにより `in-use` 以外が見えることがある |

eni（`before_enis.json` → `after_enis.json`）:

| キー | 変化する理由 |
| --- | --- |
| `Attachment.AttachmentId` / `AttachTime` / `InstanceId` / `InstanceOwnerId` | 新 EC2 への再アタッチ |
| `Status` | 取得タイミングにより変化 |
| `Association` 系 | Elastic IP の再関連付けがある場合 |

参考として、検証環境（同一構成・同一 AZ）で実測した際の差分は `InstanceId` / `LaunchTime` / `ImageId` / `ClientToken` / `ReservationId` / `AttachTime` / `AttachmentId` / `UsageOperationUpdateTime` のみでした。

### 切り戻し前後 describe の想定 diff

`06_verify_rollback.sh` は `after_rollback_instance.json` / `after_rollback_volumes.json` /
`after_rollback_enis.json` を保存します。方式Bでは AMI スナップショットから全 EBS を作り直すため、
次の差分は設計どおりです。

- instance: `InstanceId`、`LaunchTime`、`ImageId`（バックアップ AMI ID）、`ClientToken`
  （`switch-ec2-rollback-<旧ID>`）、`ReservationId`、`AmiLaunchIndex`、`StateTransitionReason`、
  `BlockDeviceMappings[].Ebs.VolumeId`、`AttachTime`、ENI の `AttachmentId`、
  `UsageOperationUpdateTime`、PrivateDnsName 関連、`aws:` 予約タグ
- volumes: `VolumeId`、`CreateTime`、`SnapshotId`、`Attachments[].InstanceId`、`AttachTime`、
  `Tags`（後述）、`Device`（後述の並び順による見かけ上の差分）
- eni: `Attachment.AttachmentId`、`AttachTime`、`InstanceId`、`InstanceOwnerId`、取得時点による `Status`

これ以外の差分は想定外として原因を確認してください。

volumes の `Device` 差分は**並び順による見かけ上のもの**です。`after_rollback_volumes.json` は
ボリュームID順にソートされますが、方式Bでは全ボリュームのIDが変わるため、データボリュームが
複数ある場合に配列内の順序が入れ替わります。デバイス名の**集合**が一致していれば正常です。
`06_verify_rollback.sh` はデバイス名で対応付けて比較するため、この並び替えの影響を受けません。

```bash
# 集合として一致していることの確認
jq -c '[.Volumes[].Attachments[0].Device] | sort' work/<old-instance-id>/before_volumes.json
jq -c '[.Volumes[].Attachments[0].Device] | sort' work/<old-instance-id>/after_rollback_volumes.json
```

volumes の `Tags` 差分は実体のある差分です。**EBS ボリュームのタグは AMI・スナップショット経由で
引き継がれません。**`create-image` はボリュームのタグをスナップショットへコピーせず、
`run-instances` も AMI から作るボリュームにタグを付けないため、復旧 EC2 のボリュームは
**タグが空の状態で作成されます**（インスタンス本体のタグは 01 が保存した値から復元されるため影響ありません）。
`06_verify_rollback.sh` はボリュームタグを検証対象にしていません。ボリュームのタグを条件にした
AWS Backup のリソース割り当て、DLM のライフサイクルポリシー、コスト配分タグを使っている場合は、
**切り戻し後に手動でタグを付け直してください。**切替前のタグは `before_volumes.json` に残っています。

```bash
# 切替前のボリュームタグを確認する
jq -r '.Volumes[] | [.Attachments[0].Device, (.Tags // [] | map(.Key + "=" + .Value) | join(","))] | @tsv' \
  work/<old-instance-id>/before_volumes.json
```

## OS内想定作業（スクリプト対象外・本番手順に組み込むこと）

本スクリプトは AWS API 操作のみを行います。以下は対象EC2のOS内で実施する作業です。
（プロダクト固有のエージェント類の対応はサーバごとに異なるため、ここでは扱いません）

### 切替前（旧EC2稼働中に実施）

インスタンスID変化により cloud-init が「新しいインスタンス」と判断して初期化処理を再実行するため、次の設定を事前に入れます。1ファイルで両方カバーできます。

```bash
# /etc/cloud/cloud.cfg.d/99-switch-ec2.cfg として配置
sudo tee /etc/cloud/cloud.cfg.d/99-switch-ec2.cfg <<'EOF'
# SSHホスト鍵の削除・再生成を防止（既定 true のままだと切替後に
# 全クライアントで known_hosts 不一致となり SSH 接続が拒否される）
ssh_deletekeys: false
# 独自設定したホスト名がメタデータ既定値（ip-10-x-x-x 形式）に
# 戻されるのを防止（ホスト名を独自設定しているサーバのみ実質的に意味を持つ）
preserve_hostname: true
EOF
```

全対象へSSHできる環境であれば、事前に一括投入できます。

### 切替後（検証PASS後すみやかに実施）

PAYG時代のRHUIリポジトリはELCインスタンスでは認可されず（`dnf` が 403 エラー）、
パッケージ更新・セキュリティパッチ適用ができない状態になるため、サブスクリプションの登録し直しが必要です。

**本案件では Satellite を使用します。具体的な登録手順は専用の手順書に従ってください。**
本 README では扱いません。

なお、OS内でも以下は**作業不要**です（同一ディスク・同一ENIを移すため）:
`/etc/machine-id`・fstab/デバイス名（UUIDマウント維持）・ネットワーク設定（MACアドレスも不変）・時刻同期（Amazon Time Sync）・authorized_keys（cloud-init は追記のみで置換しない）。

## 非対応構成

`01_prepare.sh` は次の構成を検出した場合に中止します。

- placement group
- Dedicated Host（HostId、Affinity=host、Tenancy=host）
- NetworkCardIndex が1以上の ENI を含むマルチネットワークカード
- hibernation
- Nitro Enclaves
- Multi-Attach が有効な EBS
- インスタンスストア（`ALLOW_INSTANCE_STORE_LOSS=true` で消失を明示許可した場合を除く）
- Spot インスタンス

## 注意事項

- 旧 EC2 は terminate されます。プライマリ ENI は running/stopped インスタンスから単独デタッチできないため、同一 IP を引き継ぐには旧 EC2 の terminate が必要です。
- Elastic IP は ENI に紐付くため、ENI ごと移すことで自動的に維持されます。
- cloud-init のインスタンスID変化対策（SSHホスト鍵・ホスト名）と、切替後のサブスクリプション再登録は「OS内想定作業」の節を参照してください。
- 新 AMI 由来の RHEL 9.8 ルートボリュームは削除しません。`Purpose=switch-ec2-discarded-root` と `DeleteAfterVerification=true` のタグを付けるので、検証完了後に手動削除してください。
- `aws:` で始まるタグは AWS 予約タグのため新 EC2 にコピーできません。引き継ぎ対象外とし、`04_verify.sh` のタグ比較でも除外します。
- UserData は既定で引き継ぎません。再実行リスクを確認のうえ、必要な場合だけ `COPY_USER_DATA=true` を設定してください。
- インスタンスストアボリュームは引き継げません。既定では検出時に中止し、`ALLOW_INSTANCE_STORE_LOSS=true` の場合だけ警告して続行します。
- BootMode 不一致は起動不能リスクが高いためエラーにします。`uefi-preferred` AMI と `uefi` の組み合わせは許容しますが、`legacy-bios` との組み合わせは既定で中止します。旧OSディスクのハイブリッドブート対応を確認済みの場合だけ `ALLOW_UEFI_PREFERRED_ON_BIOS=true` を使用してください。
- cloud-init の OS 内事前作業（`ssh_deletekeys: false` / `preserve_hostname: true`）は、必ず
  `02_backup.sh` より前にディスクへ永続化してください。後から行うとバックアップ AMI に含まれず、
  復旧 EC2 で SSH ホスト鍵が再生成されます。
- 切り戻すと、OS 内のサブスクリプション登録状態もバックアップ AMI 取得時点（PAYG）へ戻ります。
  切替後に Satellite 側へ登録した情報との整合は、専用の手順書に従って確認してください。
- `cloud.cfg.d` への設定ファイル配置など、02 より前にディスクへ永続化した恒久対策は復旧後も有効です。
  一方、cloud-init キャッシュの一時的な手動クリアなど AMI に結果が入らない対処は、復旧後に同じ症状が再発し得ます。
- 復旧 EC2 の EBS と残置する保全 EBS はファイルシステム UUID が同一です。データ救出時に保全 EBS を
  復旧 EC2 へ同時アタッチせず、必ず別インスタンスへアタッチしてください。
- インスタンス ID は旧 PAYG → ELC → 復旧の3世代で変化します。CloudWatch アラーム、SSM、
  ターゲットグループなど instance-id をキーにした外部リソースを再設定してください。
- **EBS ボリュームのタグは復旧 EC2 へ引き継がれません。**AMI スナップショットから作られる
  ボリュームはタグが空になります。ボリュームのタグを条件にした AWS Backup・DLM・コスト配分タグを
  使っている場合は、`before_volumes.json` を参照して切り戻し後に手動で付け直してください
  （詳細は「切り戻し前後 describe の想定 diff」を参照）。
- 切り戻し後もスクリプトはリソースを自動削除しません。検証とデータ救出判断の完了後に、
  (1) `rollback_preserved_volume_ids.txt` の保全 EBS、(2) `discarded_root_volume_id.txt` の03由来ルート、
  (3) `backup_ami_id.txt` の AMI とスナップショット、(4) opt-in で保全したタグなし追加 EBS、
  の順に対象を特定して手動削除してください。

## 切り戻し概要

切替後に問題がある場合は `05_rollback.sh` を実行し、その後 `06_verify_rollback.sh` で検証します。
採用方式は**バックアップ AMI のスナップショットからの完全復元（方式B）**です。復旧 EC2 のデータは
`02_backup.sh` の AMI 取得時点まで巻き戻り、それ以降の書き込みは失われます。

概要:

1. 状態ファイル、バックアップ AMI/スナップショット、ELC 新 EC2 の現物構成を read-only で事前確認
2. ELC 新 EC2 の保護を解除して停止
3. 現物の全 EBS/ENI を `DeleteOnTermination=false` にし、API 実測で確認
4. ELC 新 EC2 の全 EBS をデタッチして `available` で残置
5. ELC 新 EC2 を terminate し、全 ENI の `available` を待機
6. バックアップ AMI の BDM を変更せず、保全 ENI を DeviceIndex 維持で指定して復旧 EC2 を起動
7. 復旧 EC2 の 2/2 ステータスチェックを待機
8. EBS/ENI の `DeleteOnTermination` と停止保護を切替前の値へ復元
9. 残置 EBS に識別・UUID重複警告タグを付与し、最終状態を保存
10. `06_verify_rollback.sh` で PAYG への復帰と AWS 側構成を検証し、OS 内項目を手動確認

保全済み旧 EBS を復旧 EC2 に付け替える旧手順は使用しません。保全 EBS は ELC 稼働中のデータ救出用として残します。

## 手動復旧 runbook

`03_switch.sh` は途中失敗後の自動リランに対応しません。失敗した対象へそのまま再実行せず、ログと状態ファイルから到達フェーズを判定して次の手順で復旧してください。以下の例では `OLD=i-...`、`DIR="${WORK_DIR:-./work}/$OLD"` を設定済みとします。リージョンを明示する環境では各 `aws` コマンドへ `--region` を追加してください。

### 旧 EC2 停止後から terminate 前まで

このフェーズでは旧 EC2 は残っています。スクリプトの保護復元ログを確認し、必要なら prepare 時の値に戻して起動します。

```bash
[[ $(jq -r . "$DIR/disable_api_termination.json") == true ]] && \
  aws ec2 modify-instance-attribute --instance-id "$OLD" --disable-api-termination
[[ $(jq -r . "$DIR/disable_api_stop.json") == true ]] && \
  aws ec2 modify-instance-attribute --instance-id "$OLD" --disable-api-stop

# EBS をデタッチ済みの場合は block_devices.json の VolumeId/DeviceName で全件を戻す
jq -r '.[] | [.VolumeId,.DeviceName] | @tsv' "$DIR/block_devices.json" |
while IFS=$'\t' read -r volume device; do
  aws ec2 attach-volume --volume-id "$volume" --instance-id "$OLD" --device "$device"
  aws ec2 wait volume-in-use --volume-ids "$volume"
done
aws ec2 start-instances --instance-ids "$OLD"
```

prepare 後の構成変更検出で停止した場合は、旧 EC2 を再開した後に変更内容を確認し、切替を再計画する場合だけ `new_instance_id.txt` がないことを確認して `01_prepare.sh` から取り直します。

### terminate 後から run-instances 前まで

旧 EC2 は戻せないため、保全済み ENI/EBS と状態ファイルを使ってステップ6以降を手動実行します。まず ENI/EBS が利用可能か確認し、run-instances 用 ENI JSONを作ります。

```bash
jq -r '.[].NetworkInterfaceId' "$DIR/enis.json" |
while read -r eni; do
  aws ec2 wait network-interface-available --network-interface-ids "$eni"
done
jq '[.[] | {NetworkInterfaceId,DeviceIndex,DeleteOnTermination:false}]' \
  "$DIR/enis.json" > /tmp/switch-ec2-network-interfaces.json
jq '{AvailabilityZone,Tenancy} | with_entries(select(.value != null))' \
  "$DIR/placement.json" > /tmp/switch-ec2-placement.json
jq '{HttpTokens,HttpPutResponseHopLimit,HttpEndpoint,HttpProtocolIpv6,InstanceMetadataTags}
    | with_entries(select(.value != null))' \
  "$DIR/metadata_options.json" > /tmp/switch-ec2-metadata-options.json

aws ec2 run-instances \
  --image-id "$NEW_AMI_ID" \
  --instance-type "$(jq -r . "$DIR/instance_type.json")" \
  --count 1 \
  --client-token "switch-ec2-${OLD}" \
  --network-interfaces file:///tmp/switch-ec2-network-interfaces.json \
  --placement file:///tmp/switch-ec2-placement.json \
  --metadata-options file:///tmp/switch-ec2-metadata-options.json
```

KeyName、IAMプロファイル、EbsOptimized、Monitoring、タグ、終了保護、CreditSpecification も各状態ファイルの値に従って `03_switch.sh` のステップ6と同じ引数を追加してください。返された InstanceId を `new_instance_id.txt` に保存し、新 EC2 を停止、新 AMI 由来ルートをデタッチしてから、`block_devices.json` の各 EBS をアタッチします。旧ルートだけは新 EC2 の `RootDeviceName` をデバイス名に使用します。

### run-instances の応答喪失時

同じ client token で別インスタンスを増やさず、次のコマンドで起動済みインスタンスを特定します。

```bash
aws ec2 describe-instances \
  --filters "Name=client-token,Values=switch-ec2-${OLD}" \
  --query 'Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name}'
```

特定したIDを `new_instance_id.txt` に保存して手動継続します。該当がないことを確認できた場合だけ、同じ client token で `run-instances` を再発行します。

### attach 以降

`new_instance_id.txt` で操作対象を、`discarded_root_volume_id.txt` で新 AMI 由来の退避ルートを確認します。`block_devices.json` の全 VolumeId が新 EC2 に期待デバイス名で `attached` かを `describe-volumes` で確認し、不足分だけ `attach-volume` します。その後 DeleteOnTermination、停止/終了保護を状態ファイルどおりに復元し、新 EC2 を起動して `04_verify.sh` と OS 内比較を実行します。退避ルートは検証完了まで削除しません。

### 05_rollback.sh が途中失敗した場合

`05_rollback.sh` は `rollback_instance_id.txt` がある対象への再実行を禁止します。ファイルが無い場合も、
破壊操作開始後はそのまま再実行せず `05_rollback.log` と AWS 現物から到達位置を確認してください。

- terminate 前: ELC 新 EC2 は stopped で残ります。ERR トラップの保護復元ログを確認し、
  EBS をデタッチ済みなら `rollback_preserved_volume_ids.txt` と切替後のデバイス名を参照して再アタッチし、
  ELC 新 EC2 を起動します。
- terminate 後から run-instances 前: ELC 新 EC2 は戻せません。`enis.json` の全 ENI が `available`、
  バックアップ AMI が `available` であることを確認し、05 のステップ6と同じ引数で手動起動します。
- run-instances 応答喪失: 同じトークンで再発行せず、次のコマンドで起動済み復旧 EC2 を特定します。

```bash
aws ec2 describe-instances \
  --filters "Name=client-token,Values=switch-ec2-rollback-${OLD}" \
  --query 'Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name}'
```

特定した ID を `rollback_instance_id.txt` に保存し、DeleteOnTermination、停止保護、保全 EBS タグ、
`rollback_instance_after.json` を05の後続ステップどおり手動で確定してから `06_verify_rollback.sh` を実行します。

## 構文チェック

```bash
bash -n lib/common.sh 01_prepare.sh 02_backup.sh 03_switch.sh 04_verify.sh 05_rollback.sh 06_verify_rollback.sh
```

`shellcheck` がある環境では、追加で以下を実行してください。

```bash
shellcheck lib/common.sh 01_prepare.sh 02_backup.sh 03_switch.sh 04_verify.sh 05_rollback.sh 06_verify_rollback.sh
```

## 検証環境

`test-env/` は検証専用の Terraform 環境です。本番の切替手順には含めず、
環境固有情報（tfstate・検証レポート等）を含むため**リポジトリ管理外**（gitignore 対象）です。
ローカルに存在する場合、構築・検証・後片付け手順は `test-env/README.md` を参照してください。
