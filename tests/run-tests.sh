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

# --- require-test ---
mkdir -p src/hooks src/constants centralized-tests && rm -f src/foo.ts src/foo.test.ts centralized-tests/foo.test.ts src/bar.tsx src/bar.jsx src/useDevice.ts src/hooks/use-device.ts src/data.hook.ts src/constants.ts src/constants/device.ts
check "require-test: テスト無し ts は deny"   deny  require-test.sh '{"tool_name":"Edit","tool_input":{"file_path":"'$PWD'/src/foo.ts"}}'
touch centralized-tests/foo.test.ts
git add centralized-tests/foo.test.ts
check "require-test: 別directoryの追跡済みtestは棄権" empty require-test.sh '{"tool_name":"Edit","tool_input":{"file_path":"'$PWD'/src/foo.ts"}}'
check "require-test: tsx は棄権"              empty require-test.sh '{"tool_name":"Edit","tool_input":{"file_path":"'$PWD'/src/bar.tsx"}}'
check "require-test: jsx は棄権"              empty require-test.sh '{"tool_name":"Edit","tool_input":{"file_path":"'$PWD'/src/bar.jsx"}}'
check "require-test: useX hook は棄権"        empty require-test.sh '{"tool_name":"Edit","tool_input":{"file_path":"'$PWD'/src/useDevice.ts"}}'
check "require-test: hooks directory は棄権"  empty require-test.sh '{"tool_name":"Edit","tool_input":{"file_path":"'$PWD'/src/hooks/use-device.ts"}}'
check "require-test: .hook.ts は棄権"         empty require-test.sh '{"tool_name":"Edit","tool_input":{"file_path":"'$PWD'/src/data.hook.ts"}}'
check "require-test: schema.prisma は棄権"    empty require-test.sh '{"tool_name":"Edit","tool_input":{"file_path":"'$PWD'/prisma/schema.prisma"}}'
check "require-test: constants.ts は棄権"     empty require-test.sh '{"tool_name":"Edit","tool_input":{"file_path":"'$PWD'/src/constants.ts"}}'
check "require-test: constants/配下は棄権" empty require-test.sh '{"tool_name":"Edit","tool_input":{"file_path":"'$PWD'/src/constants/device.ts"}}'
check "require-test: Bash は棄権"             empty require-test.sh '{"tool_name":"Bash","tool_input":{"command":"ls"}}'

# --- load-required-contract ---
READING_CWD=$PWD
rm -f .claude/tmp/required-reading.*.READ1 .claude/tmp/required-reading.*.READ2
COWLICK_EDIT=$(jq -cn --arg cwd "$READING_CWD" '{hook_event_name:"PreToolUse",session_id:"READ1",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:".claude/prompt/branch-sample-prompt.md"}}')
COWLICK_FIRST=$(echo "$COWLICK_EDIT" | bash "$H/load-required-contract.sh" cowlick-design)
if matches_expected deny "$COWLICK_FIRST" && echo "$COWLICK_FIRST" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -Fq '## Changes'; then
  PASS=$((PASS+1)); echo "ok   required-reading: cowlick形式を初回編集前に全文注入"
else
  FAIL=$((FAIL+1)); echo "FAIL required-reading: cowlick形式を注入できない -> [$COWLICK_FIRST]"
fi
COWLICK_SECOND=$(echo "$COWLICK_EDIT" | bash "$H/load-required-contract.sh" cowlick-design)
if matches_expected empty "$COWLICK_SECOND"; then
  PASS=$((PASS+1)); echo "ok   required-reading: cowlick形式receipt後は棄権"
else
  FAIL=$((FAIL+1)); echo "FAIL required-reading: cowlick形式receiptを再利用できない -> [$COWLICK_SECOND]"
fi
DELEGATE_INPUT=$(jq -cn --arg cwd "$READING_CWD" '{hook_event_name:"PreToolUse",session_id:"READ2",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .claude/skills/worker/delegate.sh prepare"}}')
DELEGATE_FIRST=$(echo "$DELEGATE_INPUT" | bash "$H/load-required-contract.sh")
DELEGATE_REASON=$(echo "$DELEGATE_FIRST" | jq -r '.hookSpecificOutput.permissionDecisionReason')
if matches_expected deny "$DELEGATE_FIRST" && echo "$DELEGATE_REASON" | grep -Fq 'worker委任の共通契約' && [ "$(printf '%s' "$DELEGATE_REASON" | wc -c | tr -d ' ')" -le 4000 ]; then
  PASS=$((PASS+1)); echo "ok   required-reading: 圧縮した外部ワーカー契約を初回委任前に注入"
else
  FAIL=$((FAIL+1)); echo "FAIL required-reading: 圧縮した外部ワーカー契約を注入できない -> [$DELEGATE_FIRST]"
fi
check "required-reading: 外部ワーカー契約receipt後は棄権" empty load-required-contract.sh "$DELEGATE_INPUT"
DELEGATE_NEXT_TASK=$(jq -cn --arg cwd "$READING_CWD" '{hook_event_name:"PreToolUse",session_id:"READ2",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .claude/skills/worker/delegate.sh errand --hard-timeout-minutes 2 --idle-timeout-seconds 60 --poll-seconds 10 --timeout-reason scope=src/foo.ts,difficulty=low,basis=hook-contract-reuse errand-task boolean変更 -- src/foo.ts"}}')
check "required-reading: 同一sessionの別mode・taskでは再注入しない" empty load-required-contract.sh "$DELEGATE_NEXT_TASK"

# --- protect-git ---
check "protect-git: rm .git は deny"      deny  protect-git.sh '{"tool_name":"Bash","tool_input":{"command":"rm -rf .git"}}'
check "protect-git: Edit .git/config は deny" deny protect-git.sh '{"tool_name":"Edit","tool_input":{"file_path":".git/config"}}'
check "protect-git: 通常 Edit は棄権"     empty protect-git.sh '{"tool_name":"Edit","tool_input":{"file_path":"src/a.ts"}}'
check "protect-git: git status は棄権"    empty protect-git.sh '{"tool_name":"Bash","tool_input":{"command":"git status"}}'

# --- protect-config ---
check "config: Edit .claude は deny"    deny  protect-config.sh '{"tool_name":"Edit","tool_input":{"file_path":".claude/settings.json"}}'
check "config: Edit .claude/prompt は許可" empty protect-config.sh '{"tool_name":"Edit","tool_input":{"file_path":".claude/prompt/branch-sample-prompt.md"}}'
check "config: Edit .agents は deny"    deny  protect-config.sh '{"tool_name":"Edit","tool_input":{"file_path":".agents/skills/foo/SKILL.md"}}'
check "config: rm .claude は deny"      deny  protect-config.sh '{"tool_name":"Bash","tool_input":{"command":"rm -rf .claude"}}'
check "config: 設定読み取りは棄権"      empty protect-config.sh '{"tool_name":"Bash","tool_input":{"command":"cat .claude/settings.json"}}'
check "config: 設定script起動は棄権"    empty protect-config.sh '{"tool_name":"Bash","tool_input":{"command":"bash .claude/skills/bootstrap/init-agent.sh claude"}}'

# --- deny-history ---
check "history: git rebase は deny"   deny  deny-history.sh '{"tool_name":"Bash","tool_input":{"command":"git rebase -i HEAD~3"}}'
check "history: force push は deny"   deny  deny-history.sh '{"tool_name":"Bash","tool_input":{"command":"git push -f origin master"}}'
check "history: git commit は棄権"    empty deny-history.sh '{"tool_name":"Bash","tool_input":{"command":"git commit -m msg"}}'

# --- deny-eval ---
check "eval: python3 -c は deny"       deny  deny-eval.sh '{"tool_name":"Bash","tool_input":{"command":"python3 -c import_os"}}'
check "eval: node -e は deny"          deny  deny-eval.sh '{"tool_name":"Bash","tool_input":{"command":"node -e code"}}'
check "eval: python3 foo.py は棄権"    empty deny-eval.sh '{"tool_name":"Bash","tool_input":{"command":"python3 foo.py"}}'

# --- readonly-search ---
check_bash_rewrite "readonly-search: rg stderr破棄をoptionへ正規化" \
  "rg --no-messages -n 'foo|bar' front --glob '!generated/**'" \
  readonly-search.sh \
  "rg -n 'foo|bar' front --glob '!generated/**' 2>/dev/null"
check_bash_rewrite "readonly-search: findのstderr破棄を許可" \
  "find .codex/tmp/worker -maxdepth 2 -type f -print" \
  readonly-search.sh \
  "find .codex/tmp/worker -maxdepth 2 -type f -print 2>/dev/null"
check_bash_rewrite "readonly-search: stdoutのdev null破棄を許可" \
  "nl -ba src/foo.ts >/dev/null" \
  readonly-search.sh \
  "nl -ba src/foo.ts > /dev/null"
check_bash_rewrite "readonly-search: Codexのquote済みrgを直接実行へ正規化" \
  "rg '-n' '^(model|enum) |@@(?:unique|index|map)' 'front/prisma/schema.prisma'" \
  readonly-search.sh \
  "'rg' '-n' '^(model|enum) |@@(?:unique|index|map)' 'front/prisma/schema.prisma'"
check_bash_rewrite "readonly-search: quote済みrgのglob引数を保持" \
  "rg '--files' 'front' '-g' '*schema.test.*' '-g' '*schema.spec.*'" \
  readonly-search.sh \
  "'rg' '--files' 'front' '-g' '*schema.test.*' '-g' '*schema.spec.*'"
check_bash_rewrite "readonly-search: 既定workerモデル指定を除去" \
  "bash .claude/skills/worker/delegate.sh prepare" \
  readonly-search.sh \
  "DELEGATE_MODEL=openrouter/minimax/minimax-m3 bash .claude/skills/worker/delegate.sh prepare"
check_bash_rewrite "readonly-search: wrapper化した既定workerモデル指定を除去" \
  "bash .claude/skills/worker/delegate.sh prepare" \
  readonly-search.sh \
  'zsh -lc "DELEGATE_MODEL=openrouter/minimax/minimax-m3 bash .claude/skills/worker/delegate.sh prepare"'
check_bash_group "readonly-search: 安全な単一コマンドを明示allow" allow readonly-search.sh \
  "rg 'foo|bar' src" \
  "find src -maxdepth 2 -type f -print" \
  "cat src/foo.ts" \
  "nl -ba src/foo.ts" \
  "sort src/files.txt"
check_bash_group "readonly-search: allow対象外の単一コマンドは棄権" empty readonly-search.sh \
  "sed -n '1,240p' src/foo.ts" \
  'echo "$VALUE" 2>&1'
check_bash_group "readonly-search: 複合shellを分割要求で拒否" deny readonly-search.sh \
  "rg --files src | sort" \
  "'rg' '--files' 'src' | 'sort'" \
  "find src -type f -print 2>/dev/null | sort" \
  "rg foo; rm target 2>/dev/null" \
  "rg foo 2>/dev/null | tee result.txt" \
  'rg $(danger) 2>/dev/null' \
  $'pwd\nls' \
  "zsh -lc 'pwd; ls'" \
  "/bin/zsh -lc 'pwd; ls'" \
  "env bash -c 'pwd; ls'" \
  "/usr/bin/env zsh -lc 'pwd; ls'" \
  "bash --noprofile -c 'pwd; ls'" \
  "sleep 1 & echo done" \
  'for f in a.ts b.ts; do if test -f "$f"; then sed -n '\''1,240p'\'' "$f"; fi; done; rg --files src | rg '\''smtp|s3'\'''
check_bash_group "readonly-search: 危険な読み取りoptionを拒否" deny readonly-search.sh \
  "find tmp -type f -delete" \
  "'find' 'tmp' '-type' 'f' '-delete'" \
  "/usr/bin/find tmp -type f -delete" \
  "find tmp -type f -delete 2>/dev/null | sort" \
  'find tmp "-de""lete"' \
  "find tmp -type f -exec rm {} +" \
  "find tmp -type f -fprint result.txt" \
  "sort -o result.txt source.txt" \
  "sort -oresult.txt source.txt" \
  "sort --output=result.txt source.txt" \
  "sort --compress-program=gzip source.txt" \
  "rg --pre preprocess.sh pattern src" \
  "rg --pre=preprocess.sh pattern src" \
  "git diff --output=result.patch" \
  "git show --output=result.txt HEAD"
check_bash_group "readonly-search: 通常fileへのredirectはpermission層へ委任" empty readonly-search.sh \
  "cat src/foo.ts > result.txt" \
  "rg foo > result.txt 2>/dev/null"

# --- deny-registry ---
check "registry: npx は deny"           deny  deny-registry.sh '{"tool_name":"Bash","tool_input":{"command":"npx create-app"}}'
check "registry: npm install は deny"   deny  deny-registry.sh '{"tool_name":"Bash","tool_input":{"command":"npm install left-pad"}}'
check "registry: yarn build は棄権"     empty deny-registry.sh '{"tool_name":"Bash","tool_input":{"command":"yarn build"}}'

# --- deny-migration ---
check_bash_group "migration: PrismaのDB反映commandを拒否" deny deny-migration.sh \
  "node_modules/.bin/prisma migrate dev" \
  "yarn prisma migrate deploy" \
  "npx prisma migrate reset" \
  "prisma db push" \
  "prisma db execute --file migration.sql" \
  "yarn db:migrate"
check_bash_group "migration: schemaの安全な検証commandは許可" empty deny-migration.sh \
  "yarn prisma format --schema prisma/schema.prisma" \
  "node_modules/.bin/prisma validate" \
  "yarn prisma generate"

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

OUT=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git rebase"}}' | bash "$H/deny-history.sh"); RC=$?
if [ "$RC" -eq 0 ] && [ "$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ]; then
  PASS=$((PASS+1)); echo "ok   hook-io: 未実装エージェントは deny JSON + exit 0"
else FAIL=$((FAIL+1)); echo "FAIL hook-io: 未実装エージェント rc=$RC out=[$OUT]"; fi

OUT=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"bash ./skills/bootstrap/init-agent.sh codex"}}' | bash "$H/deny-history.sh"); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then PASS=$((PASS+1)); echo "ok   hook-io: 未実装でも bootstrap は棄権"
else FAIL=$((FAIL+1)); echo "FAIL hook-io: bootstrap例外 rc=$RC out=[$OUT]"; fi

OUT=$(echo '{"hook_event_name":"UserPromptSubmit","prompt":"git rebase して"}' | bash "$H/deny-history.sh"); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then PASS=$((PASS+1)); echo "ok   hook-io: PreToolUse 以外は JSON を出さず棄権"
else FAIL=$((FAIL+1)); echo "FAIL hook-io: 非 PreToolUse rc=$RC out=[$OUT]"; fi

mv "$H/hook-io.sh.orig" "$H/hook-io.sh"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
