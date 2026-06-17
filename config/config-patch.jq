# VAMS config.template.commercial.json に適用するパッチ（jq -f）
# 使い方:
#   cp infra/config/config.template.commercial.json infra/config/config.json
#   jq -f config/config-patch.jq infra/config/config.json > /tmp/c.json && mv /tmp/c.json infra/config/config.json
#
# OpenSearch を none（常駐費回避）/ Isaac Lab パイプライン有効化 / VPC 有効化。
.app.openSearch.useServerless.enabled = false
| .app.openSearch.useProvisioned.enabled = false
| .app.pipelines.useIsaacLabTraining.enabled = true
| .app.pipelines.useIsaacLabTraining.acceptNvidiaEula = true
| .app.pipelines.useIsaacLabTraining.keepWarmInstance = false
| .app.useGlobalVpc.enabled = true
