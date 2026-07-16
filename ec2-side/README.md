# ec2-side

踏み台EC2上で、対象EC2のOS内ディスク情報をSSH経由で収集・比較するためのスクリプトです。CloudShell 側は AWS API 操作に専念し、SSM/SSH による OS 内実測は行いません。

## 前提

- 踏み台EC2から全対象EC2へSSH接続できること
- 対象EC2のプライマリIPまたはホスト名が、切替前後で同じ対象を指すこと
- 対象EC2のホスト鍵が切替前後で維持されること。cloud-init の `ssh_deletekeys` 既定値（true）により、インスタンスID変化でホスト鍵が再生成される場合があります。その場合は `known_hosts` の更新か `StrictHostKeyChecking` の緩和が必要です。
- 対象EC2が Nitro 世代であること（NVMe の SERIAL に `vol...` が入ることを利用して EBS ボリュームIDと対応付けるため。旧 Xen 世代では SERIAL が空になり対応付けできない）
- 踏み台EC2に `bash`、`ssh`、`awk`、`diff`、`sort` があること
- AWS CLI と `jq` は不要

`blkid` は補助情報です。対象EC2上で `sudo -n blkid` が使えない場合は、一般ユーザーでの `blkid` を試し、それも不可なら空の補助情報として続行します。

## 設定

```bash
cd ec2-side
cp hosts.txt.example hosts.txt
cp ssh.env.example ssh.env
vi hosts.txt
vi ssh.env
```

`hosts.txt` には対象EC2のプライマリIPまたはホスト名を1行1件で記載します。空行と `#` コメントは無視されます。

`ssh.env` には SSH ユーザー、秘密鍵、ポート、追加オプションを設定します。`SSH_KEY` が空の場合は `-i` を付けず、ssh の既定設定または ssh-agent を使います。

## 実行手順

必ず `before` 収集を CloudShell 側の `03_switch.sh` より前に実行してください。切替後に `before` を取り直すと、旧状態の証跡になりません。

```bash
# 1. 踏み台EC2: 切替前のOS内情報を収集
./collect_disk_info.sh before

# 2. CloudShell: AWS側の切替を実行
# ../03_switch.sh

# 3. 踏み台EC2: 切替後のOS内情報を収集
./collect_disk_info.sh after

# 4. 踏み台EC2: ローカル保存済みの before/after を比較
./compare_disk_info.sh
```

収集結果は `work/<ホスト>/` 配下に保存されます。同じ phase のファイルが既にある場合は、上書き前に警告を出します。

## 比較内容

- `lsblk -nP -b -o NAME,SERIAL,UUID,FSTYPE,SIZE`（`KEY="value"` ペア形式。空カラムでも列ずれしない）から、「EBSボリュームID -> ファイルシステムUUID」の対応表を作って before/after を比較
- NVMe の `SERIAL=vol0abc...` は EBS ボリュームID `vol-0abc...` に対応するものとして表示
- パーティションの UUID は、デバイス名の前方一致（例: `nvme0n1p1` -> `nvme0n1`）で親ディスクのボリュームIDに対応付ける
- LVM 論理ボリューム上のファイルシステムUUIDは、親ディスクへの対応付けができないため比較対象外（物理ボリューム側の `LVM2_member` UUID で不変性を担保）
- `/etc/redhat-release` の完全一致を比較

差分がある場合は `diff -u` の結果を表示し、1ホストでも失敗すれば非0終了します。
