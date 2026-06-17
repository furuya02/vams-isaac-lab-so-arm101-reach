# config/ — VAMS デプロイ設定

VAMS 本体（`awslabs/visual-asset-management-system`）の `infra/config/config.json` に反映する
**変更差分**をここで管理する。`config.json` 全体はバージョンごとにスキーマが変わるため丸ごとは持たず、
**「commercial テンプレートをコピーして、以下のキーだけ変更する」**方式とする。

対象 VAMS: **v2.5.1**（Isaac Lab パイプライン対応は v2.4.0+）

## 手順

```bash
# VAMS リポジトリ内で
cp infra/config/config.template.commercial.json infra/config/config.json
# 下表のキーを編集（jq でのパッチ例は config-patch.jq を参照）
```

## 変更するキー（既定 → 設定値）

| キーパス | 既定 | 設定値 | 理由 |
|---|---|---|---|
| `app.openSearch.useServerless.enabled` | true | **false** | OpenSearch 無効化（常駐費の最大要因を回避） |
| `app.openSearch.useProvisioned.enabled` | false | false | 両 false で「none」 |
| `app.pipelines.useIsaacLabTraining.enabled` | false | **true** | Isaac Lab 学習パイプライン有効化 |
| `app.pipelines.useIsaacLabTraining.acceptNvidiaEula` | false | **true** | NVIDIA EULA 受諾（未設定だとデプロイ失敗） |
| `app.pipelines.useIsaacLabTraining.keepWarmInstance` | false | false | GPU 常時起動を避ける |
| `app.useGlobalVpc.enabled` | false | **true** | VPC モード（パイプライン有効化で自動 true 化されるが明示） |
| `env.region` | null | （`-c` か環境変数で `ap-northeast-1`） | リージョン |

> NAT Gateway は VAMS が自動作成する（必須・回避不可）。OpenSearch none・ALB なしなら 1 AZ＝NAT 1 個。
> 詳細・根拠は ブログ側 `Blog/vams-deploy-requirements.md` §3 を参照。

## jq パッチ例

`config-patch.jq` を使うと上記変更を一括適用できる:

```bash
cp infra/config/config.template.commercial.json infra/config/config.json
jq -f /path/to/this/config/config-patch.jq infra/config/config.json > /tmp/c.json \
  && mv /tmp/c.json infra/config/config.json
```
