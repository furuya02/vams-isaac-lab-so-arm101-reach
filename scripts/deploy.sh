#!/usr/bin/env bash
# VAMS を Isaac Lab パイプライン有効・OpenSearch none でデプロイする。
# ⚠ 最後の cdk deploy で課金が発生する（VPC/NAT 常駐費＋デプロイ時リソース）。
#    検証後は必ず scripts/destroy.sh を実行すること。
#
# 前提: AWS 認証情報, Node 20+, Python 3.12+, Docker, AWS CDK CLI, jq
set -euo pipefail

# 環境依存のビルド失敗を抑制するための設定。
# CDK の Lambda レイヤー bundling は docker build → docker run を行うが、新しめの buildx(BuildKit)
# ＋ Rancher Desktop / containerd image store 環境では、既定で attestation 付き manifest index が
# 生成され、その結果イメージが docker run 不可になって "pull access denied for cdk-<hash>" で失敗する。
# attestation を無効化して run 可能な単一イメージを生成させ、環境差によらず安定してビルドできるようにする。
# （この問題が出ない環境では無害な設定）
export BUILDX_NO_DEFAULT_ATTESTATIONS=1

REGION="${AWS_REGION:-ap-northeast-1}"
VAMS_REF="${VAMS_REF:-v2.5.1}"                 # Isaac Lab は 2.4.0+。再現性のためタグ固定
WORKDIR="${WORKDIR:-$HOME/work/vams}"
export WORKDIR                                  # 子スクリプト(patch-vams-*.sh)へ確実に継承させる
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # このリポジトリのルート

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "Account=$ACCOUNT_ID Region=$REGION VAMS_REF=$VAMS_REF"

# 0) 前回 destroy の孤児 Location APIキーを事前削除（cdk destroy では消えず、再デプロイで
#    'AWS::Location::APIKey already exists' になり ROLLBACK する。これを防ぐ）
for K in $(aws location list-keys --region "$REGION" \
  --query "Entries[?contains(KeyName,'vams-location-api-key')].KeyName" --output text 2>/dev/null); do
  echo "孤児 Location キーを削除: $K"
  aws location delete-key --key-name "$K" --region "$REGION" --force-delete >/dev/null 2>&1 || true
done

# 1) VAMS 取得（タグ固定）
mkdir -p "$WORKDIR"
if [ ! -d "$WORKDIR/visual-asset-management-system" ]; then
  git clone --depth 1 --branch "$VAMS_REF" \
    https://github.com/awslabs/visual-asset-management-system.git \
    "$WORKDIR/visual-asset-management-system"
fi
cd "$WORKDIR/visual-asset-management-system"

# 1.5) カスタム環境を使う場合の VAMS 修正（フェーズ2 SO-ARM101 で必須・ビルトインのみなら影響なし）
#   ① コンテナ: pip install -e → --no-deps（editable はアーカイブ不可＋依存再取得回避）
#   ② 実行Lambda: inputParameters の customEnvironmentS3Uri を job config に伝播
bash "$REPO_DIR/custom-env/patch-vams-container.sh"
bash "$REPO_DIR/custom-env/patch-vams-lambda.sh"

# 2) config 作成（commercial テンプレ＋本リポジトリの差分パッチ）
cp infra/config/config.template.commercial.json infra/config/config.json
jq -f "$REPO_DIR/config/config-patch.jq" infra/config/config.json > /tmp/vams-config.json
mv /tmp/vams-config.json infra/config/config.json
echo "== applied config (抜粋) =="
jq '{openSearch:.app.openSearch,isaac:.app.pipelines.useIsaacLabTraining,vpc:.app.useGlobalVpc.enabled}' \
  infra/config/config.json

# 3) フロント build / infra deps（VAMS の公式手順は npm を使用）
( cd web && npm install && npm run build )
( cd infra && npm install )

# 4) bootstrap & deploy  ← ★ここから課金
cd infra
npx cdk bootstrap "aws://$ACCOUNT_ID/$REGION"
echo ">>> cdk deploy を開始します（課金開始）。中断する場合は今すぐ Ctrl-C。"
npx cdk deploy --all --require-approval never -c region="$REGION"

echo "デプロイ完了。検証後は片付け（後始末）を忘れずに。放置すると VPC/NAT が課金され続けます。"
