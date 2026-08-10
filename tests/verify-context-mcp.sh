#!/bin/bash
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/context-mcp-template.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
FAIL=0

ok() { echo "ok   $1"; }
ng() { echo "FAIL $1"; FAIL=1; }

CLAUDE_MCP="$REPO/claude/.mcp.json"
CLAUDE_PERMISSIONS="$REPO/claude/settings.local.json"
CODEX_MCP="$REPO/codex/config.toml"
CONTEXT_SKILL="$REPO/skills/dictionary/SKILL.md"
PLACEHOLDER="__CONTEXT_DICTIONARY_ROOT__"
FIXTURE_ROOT="/opt/context dictionary"

jq -e '
  .mcpServers["context-dictionary"].type == "stdio" and
  .mcpServers["context-dictionary"].command == "__CONTEXT_DICTIONARY_ROOT__/node_modules/.bin/tsx" and
  .mcpServers["context-dictionary"].args == ["__CONTEXT_DICTIONARY_ROOT__/src/mcp/stdio.ts"]
' "$CLAUDE_MCP" >/dev/null 2>&1 && ok "Claude MCP template" || ng "Claude MCP template"

jq -e '
  (.permissions.allow | index("mcp__context-dictionary__search")) and
  (.permissions.allow | index("mcp__context-dictionary__get")) and
  (.permissions.ask | index("mcp__context-dictionary__upsert")) and
  (.permissions.ask | index("mcp__context-dictionary__follow_up")) and
  (.permissions.allow | index("mcp__context-dictionary__upsert") | not) and
  (.permissions.allow | index("mcp__context-dictionary__follow_up") | not) and
  (.enabledMcpjsonServers | index("context-dictionary"))
' "$CLAUDE_PERMISSIONS" >/dev/null 2>&1 && ok "Claude read/write approval boundary" || ng "Claude read/write approval boundary"

if awk '
  $0 == "[mcp_servers.context-dictionary]" { server=1; next }
  server && /^\[/ { exit !(prompt && command && agent) }
  server && $0 == "default_tools_approval_mode = \"prompt\"" { prompt=1 }
  server && $0 == "command = \"__CONTEXT_DICTIONARY_ROOT__/node_modules/.bin/tsx\"" { command=1 }
  server && $0 == "env = { CONTEXT_AGENT = \"codex\" }" { agent=1 }
  END { if (server) exit !(prompt && command && agent) }
' "$CODEX_MCP" &&
   grep -A1 '^\[mcp_servers.context-dictionary.tools.search\]$' "$CODEX_MCP" | grep -q 'approval_mode = "approve"' &&
   grep -A1 '^\[mcp_servers.context-dictionary.tools.get\]$' "$CODEX_MCP" | grep -q 'approval_mode = "approve"' &&
   ! grep -q '^\[mcp_servers.context-dictionary.tools.\(upsert\|follow_up\)\]$' "$CODEX_MCP"; then
  ok "Codex read/write approval boundary"
else
  ng "Codex read/write approval boundary"
fi

if grep -Fq "$PLACEHOLDER" "$CLAUDE_MCP" && grep -Fq "$PLACEHOLDER" "$CODEX_MCP" &&
   ! grep -Fq '/Users/kaikojima' "$CLAUDE_MCP" "$CODEX_MCP"; then
  ok "template has placeholder and no personal absolute path"
else
  ng "template path boundary"
fi

sed "s|$PLACEHOLDER|$FIXTURE_ROOT|g" "$CLAUDE_MCP" > "$TMP/.mcp.json"
sed "s|$PLACEHOLDER|$FIXTURE_ROOT|g" "$CODEX_MCP" > "$TMP/config.toml"
mkdir -p "$TMP/codex-home"
cp "$TMP/config.toml" "$TMP/codex-home/config.toml"
if ! grep -Rq "$PLACEHOLDER" "$TMP" && jq -e . "$TMP/.mcp.json" >/dev/null 2>&1 &&
   CODEX_HOME="$TMP/codex-home" codex mcp list >/dev/null 2>&1; then
  ok "setup-agent path injection keeps JSON/TOML valid"
else
  ng "setup-agent path injection"
fi

if [ -f "$CONTEXT_SKILL" ] &&
   [ ! -d "$REPO/skills/context-api" ] && [ ! -d "$REPO/skills/context-search" ] &&
   [ ! -d "$REPO/skills/context-save" ] && [ ! -d "$REPO/skills/context-update" ] &&
   grep -Fq '`search`' "$CONTEXT_SKILL" && grep -Fq '`get`' "$CONTEXT_SKILL" &&
   grep -Fq '`upsert`' "$CONTEXT_SKILL" && grep -Fq '`follow_up`' "$CONTEXT_SKILL" &&
   grep -Fq '承認なしに書き込まない' "$CONTEXT_SKILL" &&
   ! grep -Eq 'localhost|/api/|HTTP|JSON' "$CONTEXT_SKILL"; then
  ok "context skill contains policy without wire protocol"
else
  ng "context skill migration"
fi

exit "$FAIL"
