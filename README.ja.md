# vams-isaac-lab-so-arm101-reach

> ⚠ 雛形（WIP）。内容は実装フェーズで確定させる。commit/push は未実施。

VAMS（Visual Asset Management System）の NVIDIA Isaac Lab トレーニング機能を使って、
SO-ARM101 の強化学習（Isaac Lab / Reach-Grasp, PPO）を回すための設定・手順・補助スクリプト集。

関連ブログ: 「[VAMS] NVIDIA Isaac Lab トレーニング機能で SO-ARM101 を学習させてみました」

## このリポジトリの位置づけ

VAMS 本体や学習環境そのものは持たず、それらを「つなぐ」接着剤的リポジトリ。

| 要素 | 取得元 | このリポジトリでの扱い |
|---|---|---|
| VAMS 本体 | [awslabs/visual-asset-management-system](https://github.com/awslabs/visual-asset-management-system)（2.4.0+） | clone して使用。`config/` に設定差分を置く |
| 学習環境ベース | [MuammerBay/isaac_so_arm101](https://github.com/MuammerBay/isaac_so_arm101)（BSD-3-Clause） | `custom-env/` のスクリプトで取得・パッケージ化 |
| Reach-Grasp 差分 | [furuya02/isaac-lab-so-arm101-reach-grasp](https://github.com/furuya02/isaac-lab-so-arm101-reach-grasp) | ベースへ上書き適用してカスタム環境化 |

## ディレクトリ構成（予定）

```
vams-isaac-lab-so-arm101-reach/
├── config/        # VAMS config.json の差分・テンプレ（Isaac Lab有効化 / VPC / OpenSearch=none）
├── custom-env/    # カスタム環境パッケージング（setup.py, 差分適用→tar.gz 化スクリプト）
├── scripts/       # デプロイ / 破棄(destroy) / クォータ確認 などの補助
└── docs/          # 図・補足
```

## 前提（下調べ済み・詳細はブログ側ドキュメント参照）

- VAMS 2.4.0+（最新 v2.5.1）。Isaac Lab パイプラインのコンテナは **Isaac Lab 2.3.0 固定**。
- カスタム環境（fork）も Isaac Lab 2.3.0 / Isaac Sim 5.1.0 → **バージョン一致**。
- 必須設定: `app.pipelines.useIsaacLabTraining.{enabled:true, acceptNvidiaEula:true}`、VPC モード必須。
- GPU: ap-northeast-1 で g5/g6/g6e 利用可・vCPU クォータ充足（増枠不要）。

## クイックスタート（詳細・勘所は `docs/runbook.md`）

前提ツール: Node 20+ / Python 3.12+ / Docker / AWS CDK CLI / jq / git / AWS 認証情報。

```bash
git clone <this-repo> && cd vams-isaac-lab-so-arm101-reach

# 0) NGC ログイン（Isaac Lab ベースイメージ pull に必須）
docker login nvcr.io   # Username: $oauthtoken / Password: NGC API キー

# 1) クォータ確認（任意・read-only）
bash scripts/check-quota.sh

# 2) デプロイ（★ここから課金。VAMS clone + VAMSパッチ自動適用 + cdk deploy）
bash scripts/deploy.sh
#   完了後 Outputs を控える: WebsiteEndpointURL / AuthCognitoUserPoolId / AssetS3Bucket

# 3) 管理者パスワード設定 → WebUI ログイン
aws cognito-idp admin-set-user-password --user-pool-id <UserPoolId> \
  --username administrator --password '<大文字含むパスワード>' --permanent --region ap-northeast-1

# 4) カスタム環境 tar.gz 生成 → アセットバケットへアップロード
bash custom-env/build-custom-env.sh
aws s3 cp custom-env/dist/so-arm101-reach-grasp-env.tar.gz \
  s3://<AssetS3Bucket>/custom-env/so-arm101-reach-grasp-env.tar.gz --region ap-northeast-1
```

5. WebUI で Database / Asset 作成 → Pipelines `isaaclab-training` の Input Parameters に
   SO-ARM101 設定（**`customEnvironmentS3Uri` は `trainingConfig` の中**）→ GLOBAL ワークフローで実行。
   具体手順は `docs/runbook.md`「フェーズ2」を参照。
6. **検証後は必ず `bash scripts/destroy.sh`**（放置厳禁）。

> deploy.sh が VAMS 本体に当てるパッチ（カスタム環境を通すのに必須）と、各種ハマり所の対処は
> `docs/runbook.md` に集約。

## 動作確認

- Batch ログ `/aws/batch/job` に `Learning iteration .../500` ＋ SO-ARM101 固有報酬
  （`end_effector_position_tracking` 等）が出れば学習成功。
- アセットの File Manager に `checkpoints/model_*.pt` / `metrics.csv` / `train-config.json` が登録される。
- ⚠ VAMS が SUCCEEDED 表示でも実体は失敗のことがある（偽成功）。必ず Batch ログで確認。

## ⚠ コストと後片付け（重要）

VAMS スタックは VPC / NAT Gateway 等が**起動中ずっと課金**される。検証完了後は
**必ず `bash scripts/destroy.sh`**（内部で `cdk destroy --all`）でスタックを削除すること（放置厳禁）。
`destroy.sh` は誤爆防止の y/N 確認付き（スキップ: `FORCE=1` または `-y`）。

## トラブルシュート：destroy（削除）が失敗するとき

VAMS の destroy は途中の特定リソースで失敗し `DELETE_FAILED` で止まることがある。
**最大の課金源 NAT Gateway は通常 destroy の早い段階で削除される**ので、まず NAT の消滅を確認し、
落ち着いて残りを片付ける。

### 0. まず NAT（課金）が止まったか確認

```bash
aws ec2 describe-nat-gateways --region ap-northeast-1 \
  --filter Name=state,Values=pending,available \
  --query 'NatGateways[].{Id:NatGatewayId,State:State}' --output table
# 空（Deleted のみ）なら主要課金は停止
```

### 1. ApiGatewayV2 Authorizer の InternalFailure で失敗

症状: `AWS::ApiGatewayV2::Authorizer` が `InternalFailure` → 親(Api ネスト/core)が `DELETE_FAILED`。

対処（Authorizer を手動削除してから再 destroy）:
```bash
aws apigatewayv2 get-apis --region ap-northeast-1 \
  --query 'Items[].{Name:Name,ApiId:ApiId}' --output table
# 出た ApiId で Authorizer を一覧
aws apigatewayv2 get-authorizers --api-id <ApiId> --region ap-northeast-1 \
  --query 'Items[].{Name:Name,Id:AuthorizerId}' --output table
# 該当 Authorizer を削除
aws apigatewayv2 delete-authorizer --api-id <ApiId> --authorizer-id <AuthorizerId> --region ap-northeast-1
# 再度 destroy
bash scripts/destroy.sh -y
```

### 1b. サブネットが "has dependencies" で削除できない（VPCエンドポイント ENI 残存）

症状: `AWS::EC2::Subnet ... has dependencies and cannot be deleted` → VPCBuilder/core が `DELETE_FAILED`。
原因: そのサブネットに VPC エンドポイントの ENI（`available`）等が残っている。

対処（残依存を消してから再 destroy）:
```bash
# 失敗メッセージの subnet-id で残 ENI を確認
aws ec2 describe-network-interfaces --region ap-northeast-1 \
  --filters Name=subnet-id,Values=<subnet-id> \
  --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Status:Status,Desc:Description}' --output table
# VPC エンドポイントが残っていれば削除（ENI も解放される）
aws ec2 describe-vpc-endpoints --region ap-northeast-1 --filters Name=vpc-id,Values=<vpc-id> \
  --query 'VpcEndpoints[].VpcEndpointId' --output text
aws ec2 delete-vpc-endpoints --vpc-endpoint-ids <vpce-id> --region ap-northeast-1
# available の ENI が残れば直接削除
aws ec2 delete-network-interface --network-interface-id <eni-id> --region ap-northeast-1
# サブネットの ENI が空になったら再 destroy
bash scripts/destroy.sh -y
```

### 2. 再デプロイ時に Location Service API キーが "already exists"

症状（前回 destroy の孤児が残り、再 deploy が失敗）:
`AWS::Location::APIKey ... already exists` → core が `ROLLBACK_COMPLETE`。

対処（孤児キー削除 → 失敗スタック削除 → 再 deploy）:
```bash
aws location list-keys --region ap-northeast-1 --query 'Entries[].KeyName' --output table
aws location delete-key --key-name <KeyName> --region ap-northeast-1 --force-delete
aws cloudformation delete-stack --stack-name vams-core-prod-ap-northeast-1 --region ap-northeast-1
aws cloudformation wait stack-delete-complete --stack-name vams-core-prod-ap-northeast-1 --region ap-northeast-1
bash scripts/deploy.sh
```

### 3. destroy 後に残る孤児リソース（手動掃除）

destroy が成功しても、RETAIN ポリシー等で以下が残ることがある（コストは小だが掃除推奨）:

```bash
# vams スタックが残っていないか（ap-northeast-1 / us-east-1 両方）
aws cloudformation list-stacks --region ap-northeast-1 \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
  --query 'StackSummaries[?contains(StackName,`vams`)].{Name:StackName,Status:StackStatus}' --output table
aws cloudformation list-stacks --region us-east-1 \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
  --query 'StackSummaries[?contains(StackName,`vams`)].{Name:StackName,Status:StackStatus}' --output table

# 残った S3 バケット（空にして削除）
for B in $(aws s3api list-buckets --query 'Buckets[?contains(Name,`vams`)].Name' --output text); do
  echo "== $B =="; aws s3 rb "s3://$B" --force
done

# ECR の Isaac Lab 孤児イメージ（リポジトリ自体は CDK 共有なので残す。大きいイメージのみ削除）
aws ecr describe-images --repository-name cdk-hnb659fds-container-assets-<ACCOUNT_ID>-ap-northeast-1 \
  --region ap-northeast-1 \
  --query 'sort_by(imageDetails,&imageSizeInBytes)[].{Pushed:imagePushedAt,SizeMB:imageSizeInBytes,Digest:imageDigest}' --output table
# 不要な大きい digest を削除（他スタックが使うイメージは消さない）
# aws ecr batch-delete-image --repository-name <repo> --region ap-northeast-1 --image-ids imageDigest=<digest>
```

> ⚠ WAF スタックは設計上 us-east-1 に作られる（CloudFront 用）。`cdk destroy --all` は両リージョンを削除するが、
> 残った場合は us-east-1 側も確認すること。

## ライセンス

カスタム環境はベース [MuammerBay/isaac_so_arm101](https://github.com/MuammerBay/isaac_so_arm101)
（BSD-3-Clause, Copyright (c) 2025 Muammer Bay (LycheeAI), Louis Le Lay）の派生物。
著作権表示・ライセンスを継承すること。
