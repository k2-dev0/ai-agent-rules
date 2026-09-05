#!/bin/bash
# 全体走査で判明した配布・書き込み・履歴・workerの回帰を外部通信なしで検証する。
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rules-regressions.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
REAL_GIT=$(command -v git)
export REAL_GIT

check() {
  if "$@"; then printf 'ok   %s\n' "$*"; else printf 'FAIL %s\n' "$*" >&2; exit 1; fi
}

# AGENTSを増やさず、必要時に読むskill配下の規約参照が両配置で解決する。
for agent in claude codex; do
  target="$TMP/$agent project"
  mkdir -p "$target/.$agent"
  cp "$REPO/AGENTS.md" "$target/AGENTS.md"
  cp -R "$REPO/rules" "$target/.$agent/rules"
  cp -R "$REPO/hooks" "$target/.$agent/hooks"
  if [ "$agent" = codex ]; then skill_root=.agents/skills; else skill_root=.claude/skills; fi
  mkdir -p "$target/$(dirname "$skill_root")"
  cp -R "$REPO/skills" "$target/$skill_root"
  (cd "$target" && bash "$skill_root/bootstrap/init-agent.sh" "$agent") >/dev/null
  rule_paths=$(sed -nE 's/.*`(typescript\/[^`]+\.md)`.*/\1/p' "$target/$skill_root/IMPLEMENTATION_RULES.md")
  check test "$(wc -l < "$target/AGENTS.md" | tr -d ' ')" = 2
  check test -n "$rule_paths"
  while IFS= read -r rule; do
    check test -s "$target/.$agent/rules/$rule"
  done <<< "$rule_paths"
  check test ! -e "$target/.$agent/hooks/shell/require-test.sh"
  for explicit_skill in bootstrap meeting tdd polish rebase e2e errand; do
    # bootstrapは初期化成功後に自己削除されるため、配布元で確認する。
    if [ "$explicit_skill" = bootstrap ]; then policy_root="$REPO/skills"; else policy_root="$target/$skill_root"; fi
    check grep -Fxq '  allow_implicit_invocation: false' "$policy_root/$explicit_skill/agents/openai.yaml"
  done
done

# 設定ファイルに登録したcommand自体を実行する。空白入りpathも含む。
cd "$TMP/claude project"
git init -q
git config user.name tester
git config user.email tester@example.com
export CLAUDE_PROJECT_DIR=$PWD
for tool in Edit Write NotebookEdit; do
  # matcherとtoolの照合を実際の登録値で行い、接続漏れを検出する。
  command=$(jq -r --arg tool "$tool" '.hooks.PreToolUse[] | .matcher as $matcher | select($tool | test("^(" + $matcher + ")$")) | .hooks[].command | select(contains("protect-config.sh"))' "$REPO/claude/settings.json")
  check test -n "$command"
  input=$(jq -cn --arg tool "$tool" --arg cwd "$PWD" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:$tool,tool_input:{file_path:".agents/skills/example/SKILL.md"}}')
  output=$(printf '%s' "$input" | bash -c "$command")
  check test "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny
done
command=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|NotebookEdit") | .hooks[].command | select(contains("protect-review.sh"))' "$REPO/claude/settings.json")
check test -n "$command"
input=$(jq -cn --arg cwd "$PWD" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Write",tool_input:{file_path:"new/package.json"}}')
output=$(printf '%s' "$input" | bash -c "$command")
check test "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = ask
input=$(jq -cn --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"REG1",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:"README.md"}}')
output=$(printf '%s' "$input" | bash .claude/hooks/shell/load-required-contract.sh cowlick-design)
check test -z "$output"
check jq -e '.permissions.deny | index("Edit(.claude/**)") | not' "$REPO/claude/settings.local.json"

# 必要時だけskillの判断基準を注入し、同じsessionでは繰り返さない。
input=$(jq -cn --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"RULE1",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:"src/example.ts"}}')
command=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|NotebookEdit") | .hooks[].command | select(contains("load-required-contract.sh"))' "$REPO/claude/settings.json")
output=$(printf '%s' "$input" | bash -c "$command")
check test "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny
check test -z "$(printf '%s' "$input" | bash -c "$command")"

# nicknameではなく専用roleを選ぶ。親がread-onlyなら編集を繰り返す前に拒否する。
for agent in claude codex; do
  cd "$TMP/$agent project"
  [ -d .git ] || git init -q
  export CLAUDE_PROJECT_DIR=$PWD
  if [ "$agent" = codex ]; then
    settings="$REPO/codex/hooks.json"
    mkdir -p .codex/tmp
    : > .codex/tmp/session.tdd.ROLE1
  else
    settings="$REPO/claude/settings.json"
  fi
  command=$(jq -r '.hooks.PreToolUse[].hooks[].command | select(contains("require-implementer.sh"))' "$settings")
  check test -n "$command"
  if [ "$agent" = claude ]; then command="$command workflow"; fi
  input=$(jq -cn --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"ROLE1",cwd:$cwd,tool_name:"spawn_agent",permission_mode:"default",tool_input:{task_name:"implementer",model:"gpt-5.6-luna",reasoning_effort:"max"}}')
  output=$(printf '%s' "$input" | bash -c "$command")
  check test "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny
  if [ "$agent" = claude ]; then role_key=subagent_type; else role_key=agent_type; fi
  input=$(printf '%s' "$input" | jq --arg key "$role_key" '.tool_input[$key]="worker"')
  output=$(printf '%s' "$input" | bash -c "$command")
  check test "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny
  input=$(printf '%s' "$input" | jq --arg key "$role_key" '.tool_input[$key]="implementer"')
  check test -z "$(printf '%s' "$input" | bash -c "$command")"
  input=$(printf '%s' "$input" | jq '.permission_mode="plan"')
  output=$(printf '%s' "$input" | bash -c "$command")
  check test "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny
  if [ "$agent" = codex ]; then
    printf '%s\n' '{"type":"turn_context","payload":{"sandbox_policy":{"type":"read-only"}}}' > "$TMP/parent.jsonl"
    input=$(printf '%s' "$input" | jq --arg path "$TMP/parent.jsonl" '.permission_mode="default" | .transcript_path=$path')
    output=$(printf '%s' "$input" | bash -c "$command")
    check test "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny
    printf '%s\n' '{"type":"turn_context","payload":{"sandbox_policy":{"type":"workspace-write"}}}' >> "$TMP/parent.jsonl"
    check test -z "$(printf '%s' "$input" | bash -c "$command")"
  fi
done
cd "$TMP/claude project"

# 固定宛先の親リンクから外部fileを変更できない。
mkdir -p "$TMP/external/prompt" "$TMP/external/e2e" "$TMP/links"
printf '%s\n' '- [ ] branch-example-prompt.md' > "$TMP/external/prompt/.prompt.md"
printf 'original\n' > "$TMP/external/e2e/.e2e.md"
printf 'replacement\n' > "$TMP/plan.md"
cd "$TMP/links"
ln -s "$TMP/external" .claude
if bash "$TMP/claude project/.claude/skills/e2e/apply-e2e-plan.sh" "$TMP/plan.md" >/dev/null 2>&1; then exit 1; fi
if bash "$TMP/claude project/.claude/skills/tdd/mark-prompt-done.sh" example >/dev/null 2>&1; then exit 1; fi
check test "$(cat "$TMP/external/e2e/.e2e.md")" = original
check test "$(cat "$TMP/external/prompt/.prompt.md")" = '- [ ] branch-example-prompt.md'
cd "$TMP/claude project"
ln -s "$TMP/external" linked
if bash .claude/skills/polish/quality-gate.sh example --direct-check -- linked/e2e/.e2e.md >/dev/null 2>&1; then exit 1; fi

# 検証中に加わったユーザー編集・stage済み変更をsquashが消さない。
mkdir -p "$TMP/bin"
cat > "$TMP/bin/git" <<'SH'
#!/bin/bash
if [ "$1" = diff ] && [ "${2:-}" = --quiet ] && [ "$#" = 4 ] && [ ! -e "$RACE_ROOT/injected" ]; then
  : > "$RACE_ROOT/injected"
  if [ "$RACE_MODE" = edit ]; then
    printf 'user worktree\n' >> "$RACE_ROOT/one.ts"
    printf 'user staged\n' >> "$RACE_ROOT/two.ts"
    "$REAL_GIT" -C "$RACE_ROOT" add two.ts
  else
    "$REAL_GIT" -C "$RACE_ROOT" commit --allow-empty -qm 'concurrent: user commit'
    "$REAL_GIT" -C "$RACE_ROOT" rev-parse HEAD > "$RACE_ROOT/concurrent-head"
  fi
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$TMP/bin/git"
for mode in edit commit; do
  mkdir -p "$TMP/race-$mode/.claude"
  cp -R "$TMP/claude project/.claude/hooks" "$TMP/race-$mode/.claude/hooks"
  cd "$TMP/race-$mode"
  git init -q
  git config user.name tester
  git config user.email tester@example.com
  git commit --allow-empty -qm base
  base=$(git rev-parse HEAD)
  printf 'one\n' > one.ts
  git add one.ts
  git commit -qm 'one.ts: 追加'
  first=$(git rev-parse HEAD)
  printf 'two\n' > two.ts
  git add two.ts
  git commit -qm 'two.ts: 追加'
  last=$(git rev-parse HEAD)
  status=0
  PATH="$TMP/bin:$PATH" RACE_ROOT="$PWD" RACE_MODE="$mode" bash "$TMP/claude project/.claude/skills/rebase/rebase.sh" --base "$base" --group 'feature: 統合' "$first,$last" > result.log 2>&1 || status=$?
  check test -e injected
  if [ "$mode" = edit ]; then
    check test "$status" = 0
    check grep -Fxq 'user worktree' one.ts
    check grep -Fxq 'user staged' two.ts
    check test "$(git show :two.ts)" = "$(cat two.ts)"
    check test "$(git rev-list --count "$base..HEAD")" = 1
  else
    check test "$status" != 0
    check test "$(git rev-parse HEAD)" = "$(cat concurrent-head)"
  fi
done

# 実際のmonitor関数を短い時間幅で実行する。正常eventの後のごみはidleを延長しない。
awk '/^process_group_alive\(\)/,/^stop_running_children\(\)/ { if ($0 !~ /^stop_running_children\(\)/) print }
     /^count_valid_events\(\)/,/^run_opencode\(\)/ { if ($0 !~ /^run_opencode\(\)/) print }' "$REPO/skills/worker/delegate.sh" > "$TMP/monitor.sh"
(
  . "$TMP/monitor.sh"
  TIMEOUT_TERM_GRACE_SECONDS=1
  TIMEOUT_POLL_SECONDS=1
  HARD_TIMEOUT_SECONDS=6
  IDLE_TIMEOUT_SECONDS=2
  TIMEOUT_MARKER="$TMP/timeout.kind"
  printf '{"type":"text","text":"start"}\n' > "$TMP/events.jsonl"
  set -m
  (while true; do printf 'not-json\n'; sleep 0.2; done) >> "$TMP/events.jsonl" &
  writer=$!
  set +m
  trap 'terminate_process_group "$writer"; wait "$writer" 2>/dev/null || true' EXIT
  monitor_opencode "$writer" "$TMP/events.jsonl" "$(date +%s)"
  check test "$(cat "$TIMEOUT_MARKER")" = idle
)
printf 'regressions: all passed\n'
