#!/bin/bash
# キーは標準出力・引数・設定fileへ出さず、保護付きbridge processだけへ渡す。
set +x
set -eu
[ "$#" -gt 0 ] || { printf '%s\n' 'DeepSeek bridge command is required.' >&2; exit 1; }
SCRIPT_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" && builtin pwd -P)
if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
  command -v zsh >/dev/null || { printf '%s\n' 'DEEPSEEK_API_KEY is not configured.' >&2; exit 1; }
  # Never start an interactive shell under the CLI: its terminal job control
  # can stop a background MCP process. Keep rc reads away from MCP stdin too.
  exec zsh -fc '
    source "${ZDOTDIR:-$HOME}/.zshrc" </dev/null >/dev/null 2>&1 || true
    unsetopt xtrace
    if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
      print -u2 "DEEPSEEK_API_KEY is not configured in the environment or .zshrc."
      exit 1
    fi
    export DEEPSEEK_API_KEY
    exec bash "$@"
  ' deepseek-launch "$SCRIPT_DIR/mcp-protected.sh" "$@"
fi
export DEEPSEEK_API_KEY
exec bash "$SCRIPT_DIR/mcp-protected.sh" "$@"
