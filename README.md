# switch-ec2

RHEL PAYG ライセンスの EC2 を、ELC/BYOS 系 AMI から起動した新 EC2 へ置き換えるための bash スクリプト一式です。

## 全体像

EC2 の課金コード/UsageOperation は、インスタンス起動時に指定した AMI によって決まります。この性質を利用し、ELC/BYOS 系 AMI から新 EC2 を起動したあと、旧 EC2 の全 EBS ボリューム（OS ディスク含む）と ENI を新 EC2 に付け替えます。

旧 OS ディスクをそのまま移すため、起動後の OS は旧 EC2 と同じ RHEL 9.4 のままです。EBS ボリューム自体を再作成しないため、ファイルシステム UUID も保持されます。プライマリ IP、Elastic IP、ENI、タグも引き継ぎます。新 AMI 由来の RHEL 9.8 ルートボリュームは検証完了まで残し、手動削除対象としてタグ付けします。

## ファイル

- `SPEC.md`: 仕様書（方式・処理・状態ファイル・安全ガードの定義）
- `config.env.example`: 設定ファイル例
- `targets.txt.example`: 対象インスタンスIDの例
- `ec2-side/`: 踏み台EC2側のOS内実測スクリプト
- `lib/common.sh`: 共通関数
- `01_prepare.sh`: 事前情報取得と検証
- `02_backup.sh`: バックアップ AMI 作成
- `03_switch.sh`: EC2 切替
- `04_verify.sh`: 切替後確認

## 実行環境

運用環境は CloudShell と踏み台EC2に分けて実行します。

| 環境 | 役割 | 主なスクリプト | 必要な接続/権限 |
| --- | --- | --- | --- |
| CloudShell | AWS API による情報取得、AMI作成、EC2/ENI/EBS切替、AWS側検証 | `01_prepare.sh`、`02_backup.sh`、`03_switch.sh`、`04_verify.sh` | AWS CLI 実行権限 |
| 踏み台EC2 | 対象EC2のOS内情報をSSHで実測し、切替前後をローカル比較 | `ec2-side/collect_disk_info.sh`、`ec2-side/compare_disk_info.sh` | 対象EC2へのSSH到達性 |

## 前提条件

- AWS CloudShell または同等の bash 環境
- AWS CLI v2 と `jq`
- 対象リソースを操作できる admin 相当の権限
- 踏み台EC2から対象EC2へSSH接続できること
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

`targets.txt` は 1 行 1 インスタンスIDです。空行と `#` コメントは無視されます。

## 実行手順

必ず次の順番で実行してください。

```bash
# CloudShell: AWS側の事前情報取得とバックアップAMI作成
./01_prepare.sh
./02_backup.sh

# 踏み台EC2: 切替前のOS内情報を収集
cd ec2-side
./collect_disk_info.sh before
cd ..

# CloudShell: EC2切替とAWS側検証
./03_switch.sh
./04_verify.sh

# 踏み台EC2: 切替後のOS内情報を収集し、before/afterを比較
cd ec2-side
./collect_disk_info.sh after
./compare_disk_info.sh
```

`ec2-side/collect_disk_info.sh before` は必ず `03_switch.sh` より前に実行してください。切替後に before を取り直すと、旧OSディスク・旧UUIDの証跡になりません。
既存の `before_*.txt` が1つでもある場合は誤上書きを防ぐため失敗します。意図的に取り直す場合だけ `./collect_disk_info.sh before --force` を使用してください。収集は一時ファイルへ行い、SSH成功と必須出力の非空を確認してから確定します。

破壊的操作を含む `03_switch.sh` は確認プロンプトを出します。自動実行する場合は `--yes` を付けます。

```bash
./03_switch.sh --yes
```

各スクリプトは `config.env` と `targets.txt` を読み、対象インスタンスを 1 台ずつ処理します。1 台で失敗した場合、そのインスタンスの処理を中断して次の対象へ進み、最後に成功/失敗サマリを表示します。失敗が 1 台でもあれば非 0 で終了します。

状態ファイルは `${WORK_DIR}/<instance-id>/` に保存されます。後続スクリプトは前段の状態ファイルを必須として参照します。

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

ディスクUUIDとOSバージョンのベースライン取得は CloudShell 側では行いません。踏み台EC2上で `ec2-side/collect_disk_info.sh before` を実行して保存します。

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

ディスクUUIDとOSバージョンの実測検証は、踏み台EC2上で `ec2-side/collect_disk_info.sh after` と `ec2-side/compare_disk_info.sh` を実行して確認します。
UUID対応表が before/after のどちらかで空の場合、Xen世代など NVMe SERIAL から EBS ボリュームIDを特定できない構成として FAIL にします。

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

踏み台EC2から全対象へSSHできる環境であれば、事前に一括投入できます。

### 切替後（検証PASS後すみやかに実施）

PAYG時代のRHUIリポジトリはELCインスタンスでは認可されず（`dnf` が 403 エラー）、
パッケージ更新・セキュリティパッチ適用ができない状態になるため、サブスクリプションを登録し直します。

```bash
# 1. RHUIクライアントを撤去（旧PAYG時代のリポジトリ設定ごと削除）
sudo dnf remove 'rh-amazon-rhui-client*'

# 2. ELC契約のサブスクリプションへ登録
#    登録方式（カスタマーポータル直接 / Satellite / アクティベーションキー）は
#    ELC契約の提供形態に依存するため、ライセンス提供元に事前確認すること
sudo subscription-manager register --activationkey=<キー> --org=<組織ID>

# 3. リポジトリが使えることを確認
sudo subscription-manager status
sudo dnf repolist
sudo dnf makecache
```

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
- cloud-init のインスタンスID変化対策（SSHホスト鍵・ホスト名）と、切替後の `subscription-manager` 再登録は「OS内想定作業」の節を参照してください。
- 新 AMI 由来の RHEL 9.8 ルートボリュームは削除しません。`Purpose=switch-ec2-discarded-root` と `DeleteAfterVerification=true` のタグを付けるので、検証完了後に手動削除してください。
- `aws:` で始まるタグは AWS 予約タグのため新 EC2 にコピーできません。引き継ぎ対象外とし、`04_verify.sh` のタグ比較でも除外します。
- UserData は既定で引き継ぎません。再実行リスクを確認のうえ、必要な場合だけ `COPY_USER_DATA=true` を設定してください。
- 対象 EC2 と踏み台EC2のOS側に `jq` は不要です。踏み台側の収集・比較は `bash`、`ssh`、`awk`、`diff`、`sort` を使います。
- インスタンスストアボリュームは引き継げません。既定では検出時に中止し、`ALLOW_INSTANCE_STORE_LOSS=true` の場合だけ警告して続行します。
- BootMode 不一致は起動不能リスクが高いためエラーにします。`uefi-preferred` AMI と `uefi` の組み合わせは許容しますが、`legacy-bios` との組み合わせは既定で中止します。旧OSディスクのハイブリッドブート対応を確認済みの場合だけ `ALLOW_UEFI_PREFERRED_ON_BIOS=true` を使用してください。

## 切り戻し概要

切替後に問題がある場合は、`02_backup.sh` で作成したバックアップ AMI と、保全済み ENI/EBS を使って復旧します。

概要:

1. 新 EC2 を停止
2. 全 EBS/ENI の `DeleteOnTermination=false` を確認・設定
3. 新 EC2 から全 EBS をデタッチ
4. プライマリ ENI は stopped インスタンスからデタッチできないため、新 EC2 を terminate
5. 全 ENI が `available` になるまで待機
6. バックアップ AMI と保全済みの旧 ENI（DeviceIndexを維持）を指定して復旧用 EC2 を起動
7. 復旧用 EC2 を停止
8. 復旧用 AMI 由来のルートボリュームを外す
9. 保全済みの旧 EBS を元の構成で付け替え、EBS/ENI の `DeleteOnTermination` を復元
10. 復旧用 EC2 を起動してサービス確認

実際の切り戻しでは、状態ファイル内の `backup_ami_id.txt`、`enis.json`、`block_devices.json`、`new_instance_id.txt`、`discarded_root_volume_id.txt` を参照してください。

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

## 構文チェック

```bash
bash -n lib/common.sh 01_prepare.sh 02_backup.sh 03_switch.sh 04_verify.sh ec2-side/collect_disk_info.sh ec2-side/compare_disk_info.sh
```

`shellcheck` がある環境では、追加で以下を実行してください。

```bash
shellcheck lib/common.sh 01_prepare.sh 02_backup.sh 03_switch.sh 04_verify.sh ec2-side/collect_disk_info.sh ec2-side/compare_disk_info.sh
```

## 検証環境

`test-env/` は検証専用の Terraform 環境です。本番の切替手順には含めず、
環境固有情報（tfstate・検証レポート等）を含むため**リポジトリ管理外**（gitignore 対象）です。
ローカルに存在する場合、構築・検証・後片付け手順は `test-env/README.md` を参照してください。
