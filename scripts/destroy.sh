#!/usr/bin/env bash
# VAMS スタックを削除して常駐費を止める（検証後は必須）。
# deploy と同じ region 解決（-c region）にしてスタック名を一致させる。
# 注意: WAF スタックは設計上 us-east-1 に作られる（CloudFront 用）。core は in-region。
#       cdk destroy --all は両リージョンのスタックをまとめて削除する。
set -euo pipefail
REGION="${AWS_REGION:-ap-northeast-1}"
WORKDIR="${WORKDIR:-$HOME/work/vams}"
# synth 時に Lambda レイヤー bundling が走るため attestation 無効化を引き継ぐ
export BUILDX_NO_DEFAULT_ATTESTATIONS=1
cd "${WORKDIR}/visual-asset-management-system/infra"

# 誤爆防止: 実行前に y/N 確認（FORCE=1 または -y/--yes でスキップ可）
echo ">>> VAMS の全スタックを destroy します (region=${REGION})。"
echo "    これは VAMS スタック(core/waf)を完全削除します。"
if [ "${FORCE:-}" != "1" ] && [ "${1:-}" != "-y" ] && [ "${1:-}" != "--yes" ]; then
  printf "本当に削除しますか？ [y/N]: "
  read -r ans </dev/tty
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "中止しました（何も削除していません）。"; exit 0 ;;
  esac
fi

npx cdk destroy --all --force -c region="${REGION}"

# cdk destroy では消えない孤児 Location APIキーを削除（次回デプロイの衝突防止）
for K in $(aws location list-keys --region "${REGION}" \
  --query "Entries[?contains(KeyName,'vams-location-api-key')].KeyName" --output text 2>/dev/null); do
  echo "孤児 Location キーを削除: $K"
  aws location delete-key --key-name "$K" --region "${REGION}" --force-delete >/dev/null 2>&1 || true
done

echo "destroy 完了。コンソール/Cost Explorer で NAT/EFS/OpenSearch 等の残存が無いか必ず確認してください。"
