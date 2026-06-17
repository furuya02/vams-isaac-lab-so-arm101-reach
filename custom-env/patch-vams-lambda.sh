#!/usr/bin/env bash
# VAMS の Isaac Lab 実行 Lambda が inputParameters の customEnvironmentS3Uri を
# job config に伝播していない不具合を修正する。
# 問題: vamsExecuteIsaacLabPipeline.py の sfn_input は trainingConfig/computeConfig しか
#       inputParameters から取り出さず、customEnvironmentS3Uri が常に空 → カスタム環境が
#       install されず、Isaac-SO-ARM101-Reach-Grasp-v0 が gym 未登録で NameNotFound になる。
# 修正: sfn_input に customEnvironmentS3Uri を input_params から追加。
# 適用後に cdk deploy（該当 Lambda コード更新）が必要。
set -euo pipefail
WORKDIR="${WORKDIR:-$HOME/work/vams}"
F="${WORKDIR}/visual-asset-management-system/backendPipelines/simulation/isaacLabTraining/lambda/vamsExecuteIsaacLabPipeline.py"
[ -f "$F" ] || { echo "ERROR: $F が見つかりません"; exit 1; }

if grep -q '"customEnvironmentS3Uri": input_params.get' "$F"; then
  echo "既に適用済み"
else
  # computeConfig 行の直後に customEnvironmentS3Uri 行を挿入
  python3 - "$F" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
anchor = '            "computeConfig": input_params.get("computeConfig", {}) if isinstance(input_params, dict) else {},\n'
add = '            "customEnvironmentS3Uri": input_params.get("customEnvironmentS3Uri", "") if isinstance(input_params, dict) else "",\n'
if anchor not in s:
    sys.exit("anchor 行が見つかりません（VAMS のバージョン差の可能性）")
s = s.replace(anchor, anchor + add, 1)
open(p, "w").write(s)
print("適用: sfn_input に customEnvironmentS3Uri を追加")
PY
fi
grep -n 'customEnvironmentS3Uri' "$F" || true
