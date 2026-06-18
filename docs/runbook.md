# デプロイ Runbook（VAMS × Isaac Lab × SO-ARM101）

対象 VAMS: **v2.5.1** / リージョン: **ap-northeast-1** / Isaac Lab: **2.3.0**（コンテナ・fork とも一致）

> ⚠ フェーズ1の `cdk deploy` から課金開始（VPC/NAT 常駐費）。検証後は必ず `destroy.sh`。

## 0. 事前準備（課金なし）

- 認証情報設定（`aws sts get-caller-identity` が通ること）
- ツール: Node 20+ / Python 3.12+ / Docker / AWS CDK CLI / jq / git
- クォータ確認: `bash scripts/check-quota.sh`
  - 目安: On-Demand G/VT vCPU が 8 以上（g6.2xlarge/g5.2xlarge 1台＝8vCPU）。ap-northeast-1 で g5/g6/g6e が利用可なら増枠不要なことが多い

## 事前準備（追加）: NGC 認証（Isaac Lab イメージ pull に必須）

Isaac Lab パイプラインのコンテナは `FROM nvcr.io/nvidia/isaac-lab:2.3.0`。nvcr.io は認証必須で、
未ログインだと `failed to fetch oauth token: denied: Access Denied` でビルド失敗する。

1. NGC アカウント作成（無料）→ API キー発行（<https://org.ngc.nvidia.com/setup/api-key>）
2. `docker login nvcr.io`
   - Username: `$oauthtoken`（この文字列そのまま）
   - Password: 発行した NGC API キー
3. ログイン成功後に `bash scripts/deploy.sh`

## deploy.sh が自動適用する VAMS パッチ（フェーズ2を通すのに必須）

`scripts/deploy.sh` は VAMS clone 後、cdk deploy の前に以下を自動適用する（フェーズ1のビルトイン
タスクだけなら不要だが、フェーズ2のカスタム環境では必須）。手動で個別に当てる必要はない。

- `custom-env/patch-vams-container.sh`（コンテナ `__main__.py`）
  - ① `pip install -e <archive>` → `pip install --no-deps <archive>`（editable はアーカイブ不可・依存再取得回避）
  - ② カスタム環境 install 後、その `gymnasium.envs` エントリポイントのモジュールを
       stock RL train.py の `import isaaclab_tasks` 直後に import 注入（タスク登録のため）
- `custom-env/patch-vams-lambda.sh`（実行 Lambda）: 参考用（openPipeline 経路では未使用だが無害）
- `config/config-patch.jq`: OpenSearch none / Isaac Lab 有効 / VPC 有効

> なぜ必要か（詳細は `Blog/トピック.md` §1c/1d）: stock train.py は `isaaclab_tasks` しか import せず、
> この gymnasium は `gymnasium.envs` プラグインを自動ロードしないため、外部カスタム環境のタスクが
> gym 未登録（NameNotFound）になる。①②でこれを解消する。

## フェーズ1: VAMS 疎通（★課金）

1. デプロイ: `bash scripts/deploy.sh`
   - VAMS を `v2.5.1` で clone → 上記パッチ＆`config-patch.jq` 適用 → `npm run build`
     → `cdk bootstrap` → `cdk deploy --all`
   - 完了後の Outputs を控える（`WebsiteEndpointURLOutput` / `AuthCognitoUserPoolId` / `AssetS3BucketNameOutput0`）
2. 管理者ユーザのパスワード設定（メールはダミーのため CLI で設定）:
   ```bash
   aws cognito-idp admin-set-user-password \
     --user-pool-id <AuthCognitoUserPoolId> --username administrator \
     --password '<大文字含むパスワード>' --permanent --region ap-northeast-1
   ```
   → WebsiteEndpointURL に `administrator` でログイン
3. ビルトイン例で疎通確認:
   - Manage → Databases → Create（例 `smoke-db`）/ Create Asset（例 `cartpole`）
   - **GLOBAL ワークフロー**を作成して実行（重要・後述）。task 既定は `Isaac-Cartpole-Direct-v0`
   - 初回 Batch ジョブはコンテナ pull に 5〜10 分
4. Batch ログ（`/aws/batch/job`）に学習 iteration が出て SUCCEEDED、成果物がアセットに登録されることを確認

### GLOBAL ワークフローの作り方（必須の勘所）
Isaac Lab パイプラインは GLOBAL データベース所属。**通常DBのワークフローからは実行不可**
（`get_pipelines(workflowDB,...)` が GLOBAL を引けず IndexError → Internal Server Error）。
GLOBAL ワークフローを作る:
- ブラウザで `<WebsiteEndpointURL>/#/databases/GLOBAL/workflows/create`（**ハッシュ `#/` 必須**。
  直 URL は S3 が AccessDenied）。画面が「Global Workflow」表示になればOK
- or 左ナビ Workflows（DB未指定）→ Create → DB選択モーダルで GLOBAL
- Workflow Details で名前、Pipelines で `isaaclab-training` を選択して Save
- 実行はアセットの **Workflows タブ → Execute Workflow** から（GLOBAL ワークフローも選択肢に出る）

> ※ `autoRegisterWithVAMS` で `isaaclab-training`/`isaaclab-evaluation` の GLOBAL ワークフローは
> 自動作成されるので、それをそのまま使ってもよい（実行時にパイプラインの最新 inputParameters を参照する）。

## フェーズ2: SO-ARM101 投入（★課金）

1. カスタム環境 tar.gz 生成: `bash custom-env/build-custom-env.sh`
   - ベース `isaac_so_arm101` ＋ fork 差分3ファイルをまとめ、pyproject に
     `[project.entry-points."gymnasium.envs"] __root__ = "isaac_so_arm101.tasks"` を注入して tar.gz 化
   - 出力: `custom-env/dist/so-arm101-reach-grasp-env.tar.gz`
2. tar.gz を **アセットの S3 バケットへアップロード**（Batch ジョブのロールが読める場所）:
   ```bash
   aws s3 cp custom-env/dist/so-arm101-reach-grasp-env.tar.gz \
     s3://<AssetS3BucketNameOutput0>/custom-env/so-arm101-reach-grasp-env.tar.gz --region ap-northeast-1
   ```
3. パイプライン `isaaclab-training` の inputParameters を設定（Pipelines → 選択 → Edit →
   「Input Parameters」欄）:
   ```json
   {
     "trainingConfig": {
       "mode": "train",
       "task": "Isaac-SO-ARM101-Reach-Grasp-v0",
       "rlLibrary": "rsl_rl",
       "numEnvs": 4096,
       "maxIterations": 500,
       "customEnvironmentS3Uri": "s3://<AssetS3BucketNameOutput0>/custom-env/so-arm101-reach-grasp-env.tar.gz"
     },
     "computeConfig": { "numNodes": 1 }
   }
   ```
   → **Update Pipeline**
   - ★最重要: `customEnvironmentS3Uri` は **`trainingConfig` の「中」**に置く
     （openPipeline.py が `training_config.get("customEnvironmentS3Uri")` で読む。top-level だと空になり
      `Using built-in ...` になってカスタム環境が入らない）
   - ⚠ `cdk deploy` を実行するたびに autoRegister で inputParameters が既定(Cartpole)へ
     **リセット**される。再デプロイ後は必ずこの手順を再実行する
4. GLOBAL ワークフロー（`isaaclab-training`）をアセットの Workflows タブから Execute Workflow で実行
5. Batch ログ（`/aws/batch/job`）で検証:
   - `customEnvironmentS3Uri: s3://...`（空でない）→ `Downloading custom environment` → `Successfully installed`
   - `[VAMS] injected custom-env task import into .../train.py: ['isaac_so_arm101.tasks']`
   - `NameNotFound` が出ず `Learning iteration .../500` ＋ SO-ARM101 固有報酬
     （`Episode_Reward/end_effector_position_tracking`, `position_success_1cm` 等）
6. 学習済みポリシー（`checkpoints/model_*.pt` / `metrics.csv` / `train-config.json`）がアセットに登録される
7. （任意）`mode:"evaluate"` + `checkpointPath` で評価・動画記録

> ⚠ 偽成功の罠: 学習が NameNotFound 等で落ちてもコンテナラッパーは exit 0 を返し、VAMS は SUCCEEDED
> 表示になる（実行 ~18秒で終わるのが目印）。必ず Batch ログ `/aws/batch/job` で実体を確認する。

## 後片付け（★必須）

- `bash scripts/destroy.sh`（AWS クラウド側のリソースを削除。NAT/VPC 常駐課金の停止）
- Cost Explorer / マネジメントコンソールで NAT GW・EFS・ECR・OpenSearch 等の残存がないか確認
- 放置厳禁（NAT/VPC が常駐課金）

### ローカル作業ディレクトリ（`$WORKDIR` 既定 `~/work/vams`）について
`destroy.sh` は **AWS 上のリソースのみ**削除し、**ローカルの clone は削除しない**。実行後も以下が残る:
```
~/work/vams
├── isaac_so_arm101              # カスタム環境のベース（build-custom-env.sh が clone）
├── reach-grasp                  # fork 差分（同上）
└── visual-asset-management-system  # VAMS 本体（deploy.sh が clone）
```
- これらは次回の `deploy.sh` / `build-custom-env.sh` の作業ディレクトリとして再利用される（既にあれば再 clone をスキップ）。
- **不要なら削除して問題ない**（数 GB 規模。次回実行時に再 clone される）:
  ```bash
  rm -rf ~/work/vams
  ```
- 別の場所を使いたい場合は `WORKDIR=/path/to/dir bash scripts/deploy.sh` で変更可。

## トラブルシュート

### `cdk deploy` が `pull access denied for cdk-<hash>` / `docker exited with status 125` で失敗

- 症状: Lambda レイヤー bundling 中に `Unable to find image 'cdk-<hash>:latest' locally` →
  `pull access denied ... repository does not exist`。
- 原因: buildx(BuildKit) が既定で **attestation 付き manifest index** を生成し、その結果イメージが
  `docker run` 不可になる（Rancher Desktop / Docker の containerd image store 環境で発生）。
  CDK は `docker build` → `docker run cdk-<hash>` の順で bundling するため run 段で落ちる。
- 切り分け済み: ビルダーを docker ドライバへ切替えても直らない。**attestation 無効化が決定打**。
- 対策: deploy.sh は `export BUILDX_NO_DEFAULT_ATTESTATIONS=1` を設定済み。手動なら同変数を
  export してから `cdk deploy`。
- 補足: この失敗は **synth/bundling 段階**で起きるため、CloudFormation デプロイ前＝VPC/NAT 等の
  課金リソースは未作成（`cdk bootstrap` の CDKToolkit のみ）。

### Isaac Lab イメージ build が `failed to fetch oauth token: denied: Access Denied`
- 原因: nvcr.io 未ログイン。→ `docker login nvcr.io`（user `$oauthtoken` / NGC API キー）後に再デプロイ。

### 学習が `gymnasium.error.NameNotFound: Environment Isaac-SO-ARM101-Reach-Grasp ...`
- 原因の切り分けは Batch ログで:
  - Job Config の `customEnvironmentS3Uri` が空 / `Using built-in ...` → inputParameters の
    `customEnvironmentS3Uri` を **trainingConfig の中**に入れていない（フェーズ2手順3）。
  - `Successfully installed` は出るが NameNotFound → コンテナのタスク import 注入が未適用
    （`patch-vams-container.sh` の②）。deploy.sh 経由なら自動適用される。
- いずれも再デプロイで autoRegister により inputParameters が Cartpole 既定へ戻る点に注意（手順3を再実行）。

### 再デプロイで `AWS::Location::APIKey ... already exists`（ROLLBACK）
- 前回 destroy の孤児 Location キー。deploy.sh は起動時に自動削除するが、手動なら
  `aws location delete-key --key-name <name> --force-delete` → 失敗スタック delete → 再デプロイ。

### destroy が DELETE_FAILED（サブネット has dependencies / Authorizer InternalFailure）
- README「トラブルシュート」を参照（VPCエンドポイント/ENI 削除 → 再 destroy、または delete-authorizer → 再 destroy）。

## コスト目安（詳細は Blog/cost-estimate.md）

- 常駐（OpenSearch none・NAT×1）: 約 $2〜4/日
- GPU 学習: 1 回 約 $0.7〜3.5（g6.2xlarge/g5.2xlarge）
- 1〜2日で検証＋destroy: ざっくり **$10〜30**
