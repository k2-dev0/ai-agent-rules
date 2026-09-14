#!/bin/bash
# 承認された境界外commandにもGit・保護設定のOS制限を残す。
set -eu
[ "$#" -eq 1 ] || { printf '%s\n' 'usage: outside.sh <shell command>' >&2; exit 1; }
SCRIPT_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" && builtin pwd -P)
. "$SCRIPT_DIR/git-safe-env.sh"
exec python3 -I "$SCRIPT_DIR/protected-exec.py" --shell "$1"
