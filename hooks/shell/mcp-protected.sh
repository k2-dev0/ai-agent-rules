#!/bin/bash
# 配布したstdio MCPにも、対象repositoryのGit・保護設定への書き込み拒否を適用する。
set -eu
[ "$#" -gt 0 ] || exit 1
SCRIPT_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" && builtin pwd -P)
. "$SCRIPT_DIR/git-safe-env.sh"
exec python3 -I "$SCRIPT_DIR/protected-exec.py" -- "$@"
