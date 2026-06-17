#!/usr/bin/env bash
# SO-ARM101 Reach-Grasp のカスタム環境 tar.gz を生成する（フェーズ2）。
# 方針: ベース isaac_so_arm101（インストール可能パッケージ）に fork の差分3ファイルを
#       上書きし、1つの tar.gz にまとめる。fork 単体では gym 登録に必要な実装が無く動かない。
#
# 出力: dist/so-arm101-reach-grasp-env.tar.gz
# 登録タスク: Isaac-SO-ARM101-Reach-Grasp-v0 / -Grasp-Play-v0
set -euo pipefail

WORKDIR="${WORKDIR:-$HOME/work/vams}"
BASE_REF="${BASE_REF:-main}"
FORK_REF="${FORK_REF:-main}"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)/dist"
mkdir -p "$OUT_DIR" "$WORKDIR"
cd "$WORKDIR"

# 1) ベース & fork を取得
[ -d isaac_so_arm101 ] || git clone --depth 1 --branch "$BASE_REF" \
  https://github.com/MuammerBay/isaac_so_arm101.git
[ -d reach-grasp ] || git clone --depth 1 --branch "$FORK_REF" \
  https://github.com/furuya02/isaac-lab-so-arm101-reach-grasp.git reach-grasp

# 2) fork の差分3ファイルをベースへ上書き
cp reach-grasp/src/isaac_so_arm101/tasks/reach/__init__.py \
   reach-grasp/src/isaac_so_arm101/tasks/reach/joint_pos_env_cfg.py \
   reach-grasp/src/isaac_so_arm101/tasks/reach/reach_env_cfg.py \
   isaac_so_arm101/src/isaac_so_arm101/tasks/reach/

# 3) gymnasium エントリポイントを追加（★最重要）
#    VAMS は Isaac Lab の stock train.py を使うため `import isaac_so_arm101.tasks` が走らず、
#    そのままではカスタムタスクが gym に登録されない。gymnasium のプラグイン機構
#    (entry-points group "gymnasium.envs" の __root__) を使うと、`import gymnasium` 時に
#    指定モジュールが import され、タスク登録(gym.register)が自動で走る。
PYPROJECT="isaac_so_arm101/pyproject.toml"
if ! grep -q 'gymnasium.envs' "$PYPROJECT"; then
  cat >> "$PYPROJECT" <<'EOF'

[project.entry-points."gymnasium.envs"]
__root__ = "isaac_so_arm101.tasks"
EOF
  echo "pyproject に gymnasium エントリポイントを追加"
fi
# 注: 依存(isaaclab[all,isaacsim]==2.3.0 / torch) はコンテナに同梱済み。
#     コンテナ側 install を --no-deps にして再取得を防ぐ（patch-vams-container.sh 参照）。

# 4) tar.gz 化（キャッシュ除外）
tar -czf "$OUT_DIR/so-arm101-reach-grasp-env.tar.gz" \
  --exclude='__pycache__' --exclude='*.pyc' --exclude='.git' \
  -C isaac_so_arm101 .

echo "生成: $OUT_DIR/so-arm101-reach-grasp-env.tar.gz"
echo "次: VAMS のアセットへアップロード → 学習 config の task に Isaac-SO-ARM101-Reach-Grasp-v0 を指定"
