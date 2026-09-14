#!/bin/bash
# hook 全数テスト。claude 配置を解決済みのツリー(.claude/hooks/shell)に対して
# Claude Code スキーマの入力を食わせ、deny / ask / 棄権(出力なし) を検証する。
# 単体では動かない: verify-all.sh が配置シミュレーションを作ってからコピーして実行する。
#   実行は `bash tests/verify-all.sh`
SUITE_ROOT="$(cd "$(dirname "$0")" && pwd)"
H="$SUITE_ROOT/.claude/hooks/shell"
cd "$SUITE_ROOT"
PASS=0; FAIL=0

# hook にJSON入力を与えて stdout を返すヘルパー関数
run() { echo "$2" | bash "$H/$1"; }

matches_expected() { # expect(deny|ask|allow|empty) output
  case "$1" in
    deny)  [ "$(echo "$2" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] ;;
    ask)   [ "$(echo "$2" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "ask" ] ;;
    allow) [ "$(echo "$2" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "allow" ] ;;
    empty) [ -z "$2" ] ;;
  esac
}

# 実行結果が期待(deny/ask/allow/empty)と一致するか判定して集計する関数
check() { # name expect(deny|ask|allow|empty) hook json
  OUT=$(run "$3" "$4")
  # deny/ask/allow は「stdout 全体が決定 JSON としてパース可能」まで検査する（出力汚染の検出）
  if matches_expected "$2" "$OUT"; then PASS=$((PASS+1)); echo "ok   $1"
  else FAIL=$((FAIL+1)); echo "FAIL $1 -> [$OUT]"; fi
}

check_bash_group() { # name expect hook command...
  GROUP_NAME=$1
  EXPECTED=$2
  HOOK=$3
  shift 3
  GROUP_FAILURES=
  for COMMAND in "$@"; do
    INPUT=$(jq -cn --arg command "$COMMAND" '{tool_name:"Bash",tool_input:{command:$command}}')
    OUT=$(run "$HOOK" "$INPUT")
    if ! matches_expected "$EXPECTED" "$OUT"; then
      GROUP_FAILURES="${GROUP_FAILURES}\ncommand=[$COMMAND] output=[$OUT]"
    fi
  done
  if [ -z "$GROUP_FAILURES" ]; then PASS=$((PASS+1)); echo "ok   $GROUP_NAME"
  else FAIL=$((FAIL+1)); printf 'FAIL %s%b\n' "$GROUP_NAME" "$GROUP_FAILURES"; fi
}

check_rewrite() { # name expected-command hook json
  OUT=$(run "$3" "$4")
  ACTUAL_DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)
  ACTUAL_COMMAND=$(echo "$OUT" | jq -r '.hookSpecificOutput.updatedInput.command' 2>/dev/null)
  if [ "$ACTUAL_DECISION" = "allow" ] && [ "$ACTUAL_COMMAND" = "$2" ]; then
    PASS=$((PASS+1)); echo "ok   $1"
  else
    FAIL=$((FAIL+1)); echo "FAIL $1 -> decision=[$ACTUAL_DECISION] command=[$ACTUAL_COMMAND]"
  fi
}

check_bash_rewrite() { # name expected-command hook command
  INPUT=$(jq -cn --arg command "$4" '{tool_name:"Bash",tool_input:{command:$command}}')
  check_rewrite "$1" "$2" "$3" "$INPUT"
}


# --- load-required-contract ---
READING_CWD=$PWD
rm -f .claude/tmp/required-reading.*.READ1 .claude/tmp/required-reading.*.READ2
COWLICK_EDIT=$(jq -cn --arg cwd "$READING_CWD" '{hook_event_name:"PreToolUse",session_id:"READ1",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:".claude/prompt/branch-sample-prompt.md"}}')
COWLICK_FIRST=$(echo "$COWLICK_EDIT" | bash "$H/load-required-contract.sh")
if matches_expected deny "$COWLICK_FIRST" && echo "$COWLICK_FIRST" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -Fq '## Changes'; then
  PASS=$((PASS+1)); echo "ok   required-reading: cowlick形式を初回編集前に全文注入"
else
  FAIL=$((FAIL+1)); echo "FAIL required-reading: cowlick形式を注入できない -> [$COWLICK_FIRST]"
fi
COWLICK_SECOND=$(echo "$COWLICK_EDIT" | bash "$H/load-required-contract.sh")
if matches_expected empty "$COWLICK_SECOND"; then
  PASS=$((PASS+1)); echo "ok   required-reading: cowlick形式receipt後は棄権"
else
  FAIL=$((FAIL+1)); echo "FAIL required-reading: cowlick形式receiptを再利用できない -> [$COWLICK_SECOND]"
fi

check "contract loader: 親の起動入力を待ち伏せして拒否しない" empty load-operation-context.sh '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"difficulty-evaluator","prompt":"{}"}}'

check "required-reading: 通常文書は設計形式の対象外" empty load-required-contract.sh '{"hook_event_name":"PreToolUse","session_id":"READOTHER","tool_name":"Edit","tool_input":{"file_path":"docs/notes.md"}}'

# --- protect-git ---
check "protect-git: rm .git は deny"      deny  protect-git.sh '{"tool_name":"Bash","tool_input":{"command":"rm -rf .git"}}'
check "protect-git: Edit .git/config は deny" deny protect-git.sh '{"tool_name":"Edit","tool_input":{"file_path":".git/config"}}'
check "protect-git: 通常 Edit は棄権"     empty protect-git.sh '{"tool_name":"Edit","tool_input":{"file_path":"src/a.ts"}}'
check "protect-git: git status は安全化して許可" allow protect-git.sh '{"tool_name":"Bash","tool_input":{"command":"git status"}}'

# --- protect-config ---
check "config: Edit .claude は deny"    deny  protect-config.sh '{"tool_name":"Edit","tool_input":{"file_path":".claude/settings.json"}}'
check "config: E2E artifactsのWriteは許可" empty protect-config.sh '{"tool_name":"Write","tool_input":{"file_path":".codex/e2e/artifacts/run-001.png"}}'
check "config: E2E artifactsのmkdirは許可" empty protect-config.sh '{"tool_name":"Bash","tool_input":{"command":"mkdir -p .codex/e2e/artifacts"}}'
check "config: E2E artifactsを含む複合mkdirはdeny" deny protect-config.sh '{"tool_name":"Bash","tool_input":{"command":"mkdir -p .codex/e2e/artifacts\nmkdir -p .codex/settings"}}'
check "config: Edit .claude/prompt は許可" empty protect-config.sh '{"tool_name":"Edit","tool_input":{"file_path":".claude/prompt/branch-sample-prompt.md"}}'
check "config: promptから設定へ戻るpathは拒否" deny protect-config.sh '{"tool_name":"Write","tool_input":{"file_path":".claude/prompt/../settings.json"}}'
check "config: Edit .agents は deny"    deny  protect-config.sh '{"tool_name":"Edit","tool_input":{"file_path":".agents/skills/foo/SKILL.md"}}'
check "config: rm .claude は deny"      deny  protect-config.sh '{"tool_name":"Bash","tool_input":{"command":"rm -rf .claude"}}'
check "config: 設定読み取りは棄権"      empty protect-config.sh '{"tool_name":"Bash","tool_input":{"command":"cat .claude/settings.json"}}'
check "config: 設定script起動は棄権"    empty protect-config.sh '{"tool_name":"Bash","tool_input":{"command":"bash .claude/skills/bootstrap/bootstrap.sh claude"}}'

# --- commit-gate ---
check "commit-gate: git add -A は deny"       deny  commit-gate.sh '{"tool_name":"Bash","tool_input":{"command":"git add -A"}}'
check_bash_group "commit-gate: 強制stage は deny" deny commit-gate.sh \
  "git add -f ignored.test.ts" \
  "git add --force ignored.test.ts" \
  "git add ignored.test.ts -f"
check "commit-gate: plain push は deny"       deny  commit-gate.sh '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
check "commit-gate: cherry-pick は deny"      deny  commit-gate.sh '{"tool_name":"Bash","tool_input":{"command":"git cherry-pick abc123"}}'
mkdir -p commit-fixture
cd commit-fixture
git init -q
git config user.email tester@example.com
git config user.name tester
printf 'foo\n' > foo.ts
git add foo.ts
check "commit-gate: 契約形式コミットは棄権" empty commit-gate.sh '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"foo.ts: バグを直した\""}}'
check "commit-gate: ファイル名不一致は deny" deny  commit-gate.sh '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"bar.ts: バグを直した\""}}'
check "commit-gate: 英語だけの変更内容は deny" deny  commit-gate.sh '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"foo.ts: fix bug\""}}'
check "commit-gate: 形式違反は deny"          deny  commit-gate.sh '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix bug\""}}'
check "commit-gate: amend は deny"            deny  commit-gate.sh '{"tool_name":"Bash","tool_input":{"command":"git commit --amend -m \"foo.ts: 修正した\""}}'
printf 'bar\n' > bar.ts
git add bar.ts
check "commit-gate: 複数stageは deny"          deny  commit-gate.sh '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"foo.ts: バグを直した\""}}'
cd ..

# --- overwrite ---
echo x > untracked.txt
check "overwrite: git 管理外の上書きは ask" ask overwrite.sh '{"tool_name":"Write","tool_input":{"file_path":"'$PWD'/untracked.txt"}}'
check "overwrite: 新規作成は棄権"       empty overwrite.sh '{"tool_name":"Write","tool_input":{"file_path":"'$PWD'/nonexistent.txt"}}'
mkdir -p overwrite-fixture
printf 'original\n' > 'overwrite-fixture/[id].ts'
git add 'overwrite-fixture/[id].ts'
git commit -qm "test: overwrite fixture"
check "overwrite: 相対pathのcleanな追跡fileは棄権" empty overwrite.sh '{"tool_name":"Write","tool_input":{"file_path":"overwrite-fixture/[id].ts"}}'
printf 'dirty\n' >> 'overwrite-fixture/[id].ts'
check "overwrite: 相対pathのdirtyな追跡fileは確認" ask overwrite.sh '{"tool_name":"Write","tool_input":{"file_path":"overwrite-fixture/[id].ts"}}'

# --- protect-review ---
check "review: 新規manifestのWriteは確認" ask protect-review.sh '{"tool_name":"Write","tool_input":{"file_path":"apps/new/package.json"}}'

# --- protect-env ---
check "protect-env: Edit .env は deny"        deny  protect-env.sh '{"tool_name":"Edit","tool_input":{"file_path":".env"}}'
check "protect-env: Edit .env.local は deny"  deny  protect-env.sh '{"tool_name":"Edit","tool_input":{"file_path":"config/.env.local"}}'
check "protect-env: Edit env.ts は棄権"       empty protect-env.sh '{"tool_name":"Edit","tool_input":{"file_path":"src/env.ts"}}'
check "protect-env: rm .env は deny"          deny  protect-env.sh '{"tool_name":"Bash","tool_input":{"command":"rm .env"}}'
check "protect-env: リダイレクト書き込みは deny" deny protect-env.sh '{"tool_name":"Bash","tool_input":{"command":"echo A=1 > .env"}}'
check "protect-env: cat .env は棄権"          empty protect-env.sh '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}'

# --- protect-locks ---
check "protect-locks: Edit yarn.lock は deny" deny protect-locks.sh '{"tool_name":"Edit","tool_input":{"file_path":"yarn.lock"}}'
check "protect-locks: Bash 上書きは deny" deny protect-locks.sh '{"tool_name":"Bash","tool_input":{"command":"echo x > package-lock.json"}}'
check "protect-locks: 読み取りは棄権" empty protect-locks.sh '{"tool_name":"Bash","tool_input":{"command":"cat pnpm-lock.yaml"}}'

# --- hook-io フェイルクローズ(未実装エージェント = claude/codex 以外) ---
# 契約: exit 1 は PreToolUse で non-blocking error 扱い = fail-open になるため、
#       PreToolUse には deny 決定 JSON + exit 0 で止める。PreToolUse 以外のイベントは
#       exit 0 の stdout がプロンプトへ注入されるため JSON を出さず棄権する。
#       例外は bootstrap の 1 コマンドのみ（placeholder を解決する初期化自身を止めない）。
sed 's/^HOOK_AGENT="claude"/HOOK_AGENT="github"/' "$H/hook-io.sh" > "$H/hook-io.sh.github"
mv "$H/hook-io.sh" "$H/hook-io.sh.orig" && mv "$H/hook-io.sh.github" "$H/hook-io.sh"

OUT=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git rebase"}}' | bash "$H/protect-git.sh"); RC=$?
if [ "$RC" -eq 0 ] && [ "$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ]; then
  PASS=$((PASS+1)); echo "ok   hook-io: 未実装エージェントは deny JSON + exit 0"
else FAIL=$((FAIL+1)); echo "FAIL hook-io: 未実装エージェント rc=$RC out=[$OUT]"; fi

OUT=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"bash .agents/skills/bootstrap/bootstrap.sh codex"}}' | bash "$H/protect-git.sh"); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then PASS=$((PASS+1)); echo "ok   hook-io: 未実装でも bootstrap は棄権"
else FAIL=$((FAIL+1)); echo "FAIL hook-io: bootstrap例外 rc=$RC out=[$OUT]"; fi

OUT=$(echo '{"hook_event_name":"UserPromptSubmit","prompt":"git rebase して"}' | bash "$H/protect-git.sh"); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then PASS=$((PASS+1)); echo "ok   hook-io: PreToolUse 以外は JSON を出さず棄権"
else FAIL=$((FAIL+1)); echo "FAIL hook-io: 非 PreToolUse rc=$RC out=[$OUT]"; fi

mv "$H/hook-io.sh.orig" "$H/hook-io.sh"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
