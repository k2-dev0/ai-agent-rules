#!/bin/bash
# apply-e2e-plan: e2e skill で承認された計画を .[agent_name]/e2e/.e2e.md へ反映する。
# 保護された設定ディレクトリへの書き込みをこの固定宛先だけに限定し、任意パス上書きを防ぐ。
# 使い方: bash apply-e2e-plan.sh <draft.md>
set -u
SCRIPT_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" && builtin pwd -P) || exit 1
. "$SCRIPT_DIR/../../../.[agent_name]/hooks/shell/git-safe-env.sh" || exit 1

SRC="${1:?usage: apply-e2e-plan.sh <draft.md>}"
[ "$#" -eq 1 ] || { echo "ERROR: expected one draft argument" >&2; exit 1; }
DEST_DIR=".[agent_name]/e2e"
DEST="$DEST_DIR/.e2e.md"

[ -f "$SRC" ] || { echo "ERROR: draft not found: $SRC" >&2; exit 1; }
[ -L ".[agent_name]" ] && { echo "ERROR: agent dir is a symlink" >&2; exit 1; }
[ -L "$DEST_DIR" ] && { echo "ERROR: dest dir is a symlink: $DEST_DIR" >&2; exit 1; }
[ -L "$DEST" ] && { echo "ERROR: dest is a symlink: $DEST" >&2; exit 1; }

if python3 ".[agent_name]/hooks/shell/safe-files.py" "[agent_name]" plan "$SRC"; then
  echo "applied: $SRC -> $DEST"
else
  echo "ERROR: copy failed: $SRC -> $DEST" >&2
  exit 1
fi
