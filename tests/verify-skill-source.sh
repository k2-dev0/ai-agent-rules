#!/bin/bash
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/skill-source.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

check_result() {
  local expected=$1 input=$2 output
  output=$(printf '%s' "$input" | bash "$GUARD")
  if [ "$expected" = deny ]; then
    printf '%s' "$output" | jq -e '.hookSpecificOutput | .permissionDecision == "deny" and (.permissionDecisionReason | contains("報告して停止"))' >/dev/null
  else
    [ -z "$output" ]
  fi || { printf 'FAIL %s %s out=%s\n' "$AGENT" "$input" "$output"; exit 1; }
}
check_command() {
  check_result "$1" "$(jq -cn --arg cwd "$PWD" --arg cmd "$2" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}')"
}
check_tool() {
  check_result "$1" "$(jq -cn --arg cwd "$PWD" --arg tool "$2" --argjson args "$3" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:$tool,tool_input:$args}')"
}

for AGENT in claude codex; do
  mkdir -p "$TMP/$AGENT project/.$AGENT/hooks" "$TMP/$AGENT project/src"
  cp -R "$REPO/hooks/shell" "$TMP/$AGENT project/.$AGENT/hooks/"
  cd "$TMP/$AGENT project"
  sed "s/\[agent_name\]/$AGENT/g" "$REPO/hooks/shell/hook-io.sh" > ".$AGENT/hooks/shell/hook-io.sh"
  GUARD="$PWD/.$AGENT/hooks/shell/deny-skill-source.sh"
  if [ "$AGENT" = codex ]; then ROOT=.agents/skills; SETTINGS="$REPO/codex/hooks.json"; else ROOT=.claude/skills; SETTINGS="$REPO/claude/settings.json"; fi
  mkdir -p "$ROOT/example"
  SCRIPT="$ROOT/example/run task.sh"
  printf '#!/bin/bash\nprintf "executed\\n"\n' > "$SCRIPT"
  printf '# Readable documentation\n' > "$ROOT/example/SKILL.md"
  printf 'export const value = 1\n' > src/app.ts
  chmod +x "$SCRIPT"
  ln -s "$PWD/$SCRIPT" alias.sh
  for TOOL in Bash Read Grep exec_command functions.exec_command mcp__filesystem__read_file mcp__filesystem__read_multiple_files mcp__serena__search_for_pattern mcp__serena__find_symbol; do
    jq -e --arg tool "$TOOL" '[.hooks.PreToolUse[] | .matcher as $m | select($tool | test($m)) | .hooks[] | select(.command | contains("deny-skill-source.sh"))] | length == 1' "$SETTINGS" >/dev/null
  done
  for TOOL in Read mcp__filesystem__read_file; do
    check_tool deny "$TOOL" "$(jq -cn --arg path "$SCRIPT" '{file_path:$path,path:$path}')"
    check_tool deny "$TOOL" '{"path":"alias.sh"}'
    check_tool allow "$TOOL" "$(jq -cn --arg path "$ROOT/example/SKILL.md" '{file_path:$path,path:$path}')"
    check_tool allow "$TOOL" '{"path":"src/app.ts"}'
  done
  check_tool deny mcp__filesystem__read_multiple_files "$(jq -cn --arg path "$SCRIPT" '{paths:["src/app.ts",$path]}')"
  check_tool deny Grep "$(jq -cn --arg path "$ROOT" '{path:$path,pattern:".",output_mode:"content"}')"
  check_tool deny mcp__serena__search_for_pattern "$(jq -cn --arg path "$ROOT" '{relative_path:$path,substring_pattern:"."}')"
  check_tool allow Grep "$(jq -cn --arg path "$ROOT" '{path:$path,glob:"*.md",pattern:".",output_mode:"content"}')"
  check_tool deny Grep "$(jq -cn --arg path "$ROOT" '{path:$path,pattern:".",output_mode:"files_with_matches"}')"
  check_tool deny mcp__serena__find_symbol "$(jq -cn --arg path "$SCRIPT" '{relative_path:$path,include_body:true}')"
  check_tool deny mcp__serena__find_symbol "$(jq -cn --arg path "$SCRIPT" '{relative_path:$path,include_body:false}')"
  for READER in cat head tail nl bat less more strings; do check_command deny "$READER '$SCRIPT'"; done
  check_command deny "sed -n '1,20p' '$SCRIPT'"
  check_command deny "rg -n pattern '$SCRIPT'"
  check_command deny "cat $ROOT/example/*.sh"
  check_command deny "cat alias.sh"
  check_command deny "rg pattern '$ROOT'"
  check_command deny "grep -R pattern '$ROOT/example'"
  for FLAGS in -x -v -xv -ex --verbose '-o xtrace' -c; do check_command deny "bash $FLAGS '$SCRIPT'"; done
  check_command deny "env SHELLOPTS=xtrace bash '$SCRIPT'"
  check_command deny "bash -o errexit -x '$SCRIPT'"
  check_command deny "env SHELLOPTS=xtrace './$SCRIPT'"
  check_command allow "bash '$SCRIPT' --check"
  check_command allow "bash -eu '$SCRIPT'"
  check_command allow "'./$SCRIPT' -v"
  check_command allow "cat '$ROOT/example/SKILL.md'"
  check_command allow "cat src/app.ts"
  check_command allow "rg --files '$ROOT'"
  check_command allow "ls '$ROOT/example'"
  check_command allow "find '$ROOT' -type f -print"
  check_command allow "bash /tmp/other-script.sh"
  check_command allow "python3 /tmp/reader.py '$SCRIPT'"
  check_command allow "printf '%s' '$SCRIPT'"
  check_command allow "git add '$SCRIPT'"
  [ "$(bash "$SCRIPT")" = executed ]
  cd "$ROOT/example"
  check_command deny "cat 'run task.sh'"
  check_command deny "rg pattern"
  check_command allow "cat SKILL.md"
  check_command allow "rg '.' SKILL.md"
  check_tool deny Grep '{"pattern":".","output_mode":"content"}'
  printf '%s: skill source guard PASS\n' "$AGENT"
done
