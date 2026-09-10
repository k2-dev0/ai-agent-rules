#!/bin/bash
# 全体走査で判明した配布・書き込み・履歴・専用agentの回帰を外部通信なしで検証する。
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rules-regressions.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
REAL_GIT=$(command -v git)
export REAL_GIT

check() {
  if "$@"; then printf 'ok   %s\n' "$*"; else printf 'FAIL %s\n' "$*" >&2; exit 1; fi
}

# 常時使うモデル選択基準と、変更時だけ読む切り替え手順を両配置で解決する。
for agent in claude codex; do
  target="$TMP/$agent project"
  mkdir -p "$target/.$agent"
  cp "$REPO/AGENTS.md" "$target/AGENTS.md"
  cp -R "$REPO/rules" "$target/.$agent/rules"
  cp -R "$REPO/hooks" "$target/.$agent/hooks"
  cp -R "$REPO/$agent/agents" "$target/.$agent/agents"
  if [ "$agent" = codex ]; then skill_root=.agents/skills; else skill_root=.claude/skills; fi
  mkdir -p "$target/$(dirname "$skill_root")"
  cp -R "$REPO/skills" "$target/$skill_root"
  (cd "$target" && bash "$skill_root/bootstrap/bootstrap.sh" "$agent") >/dev/null
  rule_paths=$(sed -nE 's/.*`(typescript\/[^`]+\.md)`.*/\1/p' "$target/$skill_root/IMPLEMENTATION_RULES.md")
  check grep -Fq "$skill_root/MODEL_SWITCH.md" "$target/AGENTS.md"
  check test -s "$target/$skill_root/MODEL_SWITCH.md"
  check test ! -e "$target/$skill_root/MODEL_SELECTION.md"
  check grep -Fq '現在モデルで調査・実装方針の決定まで行い' "$target/AGENTS.md"
  check grep -Fq '現在値と異なる場合だけ' "$target/AGENTS.md"
  check grep -Fq '文脈圧縮、会話の長さ、以前の読了記憶は読込条件にしない' "$target/AGENTS.md"
  check grep -Fq '同じ方針の修正・再開では再利用' "$target/AGENTS.md"
  check test -s "$target/$skill_root/DIFFICULTY_CONTRACT.md"
  check grep -Fq '成功時は1〜10の整数だけ' "$target/$skill_root/DIFFICULTY_CONTRACT.md"
  if grep -Eq 'Luna|Sol|Astra|gpt-|effort|モデル|"model"|"evidence"' "$target/$skill_root/DIFFICULTY_CONTRACT.md"; then
    echo "FAIL 採点契約にモデル情報または根拠の返却が残存: $agent"
    exit 1
  fi
  check grep -Fq '主担当が1〜3をLuna / max、4〜7をSol / high、8〜10をAstra / highへ対応' "$target/AGENTS.md"
  check grep -Fq 'テストを含む最初の編集前' "$target/AGENTS.md"
  check grep -Fq '`critical`・`high`指摘が1件でもあれば' "$target/AGENTS.md"
  check grep -Fq '次の応答では`switch_model`だけを呼び' "$target/$skill_root/MODEL_SWITCH.md"
  check grep -Fq '`baton`による中断' "$target/$skill_root/MODEL_SWITCH.md"
  check grep -Fq '切替要求の記録、受付結果`pending`、空のツール返答、要求内容の再掲だけでは適用成功とみなさない' "$target/$skill_root/MODEL_SWITCH.md"
  check grep -Fq 'status: "applied"' "$target/$skill_root/MODEL_SWITCH.md"
  check grep -Fq '実際のモデル・effortが選定値に一致することを確認してから' "$target/$skill_root/MODEL_SWITCH.md"
  check grep -Fq '一つでも確認できない場合は編集を開始せず' "$target/$skill_root/MODEL_SWITCH.md"
  check grep -Fq '設定だけ変更済みの場合がある' "$target/$skill_root/MODEL_SWITCH.md"
  check grep -Fq '現在のモデルで続行する' "$target/$skill_root/MODEL_SWITCH.md"
  check grep -Fq 'その判断に依存する変更を止め' "$target/$skill_root/MODEL_SWITCH.md"
  check test ! -e "$target/$skill_root/REVIEW_FLOW.md"
  check test -f "$target/$skill_root/FIX_FLOW.md"
  check grep -Fq '`switch_model`だけを1回呼び直す' "$target/$skill_root/MODEL_SWITCH.md"
  check grep -Fq '切り替え前に後続作業を続けない' "$target/$skill_root/MODEL_SWITCH.md"
  check test -n "$rule_paths"
  while IFS= read -r rule; do
    check test -s "$target/.$agent/rules/$rule"
  done <<< "$rule_paths"
  check test ! -e "$target/.$agent/hooks/shell/require-test.sh"
  for explicit_skill in bootstrap meeting tdd polish rebase e2e; do
    # bootstrapは初期化成功後に自己削除されるため、配布元で確認する。
    if [ "$explicit_skill" = bootstrap ]; then policy_root="$REPO/skills"; else policy_root="$target/$skill_root"; fi
    check grep -Fxq '  allow_implicit_invocation: false' "$policy_root/$explicit_skill/agents/openai.yaml"
  done
  check grep -Fxq '  allow_implicit_invocation: true' "$target/$skill_root/errand/agents/openai.yaml"
  if grep -q '^disable-model-invocation: true$' "$target/$skill_root/errand/SKILL.md"; then
    echo "FAIL errandの自動選択が無効: $agent"
    exit 1
  fi
done

# 実際のBash登録hookをすべて通す。別hookのallowで内容変更のdenyが消えないことも検査する。
shell_decision() {
  local expected=$1 candidate=$2 input output command decision=pass
  input=$(jq -cn --arg cwd "$PWD" --arg command "$candidate" '{hook_event_name:"PreToolUse",session_id:"FILE1",cwd:$cwd,tool_name:"Bash",tool_input:{command:$command}}')
  while IFS= read -r command; do
    output=$(printf '%s' "$input" | bash -c "$command")
    if [ -n "$output" ] && [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ]; then decision=deny; fi
  done < <(jq -r '.hooks.PreToolUse[] | .matcher as $matcher | select("Bash" | test($matcher)) | .hooks[].command' "$settings")
  [ "$decision" = "$expected" ]
}
for agent in claude codex; do
  cd "$TMP/$agent project"
  git init -q
  export CLAUDE_PROJECT_DIR=$PWD
  if [ "$agent" = codex ]; then settings="$REPO/codex/hooks.json"; else settings="$REPO/claude/settings.json"; fi
  check test "$(jq '[.hooks.PreToolUse[] | .matcher as $matcher | select("Bash" | test($matcher)) | .hooks[].command | select(contains("shell-file-write.sh"))] | length' "$settings")" = 1
  printf 'source\n' > source.txt
  printf 'original\n' > existing.txt
  ln -s existing.txt linked.txt
  for candidate in 'touch new.txt' 'touch existing.txt' 'chmod +x existing.txt' 'chown 1000 existing.txt' 'chgrp 1000 existing.txt' 'cp -n -- source.txt copied.txt' 'cp -n -- source.txt existing.txt' 'cp -n -- source.txt linked.txt' 'ln -s -- source.txt new-link.txt' "sed -n '1,20p' source.txt" "rg 'a > b' source.txt" 'cat source.txt >/dev/null'; do
    check shell_decision pass "$candidate"
  done
  for candidate in 'cp source.txt existing.txt' 'cp -n -f source.txt existing.txt' 'mv source.txt existing.txt' 'ln -sf source.txt existing.txt' 'install source.txt existing.txt' 'rsync source.txt existing.txt' 'sed -i s/a/b/ existing.txt' 'sed -ni s/a/b/ existing.txt' "sed 'w existing.txt' source.txt" 'tee existing.txt' 'dd of=existing.txt' 'truncate -s 0 existing.txt' 'patch existing.txt change.diff' 'printf changed > existing.txt' 'printf changed >> existing.txt' 'printf changed >| existing.txt' 'chmod +x source.txt > existing.txt' 'touch source.txt > existing.txt' 'printf changed > new.txt' 'command /bin/cp source.txt existing.txt' "'/bin/cp' 'source.txt' 'existing.txt'" 'env MODE=test cp source.txt existing.txt' 'MODE=test cp source.txt existing.txt' 'cp -n -- source.txt .codex/config.toml'; do
    check shell_decision deny "$candidate"
  done
  # 許可されたcommandを実行して、既存fileとリンク先が変わらないことを確認する。
  for candidate in 'env MODE=test command -- /bin/cp source.txt existing.txt' "bash -c 'cp source.txt existing.txt'" "eval 'cp source.txt existing.txt'" 'gsed -i s/a/b/ existing.txt' "awk 'BEGIN { print 1 > \"existing.txt\" }'" "sed -n '1,20p' -e 'w existing.txt' source.txt"; do
    check shell_decision deny "$candidate"
  done
  check shell_decision pass 'env MODE=test command -- cp -n -- source.txt copied.txt'
  touch new.txt existing.txt
  chmod +x existing.txt
  cp -n -- source.txt copied.txt
  # macOS cp -nは既存の宛先をskipすると1を返す。内容が変わらないことを下で検証する。
  cp -n -- source.txt existing.txt || test "$?" = 1
  cp -n -- source.txt linked.txt || test "$?" = 1
  check test -f new.txt
  check test -x existing.txt
  check cmp source.txt copied.txt
  check test "$(cat existing.txt)" = original
  check test -L linked.txt
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

# 専用roleの設定は検査し、通常のagent選択・直接編集へは介入しない。
implementer_denied() {
  local output
  output=$(printf '%s' "$1" | bash -c "$command")
  printf '%s' "$output" | jq -e --arg reason "$2" '.hookSpecificOutput | .permissionDecision == "deny" and (.permissionDecisionReason | contains($reason))' >/dev/null
}
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

# ネスト検出役は実装workflow内でも新規起動できるが、権限・設定の上書きは拒否する。
for agent in claude codex; do
  cd "$TMP/$agent project"
  if [ "$agent" = codex ]; then
    role_key=agent_type
    definition=.codex/agents/nesting-reviewer.toml
    contract=.agents/skills/unwind/NESTING_CONTRACT.md
    boundary='sandbox_mode = "read-only"'
  else
    role_key=subagent_type
    definition=.claude/agents/nesting-reviewer.md
    contract=.claude/skills/unwind/NESTING_CONTRACT.md
    boundary='tools: Read, Grep, Glob'
  fi
  command="bash .$agent/hooks/shell/require-implementer.sh workflow"
  input=$(jq -cn --arg cwd "$PWD" --arg role "$role_key" '{cwd:$cwd,tool_input:{($role):"nesting-reviewer",fork_turns:"none"}}')
  check grep -Fq "$contract" "$definition"
  check grep -Fxq "$boundary" "$definition"
  check test -s "$contract"
  check test -z "$(printf '%s' "$input" | bash -c "$command")"
  for mutation in '.model="other"' '.effort="high"'; do
    invalid=$(printf '%s' "$input" | jq ".tool_input |= ($mutation)")
    check implementer_denied "$invalid" '専用定義で新規起動'
  done
  if [ "$agent" = codex ]; then
    invalid=$(printf '%s' "$input" | jq '.tool_input.fork_turns="all"')
    check implementer_denied "$invalid" '専用定義で新規起動'
  fi
  cp "$definition" "$definition.original"
  if [ "$agent" = codex ]; then
    sed 's/sandbox_mode = "read-only"/sandbox_mode = "workspace-write"/' "$definition.original" > "$definition"
  else
    sed 's/tools: Read, Grep, Glob/tools: Read, Grep, Glob, Bash/' "$definition.original" > "$definition"
  fi
  check implementer_denied "$input" '配布設定と一致しません'
  mv "$definition.original" "$definition"
  mv "$contract" "$contract.missing"
  check implementer_denied "$input" '検出契約が無い'
  mv "$contract.missing" "$contract"
  mv "$definition" "$definition.missing"
  check implementer_denied "$input" '定義が無い'
  mv "$definition.missing" "$definition"
done
# 独立レビュー役は上位モデル・読み取り専用・会話継承なしを固定する。
for agent in claude codex; do
  cd "$TMP/$agent project"
  export CLAUDE_PROJECT_DIR=$PWD
  command="bash .$agent/hooks/shell/require-implementer.sh"
  if [ "$agent" = codex ]; then
    roles='code-reviewer deep-reviewer design-reviewer difficulty-evaluator'
    role_key=agent_type
    extension=toml
    contract=.agents/skills/CODE_REVIEW_CONTRACT.md
  else
    roles='code-reviewer design-reviewer difficulty-evaluator'
    role_key=subagent_type
    extension=md
    contract=.claude/skills/CODE_REVIEW_CONTRACT.md
  fi
  for role in $roles; do
    if [ "$agent" = codex ]; then contract=.agents/skills/CODE_REVIEW_CONTRACT.md; else contract=.claude/skills/CODE_REVIEW_CONTRACT.md; fi
    if [ "$role" = design-reviewer ]; then
      if [ "$agent" = codex ]; then contract=.agents/skills/ponytail/REVIEW_CONTRACT.md; else contract=.claude/skills/ponytail/REVIEW_CONTRACT.md; fi
    fi
    effort=high
    if [ "$role" = difficulty-evaluator ]; then
      effort=medium
      if [ "$agent" = codex ]; then contract=.agents/skills/DIFFICULTY_CONTRACT.md; else contract=.claude/skills/DIFFICULTY_CONTRACT.md; fi
    fi
    definition=".$agent/agents/$role.$extension"
    input=$(jq -cn --arg cwd "$PWD" --arg key "$role_key" --arg role "$role" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Agent",tool_input:{($key):$role,fork_turns:"none"}}')
    if [ "$role" = difficulty-evaluator ]; then
      input=$(printf '%s' "$input" | jq --arg root "$(git rev-parse --show-toplevel)" '.tool_input.prompt = ({repository:$root,implementation_policy:"Add a single pure value conversion and its test."} | tojson)')
    fi
    check test -z "$(printf '%s' "$input" | bash -c "$command")"
    for mutation in '.model="gpt-5.6-luna"' '.effort="low"' '.fork_turns="all"' '.fork_context=true'; do
      invalid=$(printf '%s' "$input" | jq ".tool_input |= ($mutation)")
      check implementer_denied "$invalid" '専用定義で新規起動'
    done
    if [ "$agent" = codex ]; then
      invalid=$(printf '%s' "$input" | jq 'del(.tool_input.fork_turns)')
      check implementer_denied "$invalid" '専用定義で新規起動'
    fi
    cp "$definition" "$definition.original"
    if [ "$agent" = codex ]; then
      sed 's/sandbox_mode = "read-only"/sandbox_mode = "workspace-write"/' "$definition.original" > "$definition"
    else
      sed 's/tools: Read, Grep, Glob, Bash/tools: Read, Grep, Glob, Bash, Edit/' "$definition.original" > "$definition"
    fi
    check implementer_denied "$input" '配布設定と一致しません'
    if [ "$agent" = codex ]; then
      sed "s/model_reasoning_effort = \"$effort\"/model_reasoning_effort = \"low\"/" "$definition.original" > "$definition"
    else
      sed "s/effort: $effort/effort: low/" "$definition.original" > "$definition"
    fi
    check implementer_denied "$input" '配布設定と一致しません'
    sed 's/^model[: =].*/model: wrong-model/' "$definition.original" > "$definition"
    check implementer_denied "$input" '配布設定と一致しません'
    mv "$definition.original" "$definition"
    mv "$contract" "$contract.missing"
    check implementer_denied "$input" '契約が無い'
    mv "$contract.missing" "$contract"
    mv "$definition" "$definition.missing"
    check implementer_denied "$input" '定義が無い'
    mv "$definition.missing" "$definition"
    if [ "$role" = difficulty-evaluator ]; then
      for mutation in 'del(.tool_input.prompt)' '.tool_input.prompt="plain text"' '.tool_input.prompt |= (fromjson | .background="history" | tojson)' '.tool_input.prompt |= (fromjson | .repository="/wrong" | tojson)' '.tool_input.prompt |= (fromjson | .implementation_policy="  " | tojson)' '.tool_input.prompt |= (fromjson | .implementation_policy=[] | tojson)'; do
        invalid=$(printf '%s' "$input" | jq "$mutation")
        check implementer_denied "$invalid" '難易度調査は'
      done
      message_input=$(printf '%s' "$input" | jq '.tool_input.message=.tool_input.prompt | del(.tool_input.prompt)')
      check test -z "$(printf '%s' "$message_input" | bash -c "$command")"
      if [ "$agent" = codex ]; then
        cp "$definition" "$definition.original"
        sed 's/enabled = false/enabled = true/' "$definition.original" > "$definition"
        check implementer_denied "$input" '再委任は禁止'
        mv "$definition.original" "$definition"
      fi
    fi
  done
done

# 専用role以外を拒否する。namespace付き起動もhookへ到達する。
cd "$TMP/codex project"
command='bash .codex/hooks/shell/require-implementer.sh'
for tool_name in spawn_agent collaboration.spawn_agent functions.spawn_agent collaborationspawn_agent; do
  matched=$(jq -r --arg name "$tool_name" '.hooks.PreToolUse[] | .matcher as $m | select($name | test($m)) | .hooks[].command | select(contains("require-implementer.sh"))' "$REPO/codex/hooks.json")
  check test -n "$matched"
  input=$(jq -cn --arg cwd "$PWD" --arg tool "$tool_name" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:$tool,tool_input:{agent_type:"default",fork_turns:"none"}}')
  check implementer_denied "$input" '専用roleだけ'
done
for role in nesting-reviewer; do
  input=$(jq -cn --arg cwd "$PWD" --arg role "$role" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"spawn_agent",tool_input:{agent_type:$role,fork_turns:"none"}}')
  check test -z "$(printf '%s' "$input" | bash -c "$command")"
  for field in model reasoning_effort effort config model_provider; do
    invalid=$(printf '%s' "$input" | jq --arg field "$field" '.tool_input[$field]="override"')
    output=$(printf '%s' "$invalid" | bash -c "$command")
    check test "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny
  done
  check grep -Fxq 'enabled = false' ".codex/agents/$role.toml"
done

# 専用agent未配置でもメインの読み取り・編集・モデル切替は妨げない。
# 旧workflow登録とmarkerが残る更新途中の環境でも同じ結果になる。
for agent in claude codex; do
  cd "$TMP/$agent project"
  export CLAUDE_PROJECT_DIR=$PWD
  command="bash .$agent/hooks/shell/require-implementer.sh workflow"
  mv ".$agent/agents" ".$agent/agents.disabled"
  mkdir -p ".$agent/tmp"
  for skill in tdd errand; do
    : > ".$agent/tmp/session.$skill.DIRECT1"
  done
  for tool_name in Read Edit apply_patch switch_model; do
    input=$(jq -cn --arg cwd "$PWD" --arg tool "$tool_name" '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"DIRECT1",tool_name:$tool,tool_input:{}}')
    check test -z "$(printf '%s' "$input" | bash -c "$command")"
  done
  if [ "$agent" = codex ]; then role_key=agent_type; else role_key=subagent_type; fi
  input=$(jq -cn --arg cwd "$PWD" --arg role "$role_key" '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"DIRECT1",tool_name:"Agent",tool_input:{($role):"explorer",fork_turns:"none"}}')
  check implementer_denied "$input" '専用roleだけ'
  input=$(printf '%s' "$input" | jq --arg role "$role_key" '.tool_input[$role]="implementer"')
  check implementer_denied "$input" '実装委任は禁止'
  mv ".$agent/agents.disabled" ".$agent/agents"
done
cd "$TMP/codex project"

# 両環境でbackground・resume・一括起動を拒否する。
for agent in claude codex; do
  cd "$TMP/$agent project"
  export CLAUDE_PROJECT_DIR=$PWD
  command="bash .$agent/hooks/shell/require-implementer.sh"
  for tool_name in Agent spawn_agent collaboration.spawn_agent; do
    input=$(jq -cn --arg cwd "$PWD" --arg tool "$tool_name" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:$tool,tool_input:{}}')
    check implementer_denied "$input" '専用roleだけ'
    for mutation in '.run_in_background=true' '.background=true' '.resume="child-1"'; do
      invalid=$(printf '%s' "$input" | jq ".tool_input |= ($mutation)")
      check implementer_denied "$invalid" '並列実行は禁止'
    done
  done
  for tool_name in resume_agent collaboration.resume_agent spawn_agents_on_csv; do
    input=$(jq -cn --arg tool "$tool_name" '{hook_event_name:"PreToolUse",tool_name:$tool,tool_input:{}}')
    check implementer_denied "$input" '並列実行は禁止'
  done
done
cd "$TMP/codex project"

# 待機時間だけを書き換え、待機先・cursor等は保つ。補正でモデルの再試行を発生させない。
for tool_name in wait collaboration.wait collaborationwait wait_agent collaboration.wait_agent collaborationwait_agent; do
  matched=$(jq -r --arg name "$tool_name" '.hooks.PreToolUse[] | .matcher as $m | select($name | test($m)) | .hooks[].command | select(contains("agent-wait.sh"))' "$REPO/codex/hooks.json")
  check test -n "$matched"
  for duration in null 10000 30000; do
    input=$(jq -cn --arg cwd "$PWD" --arg tool "$tool_name" --argjson duration "$duration" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:$tool,tool_input:{ids:["child-1"],cursor:"next"}} | if $duration == null then . else .tool_input.timeout_ms=$duration end')
    output=$(printf '%s' "$input" | bash .codex/hooks/shell/agent-wait.sh)
    check test "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = allow
    expected=$(printf '%s' "$input" | jq -cS '.tool_input + {timeout_ms:60000}')
    actual=$(printf '%s' "$output" | jq -cS '.hookSpecificOutput.updatedInput')
    check test "$actual" = "$expected"
  done
  for duration in 0 60000 120000 -1 '"invalid"'; do
    input=$(jq -cn --arg cwd "$PWD" --arg tool "$tool_name" --argjson duration "$duration" '{cwd:$cwd,tool_name:$tool,tool_input:{ids:["child-1"],timeout_ms:$duration}}')
    check test -z "$(printf '%s' "$input" | bash .codex/hooks/shell/agent-wait.sh)"
  done
done
input='{"tool_name":"wait","tool_input":{"cell_id":"exec-cell","yield_time_ms":1000}}'
check test -z "$(printf '%s' "$input" | bash .codex/hooks/shell/agent-wait.sh)"
check test -z "$(printf '%s' '{"tool_name":"wait_agent","tool_input":{"timeout_ms":10000}}' | bash "$TMP/claude project/.claude/hooks/shell/agent-wait.sh")"
check test ! -e "$REPO/skills/worker/delegate.sh"
if rg -i 'opencode|skills/worker/delegate.sh' "$REPO/skills" "$REPO/claude" "$REPO/codex" "$REPO/hooks" "$REPO/README.md"; then
  printf 'FAIL: retired runner reference\n' >&2
  exit 1
fi
printf 'regressions: all passed\n'
