#!/usr/bin/env bash
# VAMS の Isaac Lab コンテナ(container/__main__.py)をカスタム環境向けに修正する。
#  ① pip install -e <archive> は editable がアーカイブ不可で失敗 → `pip install --no-deps` に。
#  ② stock train.py は isaaclab_tasks しか import せず、この gymnasium は gymnasium.envs
#     プラグインを自動ロードしないため、外部カスタム環境のタスクが gym 未登録 → NameNotFound。
#     → カスタム環境 install 後、その gymnasium.envs エントリポイントのモジュールを
#       stock RL train.py の `import isaaclab_tasks` 直後に import 注入する処理を追加。
# 適用後に cdk deploy（該当イメージ再ビルド）が必要。
set -euo pipefail
WORKDIR="${WORKDIR:-$HOME/work/vams}"
F="${WORKDIR}/visual-asset-management-system/backendPipelines/simulation/isaacLabTraining/container/__main__.py"
[ -f "$F" ] || { echo "ERROR: $F が見つかりません"; exit 1; }

python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()

# ① pip install -e → --no-deps
if '"install", "-e", local_path' in s:
    s = s.replace('"install", "-e", local_path', '"install", "--no-deps", local_path')
    print("適用①: pip install -e → --no-deps")
else:
    print("①: 既に適用済み（または該当なし）")

# ② カスタム環境タスクの import 注入（Successfully installed の直後に挿入）
anchor = '        print(f"Successfully installed {filename}")\n'
inject = '''        # VAMS-CUSTOM: stock train.py imports only isaaclab_tasks and this gymnasium build does
        # not auto-load gymnasium.envs plugins, so external custom-env tasks never register.
        # Inject an import of the custom env's gymnasium.envs entry-point module(s) right after
        # `import isaaclab_tasks` in the stock RL train scripts (i.e., after the sim app launches).
        try:
            import importlib.metadata as _md
            _mods = sorted({ep.value.split(":")[0] for ep in _md.entry_points(group="gymnasium.envs")
                            if ep.value and "isaaclab_tasks" not in ep.value})
            if _mods:
                _loader = "".join(f"import {_m}  # VAMS custom env autoload\\n" for _m in _mods)
                for _base in ("/workspace/isaaclab", os.getcwd()):
                    for _script in ("scripts/reinforcement_learning/rsl_rl/train.py",
                                    "scripts/reinforcement_learning/rl_games/train.py",
                                    "scripts/reinforcement_learning/skrl/train.py"):
                        _p = os.path.join(_base, _script)
                        if not os.path.isfile(_p):
                            continue
                        with open(_p) as _f:
                            _src = _f.read()
                        if "VAMS custom env autoload" in _src or "import isaaclab_tasks" not in _src:
                            continue
                        _i = _src.index("import isaaclab_tasks")
                        _eol = _src.index("\\n", _i) + 1
                        with open(_p, "w") as _f:
                            _f.write(_src[:_eol] + _loader + _src[_eol:])
                        print(f"[VAMS] injected custom-env task import into {_p}: {_mods}")
        except Exception as _e:
            print(f"[VAMS] WARN: failed to inject custom-env task import: {_e}")
'''
if "VAMS-CUSTOM:" in s:
    print("②: 既に適用済み")
elif anchor in s:
    s = s.replace(anchor, anchor + inject, 1)
    print("適用②: train.py への custom-env タスク import 注入を追加")
else:
    sys.exit("②: anchor 行が見つかりません（VAMS バージョン差の可能性）")

open(p, "w").write(s)
PY

echo "=== 構文チェック ==="
python3 -m py_compile "$F" && echo "OK"
