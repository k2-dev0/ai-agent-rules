#!/bin/bash
# テンプレート全体の回帰テスト。hook・スキル・配布設定を変更したら必ず走らせること。
#   bash tests/verify-all.sh
# 検証内容: 構文 / 実行ビット / claude 配置シム / hook 全数(run-tests.sh) /
#           rebase E2E / codex 配布物・rules 実機検査 / session スコープ / 残渣チェック
# 作業ファイルは一時ディレクトリに作りリポジトリを汚さない（終了時に自動削除）。
set -u
SUITE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SUITE/.." && pwd)"
S=$(mktemp -d "${TMPDIR:-/tmp}/ai-agent-rules-verify.XXXXXX") || { echo "temp dir を作れない" >&2; exit 1; }
trap 'rm -rf "$S"' EXIT
PASS=0; FAIL=0
MIN_SUPPORTED_CODEX_VERSION="0.138.0"
VERSION_COMPONENT_COUNT=3
EXPECTED_DUAL_HOOK_BINDINGS=2
GIT_COMMIT_HEX_LENGTH=40
PINNED_SERENA_SOURCE_PATTERN="^git\\+https://github\\.com/oraios/serena@[0-9a-f]{$GIT_COMMIT_HEX_LENGTH}$"
SERENA_CODE_MUTATION_TOOLS=(
  execute_shell_command
  create_text_file
  replace_content
  replace_in_files
  delete_lines
  replace_lines
  insert_at_line
  replace_symbol_body
  insert_after_symbol
  insert_before_symbol
  rename_symbol
)
CLAUDE_UNAVAILABLE_SERENA_TOOLS=(
  check_onboarding_performed
  list_dir
  find_file
  search_for_pattern
)
FILESYSTEM_WRITER_COMMANDS=(cp install rsync touch chmod chown chgrp ln patch)
CLAUDE_SAFE_READ_PERMISSIONS=(
  'Bash(find:*)'
  'Bash(nl:*)'
  'Bash(ps -p:*)'
  'Bash(sort:*)'
  'Bash(git ls-files:*)'
  'Bash(git grep:*)'
)
LEGACY_PRODUCT_NAME="claude"
LEGACY_HOOK_NAME="enforce-${LEGACY_PRODUCT_NAME}-commit"
LEGACY_TEST_LABEL="${LEGACY_PRODUCT_NAME}-commit:"
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
ng(){ FAIL=$((FAIL+1)); echo "FAIL $1"; }
append_group_failure(){
  if [ -z "$GROUP_FAILURES" ]; then GROUP_FAILURES=$1
  else GROUP_FAILURES="$GROUP_FAILURES
$1"; fi
}
report_group(){
  if [ -z "$2" ]; then
    ok "$1"
  else
    ng "$1"
    printf '%s\n' "$2" | sed 's/^/  - /'
  fi
}
version_at_least(){
  awk -v current="$1" -v minimum="$2" -v count="$VERSION_COMPONENT_COUNT" 'BEGIN {
    split(current, c, "."); split(minimum, m, ".")
    for (i = 1; i <= count; i++) {
      if ((c[i] + 0) > (m[i] + 0)) exit 0
      if ((c[i] + 0) < (m[i] + 0)) exit 1
    }
    exit 0
  }'
}
mcp_tool_approved(){
  awk -v header="[mcp_servers.$1.tools.$2]" '
    $0 == header { getline; if ($0 == "approval_mode = \"approve\"") found = 1 }
    END { exit !found }
  ' "$3"
}
mcp_server_prompts_by_default(){
  awk -v header="[mcp_servers.$1]" '
    $0 == header { in_server = 1; next }
    in_server && /^\[/ { exit !found }
    in_server && $0 == "default_tools_approval_mode = \"prompt\"" { found = 1 }
    END { exit !found }
  ' "$2"
}
mcp_server_approves_by_default(){
  awk -v header="[mcp_servers.$1]" '
    $0 == header { in_server = 1; next }
    in_server && /^\[/ { exit !found }
    in_server && $0 == "default_tools_approval_mode = \"approve\"" { found = 1 }
    END { exit !found }
  ' "$2"
}

command -v jq >/dev/null 2>&1 || { echo "jq が必要" >&2; exit 1; }

echo "== 1. 構文チェック（require-test.sh は [NOTE] 未解決のため配置後に検査） =="
GROUP_FAILURES=
for f in "$REPO"/hooks/shell/*.sh "$REPO"/skills/*/*.sh "$SUITE"/*.sh; do
  case "$f" in */require-test.sh|*/verify-all.sh) continue ;; esac
  bash -n "$f" 2>/dev/null || append_group_failure "syntax: $f"
done
report_group "shell構文: 対象ファイル全件" "$GROUP_FAILURES"
echo "== 1.5 実行ビット（ハーネスが直接実行する hook は +x 必須。hook-io.sh は source 専用） =="
GROUP_FAILURES=
for f in "$REPO"/hooks/shell/*.sh; do
  case "$f" in */hook-io.sh) continue ;; esac
  [ -x "$f" ] || append_group_failure "exec bit: $f"
done
WORKER_RUNNER="$REPO/skills/worker/delegate.sh"
CLAUDE_IMPLEMENTER="$REPO/claude/agents/implementer.md"
CODEX_IMPLEMENTER="$REPO/codex/agents/implementer.toml"
CLAUDE_SURVEYOR="$REPO/claude/agents/surveyor.md"
CODEX_SURVEYOR="$REPO/codex/agents/surveyor.toml"
IMPLEMENTER_PREFLIGHT_SCRIPT="$REPO/skills/tdd/preflight-implementer.sh"
[ -x "$WORKER_RUNNER" ] || append_group_failure "exec bit: $WORKER_RUNNER"
[ -x "$IMPLEMENTER_PREFLIGHT_SCRIPT" ] || append_group_failure "exec bit: $IMPLEMENTER_PREFLIGHT_SCRIPT"
report_group "実行ビット: hookと実行器全件" "$GROUP_FAILURES"
grep -q 'SOFT_BUDGET_USD="38"' "$WORKER_RUNNER" && grep -q 'HARD_BUDGET_USD="40"' "$WORKER_RUNNER" && ok "外部ワーカー予算: soft=38 hard=40" || ng "外部ワーカー予算が不正"
grep -q 'DEFAULT_MODEL="openrouter/minimax/minimax-m3"' "$WORKER_RUNNER" && grep -Fq 'MODEL="${DELEGATE_MODEL:-$DEFAULT_MODEL}"' "$WORKER_RUNNER" && grep -Fq 'MODEL_ID="${MODEL#openrouter/}"' "$WORKER_RUNNER" && ok "外部ワーカーモデル: MiniMax M3を既定値として差し替え可能" || ng "外部ワーカーモデルの既定値または差し替えが不正"
grep -Fq 'MODEL_VARIANT="${DELEGATE_MODEL_VARIANT:-}"' "$WORKER_RUNNER" && grep -q -- '--arg model_variant "$MODEL_VARIANT"' "$WORKER_RUNNER" && grep -q 'model_variant:(if $model_variant == "" then null else $model_variant end)' "$WORKER_RUNNER" && grep -q 'command+=(--variant "$MODEL_VARIANT")' "$WORKER_RUNNER" && ! grep -q 'reasoningEffort' "$WORKER_RUNNER" && ok "外部ワーカーvariant: 既定はadaptive、明示時だけ指定" || ng "外部ワーカーvariantの任意指定が不正"
if grep -Fq 'research and survey modes were removed; lower models are limited to bounded QA' "$WORKER_RUNNER" && grep -q 'mode must be nesting, prepare, smoke, or show' "$WORKER_RUNNER"; then
  ok "workerはnesting限定QAだけを公開"
else
  ng "workerにresearch / survey入口が残存"
fi
grep -q 'XDG_DATA_HOME="$TEMP_ROOT/xdg-data"' "$WORKER_RUNNER" && grep -q 'XDG_STATE_HOME="$TEMP_ROOT/xdg-state"' "$WORKER_RUNNER" && grep -q 'XDG_CACHE_HOME="$TEMP_ROOT/xdg-cache"' "$WORKER_RUNNER" && grep -q 'XDG_CONFIG_HOME="$TEMP_ROOT/xdg-config"' "$WORKER_RUNNER" && grep -q 'TMPDIR="$TEMP_ROOT/tmp"' "$WORKER_RUNNER" && ok "worker OpenCode状態: task単位XDG・tmp分離" || ng "worker OpenCode状態: XDG・tmp分離が不足"
grep -q 'SMOKE_IDLE_TIMEOUT_SECONDS="30"' "$WORKER_RUNNER" && grep -q 'TIMEOUT_POLICY_SOURCE="explicit"' "$WORKER_RUNNER" && grep -q 'MIN_POLLS_PER_IDLE_WINDOW="3"' "$WORKER_RUNNER" && grep -q 'MIN_IDLE_WINDOWS_PER_HARD_TIMEOUT="2"' "$WORKER_RUNNER" && grep -q '^validate_timeout_reason()' "$WORKER_RUNNER" && grep -q -- '--arg timeout_reason "$TIMEOUT_REASON"' "$WORKER_RUNNER" && grep -q '^has_valid_event()' "$WORKER_RUNNER" && grep -q '^monitor_opencode()' "$WORKER_RUNNER" && grep -q '^terminate_process_group()' "$WORKER_RUNNER" && grep -q 'return 124' "$WORKER_RUNNER" && grep -q -- '--argjson timed_out "$TIMED_OUT"' "$WORKER_RUNNER" && ok "worker timeout: 有効event・明示値・理由・安全比率を検証して記録" || ng "worker timeout設定・event観測・理由記録が不正"
grep -q '^write_task_state()' "$WORKER_RUNNER" && grep -q '^stop_running_children()' "$WORKER_RUNNER" && grep -q 'task is already active or has unfinished state' "$WORKER_RUNNER" && grep -q 'effective_status' "$WORKER_RUNNER" && ok "worker lifecycle: task状態と重複拒否を記録" || ng "worker lifecycle管理が不正"
grep -q -- '--arg model_id "$MODEL_ID"' "$WORKER_RUNNER" && ! grep -q 'MODEL_ID="$MODEL_ID".*jq' "$WORKER_RUNNER" && ok "worker config: readonly定数をjq引数で受け渡す" || ng "worker config: readonly変数への再代入が残存"
grep -q '"zdr":true' "$WORKER_RUNNER" && grep -q '"data_collection":"deny"' "$WORKER_RUNNER" && ok "worker routing: ZDRとdata collection拒否" || ng "worker routingのprivacy強制漏れ"
grep -Fq 'EDIT_RULES='\''{"*":"deny"}'\''' "$WORKER_RUNNER" && grep -q '"external_directory":"deny"' "$WORKER_RUNNER" && grep -q 'opencode --pure run' "$WORKER_RUNNER" && ok "worker権限: edit・外部dir・pluginを拒否" || ng "workerの読み取り専用権限境界が不正"
grep -Fq '".git/**":"deny"' "$WORKER_RUNNER" && grep -Fq '"**/.env.*":"deny"' "$WORKER_RUNNER" && ! grep -q 'snapshot_ignored_agent_context' "$WORKER_RUNNER" && ok "worker読み取り: Git・envを拒否しignored agent contextを持ち込まない" || ng "workerのGit・env・agent context境界が不正"
grep -Fq 'trap cleanup EXIT' "$WORKER_RUNNER" && grep -Fq "trap 'exit 130' INT" "$WORKER_RUNNER" && grep -Fq "trap 'exit 143' TERM" "$WORKER_RUNNER" && ok "worker中断: cleanup後に処理を継続しない" || ng "workerのsignal終了処理が不正"
grep -q 'SMOKE_PROMPT="hello"' "$WORKER_RUNNER" && grep -q 'read_rules='\''"deny"'\''' "$WORKER_RUNNER" && grep -q '"bash":"deny"' "$WORKER_RUNNER" && ok "worker smoke: hello固定・tool全拒否" || ng "worker smokeのpromptまたは権限が不正"
grep -q '^  nesting)' "$WORKER_RUNNER" && grep -q '機能調査、要件判断、設計判断、修正案、コード変更は禁止' "$WORKER_RUNNER" && grep -q 'nesting path must be tracked' "$WORKER_RUNNER" && ok "worker nesting: 本体コードだけを読み取り検出" || ng "worker nesting検出モードが不正"
grep -Fq 'git -C "$REPO_ROOT" show "$SOURCE_COMMIT:$path" > "$WORKTREE/$path"' "$WORKER_RUNNER" && grep -Fq 'cd "$execution_root" || exit 72' "$WORKER_RUNNER" && grep -Fq 'bounded_snapshot_unchanged' "$WORKER_RUNNER" && grep -Fq 'read-only delegated model changed a protected path' "$WORKER_RUNNER" && ok "worker snapshot: HEADの指定pathだけを固定し変更を機械拒否" || ng "workerの限定snapshotまたは読み取り専用検査が不正"
if [ ! -e "$REPO/skills/worker/validate-survey-request.sh" ] && [ ! -e "$REPO/skills/worker/DELEGATION.md" ]; then
  ok "worker旧調査契約とvalidatorを削除"
else
  ng "worker旧調査契約またはvalidatorが残存"
fi
grep -q '^  show)' "$WORKER_RUNNER" && grep -q 'show mode requires task id' "$WORKER_RUNNER" && grep -q "cannot extract delegated report" "$WORKER_RUNNER" && ok "外部ワーカー結果: report抽出と固定showを提供" || ng "外部ワーカー結果の固定取得経路が不正"
if grep -q '^  prepare)' "$WORKER_RUNNER" && grep -q 'delegation contract ready' "$WORKER_RUNNER" && [ "$(OPENROUTER_API_KEY= bash "$WORKER_RUNNER" prepare)" = 'delegate: delegation contract ready' ]; then
  ok "外部ワーカーprepare: API key・外部通信なしの共通契約入口を提供"
else
  ng "外部ワーカーprepareの固定入口が不正"
fi

BOOTSTRAP_SKILL="$REPO/skills/bootstrap/SKILL.md"
BOOTSTRAP_FAILURES="$REPO/skills/bootstrap/FAILURES.md"
if grep -q '^allowed-tools: Bash$' "$BOOTSTRAP_SKILL" && grep -q '最初のツール呼び出し' "$BOOTSTRAP_SKILL" && grep -Fq '失敗した場合だけ [FAILURES.md](FAILURES.md) を読み' "$BOOTSTRAP_SKILL" && [ -f "$BOOTSTRAP_FAILURES" ]; then
  ok "bootstrap: 初期化scriptを最初のtool呼び出しに固定"
else
  ng "bootstrap: 初期化前の不要なtool呼び出しを許可"
fi
[ -f "$REPO/SOURCE_REPOSITORY.md" ] && grep -Fq 'application repositoryではない' "$REPO/SOURCE_REPOSITORY.md" && grep -Fq '配布しない' "$REPO/SOURCE_REPOSITORY.md" && ok "配布元専用contextが明示的" || ng "配布元専用contextが不足"

echo "== 設計pipelineのskill境界 =="
MEETING_SKILL="$REPO/skills/meeting/SKILL.md"
PREFLIGHT_SKILL="$REPO/skills/preflight/SKILL.md"
COWLICK_SKILL="$REPO/skills/cowlick/SKILL.md"
PONYTAIL_SKILL="$REPO/skills/ponytail/SKILL.md"
COWLICK_FORMAT="$REPO/skills/cowlick/DESIGN_FORMAT.md"
REQUIRED_READING_HOOK="$REPO/hooks/shell/load-required-contract.sh"
for SKILL_FILE in "$MEETING_SKILL" "$PREFLIGHT_SKILL" "$COWLICK_SKILL" "$PONYTAIL_SKILL"; do
  [ -f "$SKILL_FILE" ] && ok "design skill存在: $(basename "$(dirname "$SKILL_FILE")")" || ng "design skill不在: $SKILL_FILE"
done
grep -q '^disable-model-invocation: true$' "$MEETING_SKILL" && grep -Fq 'ユーザーが `$meeting` を明示して' "$MEETING_SKILL" && grep -Fq '`$meeting` の明示呼び出しでだけ起動する' "$MEETING_SKILL" && grep -Fq '通常の自然言語による軽微な修正・追加依頼では起動しない' "$MEETING_SKILL" && grep -Fq '  - Skill(preflight)' "$MEETING_SKILL" && grep -Fq '  - Skill(cowlick *)' "$MEETING_SKILL" && grep -Fq '  - Skill(ponytail)' "$MEETING_SKILL" && grep -Fq '  - AskUserQuestion' "$MEETING_SKILL" && ! grep -Fq '  - Bash' "$MEETING_SKILL" && ok "meetingを明示起動だけに限定する" || ng "meetingの起動境界・skill境界が不正"
grep -q 'preflight → cowlick → ponytail' "$MEETING_SKILL" && ! grep -q 'cowlick apply\|最終承認を得る' "$MEETING_SKILL" && ok "meetingは承認・反映phaseなしで設計する" || ng "meetingの基本順序または承認gateが不正"
for INTERNAL_SKILL in "$PREFLIGHT_SKILL" "$COWLICK_SKILL" "$PONYTAIL_SKILL"; do
  grep -q '^user-invocable: false$' "$INTERNAL_SKILL" && ok "内部skillをmenuから隠す: $(basename "$(dirname "$INTERNAL_SKILL")")" || ng "内部skillがユーザー起動可能: $INTERNAL_SKILL"
  if grep -q '^disable-model-invocation: true$' "$INTERNAL_SKILL"; then
    ng "内部skillをmodelが呼べない: $INTERNAL_SKILL"
  else
    ok "内部skillをmodelが呼べる: $(basename "$(dirname "$INTERNAL_SKILL")")"
  fi
done
if sed -n '1,/^---$/p' "$PREFLIGHT_SKILL" | grep -Eq 'allowed-tools:.*(Write|Edit|AskUserQuestion)'; then
  ng "preflightに書き込みtoolがある"
else
  ok "preflightは読み取り専用"
fi
if sed -n '1,/^---$/p' "$PONYTAIL_SKILL" | grep -Eq 'allowed-tools:.*Write' && sed -n '1,/^---$/p' "$PONYTAIL_SKILL" | grep -Eq 'allowed-tools:.*Edit' && ! sed -n '1,/^---$/p' "$PONYTAIL_SKILL" | grep -Eq 'allowed-tools:.*AskUserQuestion'; then
  ok "ponytailはprompt設計書だけを直接更新できる"
else
  ng "ponytailの設計書更新toolまたは質問境界が不正"
fi
grep -Fq '調査を下位モデル、subagent、外部workerへ委任しない' "$MEETING_SKILL" && grep -Fq '下位モデル、subagent、外部workerへ調査を委任しない' "$PREFLIGHT_SKILL" "$COWLICK_SKILL" "$PONYTAIL_SKILL" && ! grep -Fq 'worker/delegate.sh' "$MEETING_SKILL" "$PREFLIGHT_SKILL" "$COWLICK_SKILL" "$PONYTAIL_SKILL" && ok "設計調査と判断を上位モデルへ固定" || ng "設計調査を下位モデルへ委任できる"
grep -Fq '事前知識を何も持たない状態で開始する' "$PONYTAIL_SKILL" && grep -Fq 'コードベースを独立に再調査する' "$PONYTAIL_SKILL" && grep -Fq '以前の文脈で穴埋めせず`blocked`を返す' "$PONYTAIL_SKILL" && grep -Fq 'ponytailへpreflightの調査結果、cowlickの作成経緯、ユーザーとの会話要約を入力として渡さない' "$MEETING_SKILL" && ok "ponytailを前段知識なしの独立監査へ固定" || ng "ponytailへ前段知識を持ち込める"
grep -Fq '**明示要件**' "$PREFLIGHT_SKILL" && grep -Fq '**設計選択**' "$PREFLIGHT_SKILL" && grep -q '境界を新設しない基準案' "$PREFLIGHT_SKILL" && ok "preflightの要件由来・境界ゼロ契約" || ng "preflightの要件由来・境界ゼロ契約が不足"
grep -q '設計書ごと削除' "$COWLICK_SKILL" && grep -q '境界を新設しない基準案' "$COWLICK_SKILL" && grep -q '設計選択同士' "$COWLICK_SKILL" && ok "cowlickの最小draft契約" || ng "cowlickの最小draft契約が不足"
grep -Fq 'cowlick/DESIGN_FORMAT.md' "$REQUIRED_READING_HOOK" && grep -Fq 'Summary' "$COWLICK_FORMAT" && grep -Fq '## Changes' "$COWLICK_FORMAT" && grep -Fq 'error処理とDB書き込み、メール、外部API' "$COWLICK_FORMAT" && ok "cowlickの設計書形式を必要時に強制注入" || ng "cowlickの設計書形式参照が不正"
if grep -Fq 'DESIGN_FORMAT.md' "$REPO"/skills/*/SKILL.md; then
  ng "必要時注入する共通契約名がSKILL.mdへ重複"
else
  ok "共通契約は必要時までSKILL.mdへ載せない"
fi
grep -Fq '実装者が挙動を再設計せずコードへ変換できる密度' "$COWLICK_FORMAT" && grep -Fq 'guardの評価順、導出値と計算式' "$COWLICK_FORMAT" && grep -Fq '`where`の全条件と日付境界' "$COWLICK_FORMAT" && grep -Fq 'clientで検証する範囲とserverの最新dataで再検証する範囲' "$COWLICK_FORMAT" && grep -Fq '圧縮してよいのは重複説明と同一の外枠だけ' "$COWLICK_FORMAT" && grep -Fq '重要な分岐・式・順序・契約を保持' "$COWLICK_SKILL" && ok "cowlickの実装可能な疑似コード密度" || ng "cowlickの疑似コードが実装契約を省略可能"
grep -Fq '| 書き方 | 対象 | 例 |' "$COWLICK_FORMAT" && grep -Fq '予約語・演算子・構文、組み込み型と組み込みobject' "$COWLICK_FORMAT" && grep -Fq '標準library・外部library・frameworkのAPI、instance method・property名を英語' "$COWLICK_FORMAT" && grep -Fq '新しく設計する業務上の関数、引数、変数、型、結果field、error名、処理内容は日本語' "$COWLICK_FORMAT" && grep -Fq '既存symbol、schema field、file pathも参照を壊さないよう実名' "$COWLICK_FORMAT" && grep -Fq '予約語・構文を英語、新しく設計する識別子と処理内容を日本語' "$COWLICK_SKILL" && ok "cowlick疑似コードの英語構文・日本語識別子契約" || ng "cowlick疑似コードの言語規則が曖昧"
grep -Fq '次は書式と密度の例であり、この処理自体を要件として流用しない' "$COWLICK_FORMAT" && grep -Fq '候補一覧[].length' "$COWLICK_FORMAT" && grep -Fq '候補一覧[].slice(...)' "$COWLICK_FORMAT" && grep -Fq '利用結果{}' "$COWLICK_FORMAT" && grep -Fq 'for (const 使用候補 of 使用候補一覧[])' "$COWLICK_FORMAT" && grep -Fq 'return 利用結果{}' "$COWLICK_FORMAT" && ok "cowlick疑似コードの正例" || ng "cowlick疑似コードの正例が不足"
grep -q '## 必須監査成果物' "$PONYTAIL_SKILL" && grep -Fq '`ponytail_audit`' "$PONYTAIL_SKILL" && grep -Fq '`minimalAlternative`' "$PONYTAIL_SKILL" && grep -Fq '`counterexamples`' "$PONYTAIL_SKILL" && grep -Fq '`unresolved`' "$PONYTAIL_SKILL" && grep -q '何も削らなかった場合' "$PONYTAIL_SKILL" && grep -q '全fieldが埋まり.*ponytail_ready' "$PONYTAIL_SKILL" && ok "ponytailの横断削除・ready gate契約" || ng "ponytailの横断削除・ready gate契約が不足"
grep -Fq '入口、共有責務、全caller・consumer' "$PONYTAIL_SKILL" && grep -Fq '報告された症状とroot causeを分ける' "$PONYTAIL_SKILL" && grep -Fq '実装が一つだけのinterface' "$PONYTAIL_SKILL" && grep -Fq '測定可能な条件' "$PONYTAIL_SKILL" && grep -Fq '[delete|reuse|stdlib|native|yagni|shrink]' "$PONYTAIL_SKILL" && grep -Fq '最小の実行可能なテスト' "$PONYTAIL_SKILL" && ok "ponytailの理解・root cause・簡素化負債契約" || ng "ponytailの理解または簡素化境界が不足"
grep -Fq '重複説明と同一の外枠だけを統合' "$PONYTAIL_SKILL" && grep -Fq 'where・sort・tie-break' "$PONYTAIL_SKILL" && grep -Fq '文章一行へ畳まない' "$PONYTAIL_SKILL" && ok "ponytailは実装契約を失う圧縮を禁止" || ng "ponytailが疑似コードの重要契約を圧縮可能"
grep -Fq '同一file内の呼び出しを外部consumerに数えず' "$PONYTAIL_SKILL" && grep -Fq '別の値から導ける定数' "$PONYTAIL_SKILL" && grep -Fq '`counterexamples`' "$PONYTAIL_SKILL" && grep -Fq '実装ファイルがまだ存在しないことだけを理由に `blocked` にしない' "$PONYTAIL_SKILL" && ok "ponytailの要素単位consumer・反例監査契約" || ng "ponytailの要素単位consumerまたは反例監査契約が不足"
grep -Fq '一つのfindingはIDを付けて一度だけ説明' "$PONYTAIL_SKILL" && grep -Fq '同じ要件・原因・判断・置換先を持つ要素は一行へまとめる' "$PONYTAIL_SKILL" && grep -Fq '同じtopologyや根拠を別fieldで言い換えない' "$PONYTAIL_SKILL" && ok "ponytailの監査正本は重複せず簡潔" || ng "ponytailの監査成果物が重複可能"
grep -q 'ponytail_ready.*文字列だけでは通過させない' "$MEETING_SKILL" && grep -Fq '`ponytail_audit`の必須field' "$MEETING_SKILL" && grep -Fq '空の`unresolved`' "$MEETING_SKILL" && ok "meetingのponytail成果物検証" || ng "meetingがponytailのstatusだけを信用している"
grep -Fq 'topologyが入口から副作用まで繋がる' "$MEETING_SKILL" && grep -Fq '対応要件と直接の外部consumer' "$MEETING_SKILL" && grep -Fq '具体値の反例' "$MEETING_SKILL" && ok "meetingがponytailの主要成果物を独立検証" || ng "meetingのponytail独立検証が不足"
grep -Fq '設計判断、横断比較、設計書の採否、ユーザーへ提示する選択肢は、オーケストレーターである[agent_name]が担当する' "$MEETING_SKILL" && grep -Fq '設計判断、横断比較、採否、設計書の修正はすべて[agent_name]が行う' "$PONYTAIL_SKILL" && ok "ponytailの最終設計判断を上位モデルへ固定" || ng "ponytailが設計判断を下位モデルへ委任できる"
grep -q 'design_ready.*停止' "$COWLICK_SKILL" && grep -Fq '`.[agent_name]/prompt/` へ直接作成・更新する' "$COWLICK_SKILL" && ! grep -q '^## apply\|draft-prompt\|最終承認' "$COWLICK_SKILL" && ! grep -q 'draft-prompt\|正式反映を行わない' "$PONYTAIL_SKILL" && ok "cowlickとponytailはprompt正本を直接更新" || ng "cowlick/ponytailのprompt直接更新境界が不正"
GROUP_FAILURES=
for LEGACY_DESIGN_SKILL in design-preflight design-pipeline compose-prompt; do
  [ ! -d "$REPO/skills/$LEGACY_DESIGN_SKILL" ] || append_group_failure "旧directory: skills/$LEGACY_DESIGN_SKILL"
  if command grep -rn "$LEGACY_DESIGN_SKILL" "$REPO/README.md" "$REPO/skills" "$REPO/codex" "$REPO/claude" >/dev/null 2>&1; then
    append_group_failure "旧reference: $LEGACY_DESIGN_SKILL"
  fi
done
report_group "旧design skillのdirectory・参照なし" "$GROUP_FAILURES"

echo "== skill context圧縮と参照整合性 =="
SKILL_LINE_CEILING=1300
SKILL_LINE_COUNT=$(wc -l "$REPO"/skills/*/SKILL.md | awk 'END {print $1}')
[ "$SKILL_LINE_COUNT" -le "$SKILL_LINE_CEILING" ] && ok "SKILL.md総量を${SKILL_LINE_CEILING}行以下へ制限: $SKILL_LINE_COUNT" || ng "SKILL.md総量が肥大化: $SKILL_LINE_COUNT"
GROUP_FAILURES=
[ -f "$COWLICK_FORMAT" ] || append_group_failure "cowlick設計形式なし"
[ -f "$REPO/skills/tdd/SCENARIO_FLOW.md" ] || append_group_failure "tdd/errand共通シナリオフローなし"
[ -f "$REPO/skills/tdd/REVIEW_FLOW.md" ] || append_group_failure "上位レビュー・下位再実装の共通契約なし"
report_group "progressive disclosure参照が全件存在" "$GROUP_FAILURES"
if bash "$SUITE/verify-context-mcp.sh" > "$S/context-mcp.out" 2>&1; then
  ok "dictionary skillとMCP配布設定を統合"
else
  ng "dictionary skillまたはMCP配布設定が不正"
  cat "$S/context-mcp.out"
fi

echo "== 上位モデル直接調査と下位モデル初回・再実装 =="
ERRAND_SKILL="$REPO/skills/errand/SKILL.md"
SCENARIO_FLOW="$REPO/skills/tdd/SCENARIO_FLOW.md"
REVIEW_FLOW="$REPO/skills/tdd/REVIEW_FLOW.md"
[ -f "$CLAUDE_IMPLEMENTER" ] && grep -q '^model: claude-sonnet-5$' "$CLAUDE_IMPLEMENTER" && grep -q '^effort: max$' "$CLAUDE_IMPLEMENTER" && grep -q '^tools: Read, Grep, Glob, Edit, Write, Bash$' "$CLAUDE_IMPLEMENTER" && ! grep -Eq '^tools:.*Agent' "$CLAUDE_IMPLEMENTER" && ok "Claude implementer: Sonnet 5 maxと指定test用Bashを固定" || ng "Claude implementerのmodel・effort・tool境界が不正"
[ -f "$CODEX_IMPLEMENTER" ] && grep -q '^model = "gpt-5.6-luna"$' "$CODEX_IMPLEMENTER" && grep -q '^model_reasoning_effort = "max"$' "$CODEX_IMPLEMENTER" && grep -q '^sandbox_mode = "workspace-write"$' "$CODEX_IMPLEMENTER" && ok "Codex implementer: Luna maxとworkspace writeを固定" || ng "Codex implementerのmodel・effort・sandbox境界が不正"
grep -Fq 'This is an implementation action, not an investigation, review, approval, or scenario-classification task' "$CLAUDE_IMPLEMENTER" "$CODEX_IMPLEMENTER" && grep -Fq 'Use the facts already confirmed by the parent' "$CLAUDE_IMPLEMENTER" "$CODEX_IMPLEMENTER" && grep -Fq 'requested initial implementation or review-directed reimplementation' "$CLAUDE_IMPLEMENTER" "$CODEX_IMPLEMENTER" && grep -Fq 'If a new design decision or broad investigation is required' "$CLAUDE_IMPLEMENTER" "$CODEX_IMPLEMENTER" && grep -Fq 'Outcome: implemented' "$CLAUDE_IMPLEMENTER" "$CODEX_IMPLEMENTER" && grep -Fq '要求に直接必要なproduction code' "$CLAUDE_IMPLEMENTER" "$CODEX_IMPLEMENTER" && grep -Fq 'briefに列挙したtest command' "$CLAUDE_IMPLEMENTER" "$CODEX_IMPLEMENTER" && ok "implementer: 上位モデルの確定済み指示から初回・再実装と指定testを行う" || ng "implementerの実装専用境界が不足"
[ ! -e "$CLAUDE_SURVEYOR" ] && [ ! -e "$CODEX_SURVEYOR" ] && ok "native surveyor定義を削除" || ng "native surveyor定義が残存"
grep -Fq '`claude/agents/` | `<repo>/.claude/agents/`' "$REPO/README.md" && grep -Fq '`codex/agents/` | `<repo>/.codex/agents/`' "$REPO/README.md" && ok "README: 両agent定義の配布先を明記" || ng "README: implementer定義の配布先が不足"
for IMPLEMENTER_FILE in "$CLAUDE_IMPLEMENTER" "$CODEX_IMPLEMENTER"; do
  if grep -Fq '半年後の保守者' "$IMPLEMENTER_FILE" && grep -Fq '不要なhelper分割、過度な抽象化、将来用の拡張点' "$IMPLEMENTER_FILE" && grep -Fq '`filter().map()`' "$IMPLEMENTER_FILE" && grep -Fq '`reduce()`' "$IMPLEMENTER_FILE" && grep -Fq '多少冗長でも読みやすい' "$IMPLEMENTER_FILE"; then
    ok "implementer可読性契約: $(basename "$IMPLEMENTER_FILE")"
  else
    ng "implementer可読性契約が不足: $IMPLEMENTER_FILE"
  fi
done
[ -f "$ERRAND_SKILL" ] && grep -q '^disable-model-invocation: true$' "$ERRAND_SKILL" && grep -q 'allow_implicit_invocation: false' "$REPO/skills/errand/agents/openai.yaml" && ok "errand スキルは明示起動だけ許可" || ng "errand スキルの明示起動境界が不正"
grep -Fq 'ユーザーが明示的にerrandを呼んだ場合だけ' "$ERRAND_SKILL" && grep -Fq 'meeting / cowlick / ponytail / tddは呼ばない' "$ERRAND_SKILL" && grep -Fq '識別子、path、番号、固有名詞を省略・翻訳・一般化しない' "$ERRAND_SKILL" && grep -Fq '最寄りの同型実装1件' "$ERRAND_SKILL" && grep -Fq '[agent_name]が次を直接確認する' "$ERRAND_SKILL" && grep -Fq '外部workerへ調査を委任しない' "$ERRAND_SKILL" && ok "errand は上位モデルの直接調査へ固定" || ng "errand の直接調査境界が不正"
grep -q 'AskUserQuestion' "$ERRAND_SKILL" && ! grep -Fq 'command: .[agent_name]/hooks/shell/require-test.sh' "$ERRAND_SKILL" && grep -Fq '../tdd/SCENARIO_FLOW.md' "$ERRAND_SKILL" && grep -Fq '新しいテストまたはテストファイルが必要なことは停止理由にしない' "$ERRAND_SKILL" && grep -Fq 'ユーザーが選択したものだけをテストへ変換する' "$ERRAND_SKILL" && ok "errand はユーザー選択後のテスト追加を許可" || ng "errand が追加テストで停止またはユーザー選択なしで変更可能"
grep -Fq '初回実装は専用`implementer` subagent' "$ERRAND_SKILL" && ! grep -Fq 'worker/delegate.sh' "$ERRAND_SKILL" && grep -Fq 'native implementerにテスト、設定、migration、Git、設計資産を変更させない' "$ERRAND_SKILL" && ok "errand は上位モデル調査と下位モデル初回実装を分離" || ng "errand の調査・実装境界が不正"
grep -Fq '同型実装から名前・内容を一意に決められる新規本体ファイル' "$ERRAND_SKILL" && grep -q '親directoryが存在しない' "$REPO/skills/polish/capture-scope.sh" && grep -q 'ignoredされている' "$REPO/skills/polish/capture-scope.sh" && ok "errand は一意な定型ファイル追加だけ許可" || ng "errand の新規ファイル境界が不正"
grep -Fq '未実装、複数、または対応テストが未作成であることだけを理由に停止しない' "$ERRAND_SKILL" && grep -Fq 'schema.prisma' "$ERRAND_SKILL" && grep -Fq 'migration fileの作成' "$ERRAND_SKILL" && ok "errand は複数path・未作成test・Prisma schemaを許可しmigrationを禁止" || ng "errand の複数path・test・Prisma境界が不正"
grep -Fq '初回実装は専用`implementer` subagent' "$ERRAND_SKILL" && grep -Fq '変更前worktreeがcleanな場合だけ一度再起動' "$ERRAND_SKILL" && grep -Fq '小さい問題だけ直接修正し、大きい問題は下位モデルへ再実装' "$ERRAND_SKILL" && grep -Fq 'effort `max`' "$ERRAND_SKILL" && grep -Fq '問題の大小、部分採用、全体拒否、最終完了の判断は上位モデル' "$ERRAND_SKILL" && ok "errand は上位モデル判断・下位モデル初回・再実装へ固定" || ng "errand の初回実装・修正責務が不正"
if [ ! -e "$REPO/hooks/shell/delegate.sh" ] && ! grep -q 'hooks/shell/delegate.sh' "$REPO/codex/hooks.json" "$REPO/claude/settings.json"; then
  ok "上位モデルの独立読み取りを調査委任hookで遮断しない"
else
  ng "上位モデルの読み取りを遮断する調査委任hookが残存"
fi
GROUP_FAILURES=
for REMOVED_SKILL in audit interview conductor prototype; do
  [ ! -d "$REPO/skills/$REMOVED_SKILL" ] || append_group_failure "旧directory: skills/$REMOVED_SKILL"
  if command grep -rn "\b$REMOVED_SKILL\b" "$REPO/README.md" "$REPO/AGENTS.md" "$REPO/skills" "$REPO/codex" "$REPO/claude" >/dev/null 2>&1; then
    append_group_failure "旧reference: $REMOVED_SKILL"
  fi
done
report_group "未使用skill audit・interview・conductor・prototypeのdirectory・参照なし" "$GROUP_FAILURES"

echo "== tdd の設計書実装と最終品質ゲート =="
POLISH_SKILL="$REPO/skills/polish/SKILL.md"
UNWIND_SKILL="$REPO/skills/unwind/SKILL.md"
TDD_SKILL="$REPO/skills/tdd/SKILL.md"
QUALITY_GATE_SCRIPT="$REPO/skills/polish/quality-gate.sh"
CAPTURE_SCOPE_SCRIPT="$REPO/skills/polish/capture-scope.sh"
MARK_PROMPT_DONE_SCRIPT="$REPO/skills/tdd/mark-prompt-done.sh"
[ -f "$UNWIND_SKILL" ] && python3 /Users/kaikojima/.codex/skills/.system/skill-creator/scripts/quick_validate.py "$REPO/skills/unwind" >/dev/null && ok "unwind スキルが有効" || ng "unwind スキルが無効"
grep -Fq 'Skill(unwind)' "$POLISH_SKILL" && grep -q '必ず呼ぶ' "$POLISH_SKILL" && ok "polish はunwindを必須化" || ng "polish のunwind連携が無い"
grep -q '新しい関数・メソッド・helperへ切り出して直後に呼ぶ' "$UNWIND_SKILL" && grep -q 'IIFE、callback、lambda、local functionへ押し込む' "$UNWIND_SKILL" && ok "unwind は見せかけの関数抽出を禁止" || ng "unwind の関数抽出禁止が無い"
grep -Fq '検出候補の抽出だけを下位モデル' "$UNWIND_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh nesting' "$UNWIND_SKILL" && grep -Fq '検証済みの実変更pathだけ' "$UNWIND_SKILL" && grep -Fq '機能の目的、要件、設計、変更範囲の調査は依頼しない' "$UNWIND_SKILL" && grep -q '返却された候補だけ' "$POLISH_SKILL" && grep -Fq '候補の採否、修正・却下判断、検証はすべて上位モデル' "$UNWIND_SKILL" && ok "unwind はnesting候補抽出だけを下位モデルへ限定" || ng "unwind の限定QA・判断責務分離が無い"
[ -x "$QUALITY_GATE_SCRIPT" ] && bash -n "$QUALITY_GATE_SCRIPT" && grep -Fq 'quality-gate.sh <機能名> -- <実変更path>...' "$POLISH_SKILL" && ! grep -Eq 'record|verify|HEAD.*receipt' "$QUALITY_GATE_SCRIPT" && ok "polish の単回path検査器が有効" || ng "polish の単回path検査器が不正"
[ -x "$CAPTURE_SCOPE_SCRIPT" ] && bash -n "$CAPTURE_SCOPE_SCRIPT" && [ -x "$IMPLEMENTER_PREFLIGHT_SCRIPT" ] && grep -Fq 'capture-scope.sh <機能名> --auto' "$TDD_SKILL" && grep -Fq 'preflight-implementer.sh [agent_name]' "$SCENARIO_FLOW" && grep -Fq 'capture-scope.sh list-changed <機能名>' "$TDD_SKILL" && ! grep -Eq 'capture-scope.sh (status|activate|recover-to-parent|handoff-to-parent|deactivate)' "$TDD_SKILL" "$SCENARIO_FLOW" "$ERRAND_SKILL" && ok "tddとerrandは自動baselineと実変更pathだけを使う" || ng "tdd/errandにactive implementation scopeが残存"
! grep -Fq 'validate-implementation-request.sh' "$TDD_SKILL" "$SCENARIO_FLOW" "$ERRAND_SKILL" && ! grep -Fq 'implementer-read.sh' "$TDD_SKILL" "$SCENARIO_FLOW" "$ERRAND_SKILL" && ! grep -Fq 'allowed_paths' "$TDD_SKILL" "$SCENARIO_FLOW" "$ERRAND_SKILL" && ok "tddとerrandはartifact validator・quoted reader・exact許可pathに依存しない" || ng "tdd/errandに過剰な実装制御が残存"
grep -Fq 'quality-gate.sh <機能名> -- <実変更path>...' "$POLISH_SKILL" && grep -Fq '現在の入力pathを「基準commitから実際に変更され、現在存在するfile」の一覧と順序込みで完全一致' "$POLISH_SKILL" && grep -Fq '入力された実変更pathだけが追跡済みかつclean' "$POLISH_SKILL" && grep -Fq '完了receiptの記録や後続での再検証は行わない' "$POLISH_SKILL" && grep -Fq '独自のESLint rule、`no-magic-numbers`、import規則を追加しない' "$POLISH_SKILL" && ! grep -Eq 'eslint|no-magic-numbers|no-restricted-syntax' "$QUALITY_GATE_SCRIPT" && ok "polish は実変更path一致とtracked・cleanだけを単回検査" || ng "polish の実変更path検査が不正"
grep -Fq '**verified**' "$POLISH_SKILL" && grep -Fq '**direct**' "$POLISH_SKILL" && grep -Fq 'receipt欠落は呼び出し元の状態遷移不備として停止し、directへ降格しない' "$POLISH_SKILL" && grep -Fq 'Prettier / ESLintだけの独自フォールバックへ置き換えない' "$POLISH_SKILL" && grep -Fq 'quality-gate.sh <機能名> --direct-check -- <明示path>...' "$POLISH_SKILL" && grep -Fq 'quality-gate.sh <機能名> --direct -- <明示path>...' "$POLISH_SKILL" && grep -Fq 'scope-unverified' "$POLISH_SKILL" "$REPO/README.md" && grep -Fq -- '--direct-check' "$QUALITY_GATE_SCRIPT" && grep -Fq -- '--direct' "$QUALITY_GATE_SCRIPT" && ok "polish はverifiedとdirectの保証差を明示" || ng "polish のverified/direct mode契約が不正"
! grep -Fq 'quality-gate.sh' "$MARK_PROMPT_DONE_SCRIPT" && grep -Fq '完了マークを付けるか明示的に確認する' "$TDD_SKILL" && grep -Fq 'ユーザーが付けると回答した場合だけ' "$TDD_SKILL" && ok "tdd はユーザー判断だけでindexを更新" || ng "tdd が完了マークを自動判定"
grep -Fq 'SCENARIO_FLOW.md' "$TDD_SKILL" && grep -Fq '../tdd/SCENARIO_FLOW.md' "$ERRAND_SKILL" && [ -f "$SCENARIO_FLOW" ] && [ -f "$REVIEW_FLOW" ] && grep -Fq '`tdd`と`errand`は、調査後の実装をこの契約へ集約する' "$SCENARIO_FLOW" && grep -Fq 'REVIEW_FLOW.md' "$SCENARIO_FLOW" "$POLISH_SKILL" "$UNWIND_SKILL" && ok "tdd・errand・polish・unwindはレビュー・再実装契約を共有" || ng "共通実装・レビューフロー参照が不正"
grep -Fq '[agent_name]が次を直接調査する' "$TDD_SKILL" && grep -Fq '外部workerへ調査を委任しない' "$TDD_SKILL" && ! grep -Fq 'worker/delegate.sh' "$TDD_SKILL" && grep -Fq 'native implementer' "$TDD_SKILL" && grep -Fq '初回実装後の小さい本体コード修正 | 可 | 禁止' "$TDD_SKILL" && grep -Fq '初回実装後の大きい本体コード再実装 | 2回連続失敗時だけ可 | 可' "$TDD_SKILL" && ok "tdd は上位モデル調査・判断と下位モデル初回・再実装へ固定" || ng "tdd の調査・実装・修正境界が不正"
grep -Fq '## 0. [agent_name]が直接調査する' "$SCENARIO_FLOW" && grep -Fq 'path:line' "$SCENARIO_FLOW" && grep -Fq '必須事実が不足する場合は[agent_name]が追加調査' "$SCENARIO_FLOW" && grep -Fq '下位モデル、surveyor subagent、外部workerへ調査を委任しない' "$SCENARIO_FLOW" && ok "共通フローは上位モデルの直接調査へ固定" || ng "共通フローの直接調査境界が不正"
grep -Fq '## 1. テストシナリオ候補をまとめて提示する' "$SCENARIO_FLOW" && grep -Fq '採用するシナリオ、外すシナリオ、修正点を指定してください。' "$SCENARIO_FLOW" && grep -Fq '全件採用を既定または要求する言い方をしない' "$SCENARIO_FLOW" && grep -Fq 'どの候補を採用・不採用・修正するかはユーザーが決める' "$SCENARIO_FLOW" && grep -Fq '実装要件を省略する根拠にしてはならない' "$SCENARIO_FLOW" && grep -Fq '選択が確定するまでファイルを変更しない' "$SCENARIO_FLOW" && grep -Fq '新しいテストが必要であることだけを理由に停止しない' "$SCENARIO_FLOW" && grep -Fq '`fork_turns: "none"`' "$SCENARIO_FLOW" && grep -Fq '`reasoning_effort: "max"`' "$SCENARIO_FLOW" && grep -Fq 'child agent IDが空' "$SCENARIO_FLOW" && grep -Fq 'wait先が空' "$SCENARIO_FLOW" && ok "共通フローはtest選択権・実装範囲・freshなimplementerを固定" || ng "共通フローのtest選択権・実装境界またはimplementer起動が不正"
grep -Fq '半年後に負債にならないかを必ずレビュー' "$SCENARIO_FLOW" && grep -Fq '関数ジャンプ' "$SCENARIO_FLOW" && grep -Fq 'YAGNI' "$SCENARIO_FLOW" && grep -Fq '`filter().map()`' "$SCENARIO_FLOW" && grep -Fq '`reduce()`' "$SCENARIO_FLOW" && grep -Fq '多少冗長でも局所的に理解できる' "$SCENARIO_FLOW" && ok "上位モデルは半年後の負債と可読性を必須レビュー" || ng "上位モデルの保守性・可読性レビュー契約が不足"
grep -Fq '次の条件をすべて満たす場合だけ小さい問題' "$REVIEW_FLOW" && grep -Fq '変更行数が10行以下' "$REVIEW_FLOW" && grep -Fq '次の条件を一つでも満たす場合は大きい問題' "$REVIEW_FLOW" && grep -Fq '変更先が2ファイル以上、または変更行数が11行以上' "$REVIEW_FLOW" && grep -Fq '1行の条件反転でも' "$REVIEW_FLOW" && grep -Fq '2回連続' "$REVIEW_FLOW" && grep -Fq '最終レビュー' "$REVIEW_FLOW" && ok "レビュー契約は大小判定・2回失敗fallback・最終レビューを固定" || ng "レビュー・再実装契約が不足"
grep -Fq 'Green、formatter、lint、polish、本体コードのcommitより先に' "$SCENARIO_FLOW" && grep -Fq '次の3項目だけを簡潔に報告する' "$SCENARIO_FLOW" && grep -Fq '採用:' "$SCENARIO_FLOW" && grep -Fq '問題:' "$SCENARIO_FLOW" && grep -Fq '修正主体:' "$SCENARIO_FLOW" && grep -Fq 'コードの再掲、作業手順、内部推論は報告しない' "$SCENARIO_FLOW" && ok "上位モデルは実装差分の評価と修正主体を後続処理前に簡潔に報告" || ng "上位モデルの実装差分レビュー報告契約が不足"
grep -Fq '次のtest除外pathだけの変更では対応test/specの作成・実行とRed / Greenを要求せず' "$SCENARIO_FLOW" && grep -Fq 'basenameが`constants.ts`または`constants.js`' "$SCENARIO_FLOW" && grep -Fq '`constants/`配下' "$SCENARIO_FLOW" && grep -Fq 'その挙動だけを通常どおりシナリオ、Red、Greenの対象' "$SCENARIO_FLOW" && ok "共通フローはschema・定数のtest除外境界を固定" || ng "共通フローのschema・定数test除外境界が不正"
grep -Fq '`.jsx` / `.tsx` componentとReact hookには、そのためだけの隣接unit testを新設しない' "$SCENARIO_FLOW" && grep -Fq '`.jsx` / `.tsx` componentとReact hookは隣接unit testの必須対象外' "$REPO/rules/typescript/tdd-pattern.md" && grep -Fq '*/hooks/*|*/use[A-Z]*.ts' "$REPO/hooks/shell/require-test.sh" && ok "componentとReact hookはunit test必須対象外" || ng "componentまたはReact hookのtest除外が不正"
grep -Fq '`target-test`、`direct-regression`、`typecheck`、`schema`' "$SCENARIO_FLOW" && grep -Fq '無関係なpackageのtestやproject全体のtestを追加しない' "$SCENARIO_FLOW" && grep -Fq '`tsc -p <tsconfig> --noEmit`' "$SCENARIO_FLOW" && grep -Fq 'Prisma `format`、`validate`、`generate`' "$SCENARIO_FLOW" && ok "共通フローは調査commandと最終検証の範囲を固定" || ng "共通フローの調査commandまたは最終検証が曖昧"
grep -Fq '`scope-related`' "$SCENARIO_FLOW" && grep -Fq '`unrelated`' "$SCENARIO_FLOW" && grep -Fq '`uncertain`' "$SCENARIO_FLOW" && grep -Fq 'ignored / untracked test' "$SCENARIO_FLOW" && grep -Fq '対象外の失敗だけでタスクを未完了と決めない' "$ERRAND_SKILL" && grep -Fq 'どの分類もユーザーの完了マーク判断を代行しない' "$POLISH_SKILL" && grep -Fq 'どの分類が残っていても完了マークを自動判定せず' "$SCENARIO_FLOW" && ok "tdd・errand・polishは対象外失敗と完了判断を分離" || ng "対象外失敗がタスク完了を自動阻止"
grep -Fq 'この出力と完全一致する相対path全件を一括入力' "$POLISH_SKILL" && grep -Fq 'directory、glob、`git diff`で独自に広げたpathを使わない' "$POLISH_SKILL" && grep -Fq 'typecheck・build・Prisma検証はファイル単位で安全に分割できない' "$POLISH_SKILL" && grep -Fq '実変更pathだけを渡して`unwind`を必ず呼ぶ' "$POLISH_SKILL" && grep -Fq '`unwind`自身では差分を再探索・再検証しない' "$UNWIND_SKILL" && grep -Fq '`list-changed`をもう一度実行しない' "$POLISH_SKILL" && ok "polishとunwindは実変更pathを再探索せず対象化" || ng "polishまたはunwindが実変更pathを再探索"
grep -Fq 'packageに`build` scriptあり' "$POLISH_SKILL" && grep -Fq 'packageで`yarn build`' "$POLISH_SKILL" && grep -Fq '`build` scriptがないpackageのbuild commandは推測・発明しない' "$POLISH_SKILL" && grep -Fq '親の`polish`が実行した同じpackageのbuildを再実行する' "$UNWIND_SKILL" && grep -Fq '新しいbuild commandを発明しない' "$UNWIND_SKILL" && ok "polishは所属packageをbuildしunwind修正後に同じbuildを再検証" || ng "polishまたはunwindのbuild検証契約が不正"
grep -Fq 'Skill(polish)' "$TDD_SKILL" && grep -Fq 'この出力にある実変更pathだけをまとめて`polish`へ渡し' "$TDD_SKILL" && grep -Fq 'bash [skills_root]/tdd/mark-prompt-done.sh <機能名>' "$TDD_SKILL" && ok "tdd は実変更pathのpolish後だけindexを更新" || ng "tdd のpolish対象または品質ゲートが不正"
grep -Fq 'capture-scope.sh <機能名> --auto' "$TDD_SKILL" && grep -Fq 'native implementer起動直前に次を1回実行' "$TDD_SKILL" && ok "tdd はRed後の基準commitから実変更pathを自動列挙" || ng "tdd の自動baselineが不正"
grep -Fq 'ファイルごとには呼ばない' "$TDD_SKILL" && grep -Fq 'formatterがformat差分を自動修正' "$POLISH_SKILL" && grep -Fq '`REVIEW_FLOW.md`で大小判定' "$POLISH_SKILL" && grep -Fq 'どちらが修正しても全品質ゲートを再実行' "$POLISH_SKILL" && ok "tdd はpolishを全path一括で原因別に反復" || ng "tdd のpolish実行単位または反復条件が不正"

echo "== 2. claude 配置シミュレーション =="
mkdir -p "$S/claude-sim/.claude"
cp "$REPO/AGENTS.md" "$S/claude-sim/"
cp -R "$REPO/hooks" "$S/claude-sim/.claude/hooks"
cp -R "$REPO/skills" "$S/claude-sim/.claude/skills"
cp -R "$REPO/rules" "$S/claude-sim/.claude/rules"
cp -R "$REPO/claude/agents" "$S/claude-sim/.claude/agents"
cd "$S/claude-sim"
git init -q
git config user.email tester@example.com
git config user.name tester
git commit --allow-empty -qm "test: 品質ゲートfixtureを初期化"
touch SOURCE_REPOSITORY.md
if bash .claude/skills/bootstrap/init-agent.sh claude > init-source.log 2>&1; then
  ng "bootstrap は配布元での実行を拒否"
else
  ok "bootstrap は配布元での実行を拒否"
fi
[ -d .claude/skills/bootstrap ] && ok "bootstrap は失敗時に残る" || ng "bootstrap が失敗時に消えた"
rm SOURCE_REPOSITORY.md
mkdir -p "$S/bootstrap-failing-bin"
printf '%s\n' '#!/bin/bash' 'exit 2' > "$S/bootstrap-failing-bin/grep"
chmod +x "$S/bootstrap-failing-bin/grep"
if PATH="$S/bootstrap-failing-bin:$PATH" bash .claude/skills/bootstrap/init-agent.sh claude > init-search-failure.log 2>&1; then
  ng "bootstrap は探索失敗を拒否"
else
  ok "bootstrap は探索失敗を拒否"
fi
[ -d .claude/skills/bootstrap ] && ok "bootstrap は探索失敗後も再試行可能" || ng "bootstrap が探索失敗後に消えた"
printf '%s\n' '[NOTE]: bootstrap 対象' 'broken' > .claude/broken-bootstrap.sh
if bash .claude/skills/bootstrap/init-agent.sh claude > init-failure.log 2>&1; then
  ng "bootstrap は未解決NOTEを拒否"
else
  ok "bootstrap は未解決NOTEを拒否"
fi
[ -d .claude/skills/bootstrap ] && ok "bootstrap は処理失敗後も再試行可能" || ng "bootstrap が処理失敗後に消えた"
rm .claude/broken-bootstrap.sh
if bash .claude/skills/bootstrap/init-agent.sh claude > init-claude.log 2>&1; then ok "bootstrap claude 実行"; else ng "bootstrap claude 実行"; cat init-claude.log; fi
[ ! -e .claude/skills/bootstrap ] && ok "bootstrap claude は成功後に自己削除" || ng "bootstrap claude が成功後に残った"
[ -f .claude/skills/tdd/SKILL.md ] && ok "bootstrap claude は他skillを保持" || ng "bootstrap claude が他skillを削除"
[ -f .claude/agents/implementer.md ] && grep -q '^model: claude-sonnet-5$' .claude/agents/implementer.md && grep -q '^effort: max$' .claude/agents/implementer.md && ok "bootstrap claude はimplementer定義を保持" || ng "bootstrap claude のimplementer定義が不正"
if bash .claude/skills/tdd/preflight-implementer.sh claude >/dev/null 2>&1; then ok "Claude implementer preflight: 正常配置を受理"; else ng "Claude implementer preflight: 正常配置を拒否"; fi
mv .claude/agents/implementer.md .claude/agents/implementer.md.missing
if ! bash .claude/skills/tdd/preflight-implementer.sh claude > claude-implementer-missing.out 2>&1 && grep -Fq 'Claude implementer設定が無い' claude-implementer-missing.out; then ok "Claude implementer preflight: agent設定欠落を起動前に拒否"; else ng "Claude implementer preflight: agent設定欠落を見逃す"; fi
mv .claude/agents/implementer.md.missing .claude/agents/implementer.md
bash -n .claude/hooks/shell/require-test.sh 2>/dev/null && ok "解決後 require-test 構文" || ng "解決後 require-test 構文"
grep -q 'HOOK_AGENT="claude"' .claude/hooks/shell/hook-io.sh && ok "hook-io HOOK_AGENT=claude" || ng "hook-io HOOK_AGENT=claude"
if ! grep -q '\[\[agent_name\]\]' AGENTS.md && \
   [ "$(bash .claude/hooks/shell/commit-subject.sh --prefix foo.ts)" = "foo.ts: " ] && \
   bash .claude/hooks/shell/commit-subject.sh --validate 'feature: 日本語の説明' && \
   ! bash .claude/hooks/shell/commit-subject.sh --validate 'feature: english only' && \
   grep -q 'COMMIT_MESSAGE_CONTRACT=.*\.claude/hooks/shell/commit-subject.sh' .claude/skills/rebase/rebase.sh; then
  ok "commit-message契約をhookが一元生成・検証"
else
  ng "commit-message契約のhook一元化が不正"
fi
grep -q 'bash .claude/skills/rebase/rebase.sh' .claude/skills/rebase/SKILL.md && ok "[skills_root]→.claude/skills" || ng "[skills_root]→.claude/skills"
LEFT=$(command grep -rlE '\[agent_name\]|\[skills_root\]' AGENTS.md .claude 2>/dev/null | grep -v '/bootstrap/' | wc -l | tr -d ' ')
[ "$LEFT" = "0" ] && ok "置換漏れゼロ(claude)" || { ng "置換漏れ $LEFT 件(claude)"; command grep -rlE '\[agent_name\]|\[skills_root\]' AGENTS.md .claude | grep -v '/bootstrap/'; }

echo "== 2.5 cowlick / tdd の設計書フロー（claude 配置） =="
MD=".claude/skills/tdd/mark-prompt-done.sh"
QG=".claude/skills/polish/quality-gate.sh"
CS=".claude/skills/polish/capture-scope.sh"
mkdir -p .claude/prompt
printf '# 実装順\n\n- [ ] branch-user-api-prompt.md\n- [ ] branch-user-form-prompt.md\n' > .claude/prompt/.prompt.md
echo api > .claude/prompt/branch-user-api-prompt.md
echo form > .claude/prompt/branch-user-form-prompt.md
if [ -f .claude/prompt/.prompt.md ] && [ -f .claude/prompt/branch-user-api-prompt.md ] && [ -f .claude/prompt/branch-user-form-prompt.md ]; then
  ok "cowlick: 設計書をprompt正本へ直接作成"
else
  ng "cowlick: prompt正本への作成漏れ"
fi
[ ! -e .claude/skills/cowlick/apply-prompt.sh ] && ok "cowlick: 旧設計反映scriptを配布しない" || ng "cowlick: 旧設計反映scriptが残存"
printf -- '- [ ] branch-billing-prompt.md\n' > .claude/prompt/.prompt.md
echo billing > .claude/prompt/branch-billing-prompt.md
rm -f .claude/prompt/branch-user-api-prompt.md .claude/prompt/branch-user-form-prompt.md

mkdir -p src
printf 'export function legacyNumber() { return 99 }\n' > src/rules.ts
printf 'export const untouched = true\n' > src/untouched.ts
git add src/rules.ts src/untouched.ts
git commit -qm "test: scope path fixtureを追加"
if bash "$CS" billing -- src/rules.ts src/untouched.ts src/planned.ts > quality-begin.out 2>&1; then ok "polish-scope: 基準commitと候補pathを固定"; else ng "polish-scope: 変更前scopeを記録できない"; cat quality-begin.out; fi
if bash "$CS" native-auto --auto > native-auto-begin.out 2>&1; then
  printf 'export function legacyNumber() { return 100 }\n' > src/rules.ts
  printf 'export const discoveredDuringImplementation = true\n' > src/discovered.ts
  git add src/rules.ts src/discovered.ts
  git commit -qm "test: native subagentの実変更fixtureを追加"
  NATIVE_CHANGED_PATHS=$(bash "$CS" list-changed native-auto)
  if [ "$NATIVE_CHANGED_PATHS" = "src/discovered.ts
src/rules.ts" ]; then ok "polish-scope: 事前許可pathなしで実変更fileを自動列挙"; else ng "polish-scope: auto baselineの実変更列挙が不正 [$NATIVE_CHANGED_PATHS]"; fi
else
  ng "polish-scope: auto baselineを記録できない"; cat native-auto-begin.out
fi
if [ ! -e .claude/skills/tdd/validate-implementation-request.sh ] && [ ! -e .claude/skills/tdd/implementer-read.sh ] && [ ! -e .claude/hooks/shell/protect-implementation-scope.sh ] && [ ! -e .claude/skills/polish/implementation-scope-state.sh ]; then
  ok "旧調査artifact・quoted reader・exact実装scopeを配布しない"
else
  ng "旧実装委任資産がClaude配置へ残存"
fi
if bash "$CS" directory-scope -- src > quality-directory.out 2>&1; then ng "polish-scope: directory指定を通した"; else ok "polish-scope: 個別file以外を拒否"; fi
if bash "$CS" glob-scope -- 'src/*.ts' > quality-glob.out 2>&1; then ng "polish-scope: pathspec globを通した"; else ok "polish-scope: pathspec globを拒否"; fi
mkdir -p front/features/mypage/routes/contract/pages
BRACKET_PATH='front/features/mypage/routes/contract/pages/-.[number]._index.tsx'
printf 'export const page = 1\n' > "$BRACKET_PATH"
git add "$BRACKET_PATH"
git commit -qm "test: literal pathspec fixtureを追加"
if bash "$CS" literal-brackets -- "$BRACKET_PATH" > literal-brackets-begin.out 2>&1; then
  printf 'export const page = 2\n' > "$BRACKET_PATH"
  git add "$BRACKET_PATH"
  git commit -qm "test: literal pathspec fixtureを更新"
  [ "$(bash "$CS" list-changed literal-brackets)" = "$BRACKET_PATH" ] && ok "polish-scope: 角括弧を含むliteral pathを固定・列挙" || ng "polish-scope: 角括弧を含むliteral pathを列挙できない"
else
  ng "polish-scope: 角括弧を含むliteral pathを固定できない"; cat literal-brackets-begin.out
fi
if bash "$CS" untracked -- src/untracked.ts > quality-untracked-begin.out 2>&1; then
  printf 'export const untracked = true\n' > src/untracked.ts
  if bash "$QG" untracked -- src/untracked.ts > quality-untracked.out 2>&1; then ng "polish-paths: 未追跡の新規fileを通した"; else ok "polish-paths: 未追跡の新規fileを拒否"; fi
  rm -f src/untracked.ts
else
  ng "polish-scope: 新規fileのscopeを固定できない"; cat quality-untracked-begin.out
fi
printf 'import legacy from "../../legacy"\nexport function legacyNumber() { return 99 }\nexport function errorCode() { return 404 }\n' > src/rules.ts
git add src/rules.ts
git commit -qm "test: エラーコードを含むpath fixtureへ更新"
CHANGED_PATHS=$(bash "$CS" list-changed billing)
[ "$CHANGED_PATHS" = "src/rules.ts" ] && ok "polish-scope: 未変更・未使用候補を除外して実変更pathだけ列挙" || ng "polish-scope: 実変更path selectorが不正 [$CHANGED_PATHS]"
if bash "$CS" unchanged -- src/untouched.ts src/planned-empty.ts > quality-empty-begin.out 2>&1 &&
   [ -z "$(bash "$CS" list-changed unchanged)" ] &&
   bash "$QG" unchanged -- > quality-empty.out 2>&1; then
  ok "polish-scope: 実変更pathが空なら空入力を検証"
else
  ng "polish-scope: 空の実変更pathを扱えない"
fi
if bash "$QG" billing -- > quality-before-polish.out 2>&1; then ng "quality-gate: 実変更pathの空入力を通した"; else ok "quality-gate: 実変更pathとの完全一致を強制"; fi
if bash "$QG" billing -- src/rules.ts src/untouched.ts src/planned.ts > quality-broad.out 2>&1; then ng "polish-paths: 開始scope全件を通した"; else ok "polish-paths: 開始scope全件を拒否"; fi
if bash "$QG" billing -- src/other.ts > quality-mismatch.out 2>&1; then ng "polish-paths: scopeと異なる入力pathを通した"; else ok "polish-paths: 入力pathの完全一致を強制"; fi
printf '\n// dirty\n' >> src/rules.ts
if bash "$QG" billing -- src/rules.ts > quality-dirty.out 2>&1; then ng "quality-gate: dirtyな実変更pathを通した"; else ok "quality-gate: dirtyな実変更pathを拒否"; fi
printf 'import legacy from "../../legacy"\nexport function legacyNumber() { return 99 }\nexport function errorCode() { return 404 }\n' > src/rules.ts
if bash "$QG" billing -- src/rules.ts > quality-gate.out 2>&1; then ok "quality-gate: 実変更path一致とtracked・cleanだけを検査"; else ng "quality-gate: 最小path検査に失敗"; cat quality-gate.out; fi
printf 'export const direct = true\n' > src/direct.ts
if bash "$QG" direct-fix --direct-check -- src/direct.ts > direct-check.out 2>&1 && \
   grep -Fq 'validated-direct: direct-fix scope-unverified' direct-check.out && \
   ! bash "$QG" direct-fix --direct -- src/direct.ts > direct-untracked.out 2>&1; then
  ok "quality-gate direct: 未追跡の明示fileを事前検査し最終gateでは拒否"
else
  ng "quality-gate directの事前検査または未追跡拒否が不正"; cat direct-check.out direct-untracked.out
fi
git add src/direct.ts
git commit -qm "test: direct polish fixtureを追加"
if bash "$QG" direct-fix --direct -- src/direct.ts > direct-clean.out 2>&1 && \
   grep -Fq 'checked-direct: direct-fix scope-unverified' direct-clean.out; then
  ok "quality-gate direct: receiptなしで明示pathのtracked・cleanを検査"
else
  ng "quality-gate directのtracked・clean検査が不正"; cat direct-clean.out
fi
if bash "$QG" direct-fix --direct-check -- > direct-empty.out 2>&1; then
  ng "quality-gate direct: 空の明示pathを許可"
elif bash "$QG" direct-fix --direct-check -- src/direct.ts src/direct.ts > direct-duplicate.out 2>&1; then
  ng "quality-gate direct: 重複pathを許可"
elif bash "$QG" direct-fix --direct-check -- src > direct-directory.out 2>&1; then
  ng "quality-gate direct: directoryを許可"
else
  ok "quality-gate direct: 空入力・重複・directoryを拒否"
fi
if bash "$QG" missing-receipt -- src/direct.ts > verified-missing.out 2>&1; then
  ng "quality-gate verified: receipt欠落をdirectへ暗黙降格"
elif grep -Fq 'polish対象の開始receiptが無い: missing-receipt' verified-missing.out; then
  ok "quality-gate verified: receipt欠落時もdirectへ暗黙降格しない"
else
  ng "quality-gate verifiedのreceipt欠落診断が不正"; cat verified-missing.out
fi
bash "$MD" billing > mark.out 2>&1
grep -qE '^\- \[x\] branch-billing-prompt\.md$' .claude/prompt/.prompt.md && ok "mark-prompt-done: index を [x] に倒す" || { ng "mark-prompt-done: [x] に倒せない"; cat mark.out; }
grep -q '^remaining: 0$' mark.out && ok "mark-prompt-done: 残件数を報告" || { ng "mark-prompt-done: 残件数の報告が無い"; cat mark.out; }
if bash "$MD" billing > mark2.out 2>&1; then ng "mark-prompt-done: 二重マークを通した"; else ok "mark-prompt-done: 二重マークを拒否"; fi
if bash "$MD" "../../etc/passwd" > mark3.out 2>&1; then ng "mark-prompt-done: 不正な機能名を通した"; else ok "mark-prompt-done: 不正な機能名を拒否"; fi
if bash "$MD" nonexistent > mark4.out 2>&1; then ng "mark-prompt-done: 未登録の機能名を通した"; else ok "mark-prompt-done: 未登録の機能名を拒否"; fi
rm -rf .claude/prompt

echo "== 2.75 workerの限定QA回帰（外部通信なし） =="
DELEGATE_REPO="$S/delegate-nesting"
DELEGATE_BIN="$DELEGATE_REPO/bin"
DELEGATE_SCRIPT="$DELEGATE_REPO/.claude/skills/worker/delegate.sh"
DELEGATE_TIMEOUT_REASON='scope=changed-production-paths,difficulty=low,basis=mechanical-nesting-qa'
DELEGATE_TIMEOUT_ARGS=(--hard-timeout-minutes 4 --idle-timeout-seconds 120 --poll-seconds 5 --timeout-reason "$DELEGATE_TIMEOUT_REASON")
mkdir -p "$DELEGATE_BIN" "$(dirname "$DELEGATE_SCRIPT")" "$DELEGATE_REPO/src"
cp .claude/skills/worker/delegate.sh "$DELEGATE_SCRIPT"
printf '#!/bin/bash\n[ -z "${CURL_CALL_MARKER:-}" ] || : > "$CURL_CALL_MARKER"\nprintf '\''{"data":{"usage_monthly":0,"usage":0,"limit":40,"limit_reset":"monthly"}}\\n'\''\n' > "$DELEGATE_BIN/curl"
printf '%s\n' \
  '#!/bin/bash' \
  'jq -e '\''.permission.edit["*"] == "deny" and (.permission.bash == "deny" or .permission.bash["*"] == "deny") and .permission.external_directory == "deny"'\'' "$OPENCODE_CONFIG" >/dev/null || exit 40' \
  'last="${!#}"' \
  'if [ "$last" = "hello" ]; then jq -cn --arg text hello '\''{type:"text",text:$text}'\''; exit; fi' \
  '[ -f src/subject.ts ] || exit 41' \
  '[ ! -e .claude ] || exit 42' \
  '[ "$(find . -type f | wc -l | tr -d " ")" = "1" ] || exit 43' \
  'text='\''Outcome: fulfilled
## Claims
### C1
Status: fulfilled
Claim: src/subject.tsに三段階の制御フローネストがある
Evidence:
- `src/subject.ts:1-7`
Interpretation: if、for、ifが同じ実行経路で深さ3になる
Limitations: none
## Remaining
none'\''' \
  'jq -cn --arg text "$text" '\''{type:"text",text:$text}'\''' \
  > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/curl" "$DELEGATE_BIN/opencode"
cd "$DELEGATE_REPO"
git init -q
git config user.email tester@example.com
git config user.name tester
printf '%s\n' 'export function subject(items: number[]) {' '  if (items.length > 0) {' '    for (const item of items) {' '      if (item > 0) {' '        return item' '      }' '    }' '  }' '  return 0' '}' > src/subject.ts
git add src/subject.ts
git commit -qm "test: nesting fixture"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" smoke > delegate-smoke.out 2>&1 && grep -Fq 'smoke: ok model=openrouter/minimax/minimax-m3 variant=default' delegate-smoke.out; then
  ok "delegate-openrouter: 固定helloでsmokeを完了"
else
  ng "delegate-openrouter: smokeが不正"; cat delegate-smoke.out
fi
CURL_CALL_MARKER="$DELEGATE_REPO/research-curl-called"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test CURL_CALL_MARKER="$CURL_CALL_MARKER" bash "$DELEGATE_SCRIPT" research > delegate-research-mode.out 2>&1; then
  ng "delegate-worker: research modeを許可"
elif grep -Fq 'research and survey modes were removed; lower models are limited to bounded QA' delegate-research-mode.out && [ ! -e "$CURL_CALL_MARKER" ]; then
  ok "delegate-worker: researchを外部通信前に拒否"
else
  ng "delegate-worker: researchの拒否境界が不正"; cat delegate-research-mode.out
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test CURL_CALL_MARKER="$CURL_CALL_MARKER" bash "$DELEGATE_SCRIPT" survey > delegate-survey-mode.out 2>&1; then
  ng "delegate-worker: survey modeを許可"
elif grep -Fq 'research and survey modes were removed; lower models are limited to bounded QA' delegate-survey-mode.out && [ ! -e "$CURL_CALL_MARKER" ]; then
  ok "delegate-worker: surveyを外部通信前に拒否"
else
  ng "delegate-worker: surveyの拒否境界が不正"; cat delegate-survey-mode.out
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" implement > delegate-implement-mode.out 2>&1; then
  ng "delegate-worker: implement modeを許可"
elif grep -Fq 'mode must be nesting, prepare, smoke, or show' delegate-implement-mode.out; then
  ok "delegate-worker: nesting以外の作業modeを拒否"
else
  ng "delegate-worker: 不正modeの拒否理由が不正"; cat delegate-implement-mode.out
fi
BEFORE_NESTING_TREE=$(git rev-parse 'HEAD^{tree}')
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" nesting "${DELEGATE_TIMEOUT_ARGS[@]}" nesting-check src/subject.ts > delegate-nesting.out 2>&1; then
  ok "delegate-worker: nestingは追跡済み本体コードを読み取り検出"
else
  ng "delegate-worker: nestingが失敗"; cat delegate-nesting.out
fi
NESTING_RESULT="$DELEGATE_REPO/.claude/tmp/worker/nesting-check/result.json"
if [ -f "$NESTING_RESULT" ] && [ "$(jq -r '.mode' "$NESTING_RESULT")" = "nesting" ] && [ "$(jq -r '.status' "$NESTING_RESULT")" = "0" ] && [ "$(jq -c '.changed_paths' "$NESTING_RESULT")" = "[]" ] && [ "$(jq -c '.context_snapshot_paths' "$NESTING_RESULT")" = "[]" ] && grep -Fq 'src/subject.tsに三段階' "$DELEGATE_REPO/.claude/tmp/worker/nesting-check/report.md" && [ "$(git rev-parse 'HEAD^{tree}')" = "$BEFORE_NESTING_TREE" ]; then
  ok "delegate-worker: 指定pathのnesting結果を変更なしで保存"
else
  ng "delegate-worker: nestingのresultまたは読み取り専用境界が不正"
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" nesting "${DELEGATE_TIMEOUT_ARGS[@]}" nesting-test-path src/subject.test.ts > delegate-test-path.out 2>&1; then
  ng "delegate-worker: test pathをnesting対象に許可"
elif grep -Fq 'test assets cannot be inspected for nesting' delegate-test-path.out; then
  ok "delegate-worker: nesting対象を追跡済みproduction codeへ限定"
else
  ng "delegate-worker: nesting対象pathの拒否理由が不正"; cat delegate-test-path.out
fi
echo "== 3. hook 全数テスト（claude 配置） =="
cp "$SUITE/run-tests.sh" "$S/claude-sim/run-tests.sh"
bash "$S/claude-sim/run-tests.sh" > hook-tests.out 2>&1
tail -3 hook-tests.out
grep -q '^PASS=[0-9]* FAIL=0$' hook-tests.out && ok "hook 全数テスト全緑" || { ng "hook 全数テストに失敗あり"; grep '^FAIL' hook-tests.out; }

echo "== 4. rebase E2E =="
RS="$S/claude-sim/.claude/skills/rebase/rebase.sh"
mkdir -p "$S/rs/.claude"
cp -R "$S/claude-sim/.claude/hooks" "$S/rs/.claude/"
cd "$S/rs"
git init -q && git config user.email tester@example.com && git config user.name tester
echo base > base.txt && git add base.txt && git commit -qm "chore: base"
echo 1 > f1.ts && git add f1.ts && git commit -qm "f1.ts: f1を追加した"
echo 2 > f1.test.ts && git add f1.test.ts && git commit -qm "f1.test.ts: f1のテストを追加した"
echo 3 > f2.ts && git add f2.ts && git commit -qm "f2.ts: f2を追加した"
BASE=$(git rev-parse HEAD~3)
if bash "$RS" --check --base "$BASE" > check.out 2>&1; then ok "--check 成功"; else ng "--check 失敗"; cat check.out; fi
grep -q "COMMITS 3" check.out && ok "対象3件を認識" || ng "対象件数が不正"
grep -q '^SUBJECT_FORMAT ' check.out && ok "subject形式をcheck結果へ出力" || ng "subject形式の出力が無い"
EB=$(grep '^BASE ' check.out | cut -d' ' -f2)
C1=$(git rev-parse HEAD~2); C2=$(git rev-parse HEAD~1); C3=$(git rev-parse HEAD)
TREE_BEFORE=$(git rev-parse 'HEAD^{tree}')
if bash "$RS" --base "$BASE" \
  --group 'f1: f1と対応テストを追加した' "${C1:0:8},${C2:0:8}" \
  --group 'f2.ts: f2を追加した' "${C3:0:8}" > run.out 2>&1; then
  ok "scratch plan無しでsquash実行"
else
  ng "squash 失敗"; cat run.out
fi
[ "$(git rev-list --count "$EB..HEAD")" = "2" ] && ok "3→2 コミットへ縮約" || ng "コミット数が不正"
[ "$(git rev-parse 'HEAD^{tree}')" = "$TREE_BEFORE" ] && ok "tree 同一性" || ng "tree が変わった"
git branch --list 'backup/rebase-*' | grep -q . && ng "backup ブランチが残っている" || ok "成功時に backup ブランチを残さない"
git reflog show HEAD --format=%H | grep -qFx "$C3" && ok "元 HEAD を reflog から辿れる" || ng "元 HEAD が reflog から失われた"
grep -q "$C3" run.out && ok "報告に元 HEAD の sha を含む" || { ng "元 HEAD の sha を報告していない"; cat run.out; }
if bash "$RS" --base "$BASE" --group '再実行: 対象が古い' "${C1:0:8},${C2:0:8},${C3:0:8}" > again.out 2>&1; then ng "古いgroupが通ってしまった"; else ok "古いgroupを拒否"; fi
if bash "$RS" --base "$(git rev-parse 'HEAD~1')" --group 'タグ無し不正subject' "$(git rev-parse --short=8 HEAD)" > bad.out 2>&1; then ng "不正 subject が通ってしまった"; else ok "不正 subject を拒否"; fi
echo 4 > f3.ts && git add f3.ts && git commit -qm "manual change"
echo 5 > f4.ts && git add f4.ts && git commit -qm "f4.ts: f4を追加した"
bash "$RS" --check --base "$BASE" > b2.out 2>&1
grep -q "COMMITS 1" b2.out && ok "非タグコミットを境界として認識" || { ng "境界判定が不正"; cat b2.out; }

echo "== 5. codex 配置シミュレーション（skills は .agents/skills） =="
mkdir -p "$S/codex-sim/.codex" "$S/codex-sim/.agents"
cp "$REPO/AGENTS.md" "$S/codex-sim/"
cp "$REPO/codex/config.toml" "$S/codex-sim/.codex/"
cp "$REPO/codex/hooks.json" "$S/codex-sim/.codex/"
cp "$REPO/codex/.gitignore" "$S/codex-sim/.codex/"
cp -R "$REPO/codex/agents" "$S/codex-sim/.codex/agents"
cp -R "$REPO/hooks" "$S/codex-sim/.codex/hooks"
cp -R "$REPO/rules" "$S/codex-sim/.codex/rules"
cp "$REPO/codex/rules/default.rules" "$S/codex-sim/.codex/rules/"
cp -R "$REPO/prompt" "$S/codex-sim/.codex/prompt"
cp -R "$REPO/e2e" "$S/codex-sim/.codex/e2e"
cp -R "$REPO/skills" "$S/codex-sim/.agents/skills"
cd "$S/codex-sim"
git init -q
if bash .agents/skills/bootstrap/init-agent.sh codex > init-codex.log 2>&1; then ok "bootstrap codex 実行"; else ng "bootstrap codex 実行"; cat init-codex.log; fi
[ ! -e .agents/skills/bootstrap ] && ok "bootstrap codex は成功後に自己削除" || ng "bootstrap codex が成功後に残った"
[ -f .agents/skills/tdd/SKILL.md ] && ok "bootstrap codex は他skillを保持" || ng "bootstrap codex が他skillを削除"
[ -f .codex/agents/implementer.toml ] && grep -q '^model = "gpt-5.6-luna"$' .codex/agents/implementer.toml && grep -q '^model_reasoning_effort = "max"$' .codex/agents/implementer.toml && ok "bootstrap codex はimplementer定義を保持" || ng "bootstrap codex のimplementer定義が不正"
if bash .agents/skills/tdd/preflight-implementer.sh codex >/dev/null 2>&1; then ok "Codex implementer preflight: 正常配置を受理"; else ng "Codex implementer preflight: 正常配置を拒否"; fi
mv .codex/agents/implementer.toml .codex/agents/implementer.toml.missing
if ! bash .agents/skills/tdd/preflight-implementer.sh codex > codex-implementer-missing.out 2>&1 && grep -Fq 'Codex implementer設定が無い' codex-implementer-missing.out; then ok "Codex implementer preflight: agent設定欠落を起動前に拒否"; else ng "Codex implementer preflight: agent設定欠落を見逃す"; fi
mv .codex/agents/implementer.toml.missing .codex/agents/implementer.toml
if ! grep -q '^default_subagent_model' .codex/config.toml && ! grep -q '^default_subagent_reasoning_effort' .codex/config.toml; then
  ok "bootstrap codex はgeneric subagentを下位モデルへ固定しない"
else
  ng "bootstrap codex にgeneric subagentの下位モデル既定が残存"
fi
git config user.email tester@example.com
git config user.name tester
mkdir -p src
printf 'export const codexImplementation = true\n' > src/codex-implementation.ts
printf 'export const codexUntouched = true\n' > src/codex-untouched.ts
git add src/codex-implementation.ts src/codex-untouched.ts
git commit -qm "test: Codex implementation scope fixture"
if [ ! -e .agents/skills/tdd/validate-implementation-request.sh ] && [ ! -e .agents/skills/tdd/implementer-read.sh ] && [ ! -e .codex/hooks/shell/protect-implementation-scope.sh ] && [ ! -e .agents/skills/polish/implementation-scope-state.sh ]; then
  ok "旧実装委任資産をCodex配置へ残さない"
else
  ng "旧実装委任資産がCodex配置へ残存"
fi
if [ "$(bash .codex/hooks/shell/commit-subject.sh --prefix foo.ts)" = "foo.ts: " ] && \
   bash .codex/hooks/shell/commit-subject.sh --validate 'feature: 日本語の説明' && \
   ! bash .codex/hooks/shell/commit-subject.sh --validate 'feature: english only'; then
  ok "commit-message契約をCodex hookが一元生成・検証"
else
  ng "commit-message契約のCodex hook一元化が不正"
fi
grep -q 'HOOK_AGENT="codex"' .codex/hooks/shell/hook-io.sh && ok "hook-io HOOK_AGENT=codex" || ng "hook-io HOOK_AGENT=codex"
grep -q '"\$TOOL" = "apply_patch"' .codex/hooks/shell/require-test.sh && ok "[NOTE]→apply_patch" || ng "[NOTE]→apply_patch"
grep -q 'bash .agents/skills/rebase/rebase.sh' .agents/skills/rebase/SKILL.md && ok "[skills_root]→.agents/skills" || ng "[skills_root]→.agents/skills"
grep -q 'COMMIT_MESSAGE_CONTRACT=.*\.codex/hooks/shell/commit-subject.sh' .agents/skills/rebase/rebase.sh && ok "rebase はCodex hook契約を参照" || ng "rebase のCodex hook契約参照が無い"
LEFT=$(command grep -rlE '\[agent_name\]|\[skills_root\]' AGENTS.md .codex .agents 2>/dev/null | grep -v '/bootstrap/' | wc -l | tr -d ' ')
[ "$LEFT" = "0" ] && ok "置換漏れゼロ(codex)" || { ng "置換漏れ $LEFT 件(codex)"; command grep -rlE '\[agent_name\]|\[skills_root\]' AGENTS.md .codex .agents | grep -v '/bootstrap/'; }
printf 'codex e2e plan\n' > "$S/e2e-plan.md"
if bash .agents/skills/e2e/apply-e2e-plan.sh "$S/e2e-plan.md" > apply-e2e.out 2>&1 && grep -q '^codex e2e plan$' .codex/e2e/.e2e.md; then
  ok "e2e plan を固定宛先へ反映"
else
  ng "e2e plan の固定宛先反映に失敗"
  cat apply-e2e.out
fi
grep -q '^hooks = true$' .codex/config.toml && ok "config: hooks を明示有効化" || ng "config: hooks が未設定"
[ "$(jq '[.hooks.PreToolUse[] | select(.matcher == "^Bash$") | .hooks[].command | select(contains("readonly-search.sh"))] | length' .codex/hooks.json)" = "1" ] && ok "codex: 読み取り検索の正規化hookをBashへ配線" || ng "codex: 読み取り検索の正規化hookが未配線"
[ "$(jq '[.hooks.PermissionRequest[] | select(.matcher == "^Bash$") | .hooks[].command | select(contains("readonly-search.sh"))] | length' .codex/hooks.json)" = "1" ] && ok "codex: 安全な読み取りの承認省略hookをBashへ配線" || ng "codex: 読み取り承認省略hookが未配線"
READONLY_PERMISSION_COMMAND='rg -n "requirements\.phone|requirements\.message|karadenResult\.status|console\.log\(filterRes|userId|prefix: \"karaden/\"" lambda/karaden/index.ts'
READONLY_PERMISSION_OUT=$(jq -cn --arg cwd "$PWD" --arg command "$READONLY_PERMISSION_COMMAND" '{hook_event_name:"PermissionRequest",session_id:"CREAD1",cwd:$cwd,tool_name:"Bash",tool_input:{command:$command,description:"opaque shell"}}' | bash .codex/hooks/shell/readonly-search.sh)
[ "$(printf '%s' "$READONLY_PERMISSION_OUT" | jq -r '.hookSpecificOutput.decision.behavior' 2>/dev/null)" = "allow" ] && ok "codex: quoteを含む単一rgの承認表示を省略" || ng "codex: 単一rgの承認省略失敗 out=[$READONLY_PERMISSION_OUT]"
GLOB_PERMISSION_OUT=$(jq -cn --arg cwd "$PWD" --arg command 'rg --files src -g *.ts' '{hook_event_name:"PermissionRequest",session_id:"CREADGLOB",cwd:$cwd,tool_name:"Bash",tool_input:{command:$command,description:"opaque wildcard shell"}}' | bash .codex/hooks/shell/readonly-search.sh)
[ "$(printf '%s' "$GLOB_PERMISSION_OUT" | jq -r '.hookSpecificOutput.decision.behavior' 2>/dev/null)" = "allow" ] && ok "codex: 読み取りglobを含む単一commandの承認表示を省略" || ng "codex: 読み取りglobの承認省略失敗 out=[$GLOB_PERMISSION_OUT]"
WRITER_GLOB_PERMISSION_OUT=$(jq -cn --arg cwd "$PWD" --arg command 'rm src/*.ts' '{hook_event_name:"PermissionRequest",session_id:"CWRITEGLOB",cwd:$cwd,tool_name:"Bash",tool_input:{command:$command,description:"opaque wildcard shell"}}' | bash .codex/hooks/shell/readonly-search.sh)
[ -z "$WRITER_GLOB_PERMISSION_OUT" ] && ok "codex: 書き込みglobの承認判断へ介入しない" || ng "codex: 書き込みglobを誤って自動許可 out=[$WRITER_GLOB_PERMISSION_OUT]"
UNSAFE_PERMISSION_OUT=$(jq -cn --arg cwd "$PWD" '{hook_event_name:"PermissionRequest",session_id:"CREAD2",cwd:$cwd,tool_name:"Bash",tool_input:{command:"rg foo src | sort",description:"opaque shell"}}' | bash .codex/hooks/shell/readonly-search.sh)
[ -z "$UNSAFE_PERMISSION_OUT" ] && ok "codex: 複合shellの承認判断へ介入しない" || ng "codex: 複合shellを誤って自動許可 out=[$UNSAFE_PERMISSION_OUT]"
! grep -Fq 'normalize_default_delegate_model' .codex/hooks/shell/readonly-search.sh && ! grep -Fq 'DELEGATE_MODEL=openrouter/minimax/minimax-m3' .codex/hooks/shell/readonly-search.sh && ok "codex: worker commandを書き換えない" || ng "codex: 旧worker model正規化が残存"
grep -q '^default_permissions = "distributed"$' .codex/config.toml && ok "config: distributed permission profile を既定化" || ng "config: permission profile が未設定"
grep -q '^extends = ":workspace"$' .codex/config.toml && ok "permissions: 通常ファイルは workspace write を継承" || ng "permissions: 通常書き込みが未設定"
grep -q '^enabled = false$' .codex/config.toml && grep -q '^allow_local_binding = false$' .codex/config.toml && ok "permissions: localhost を含む network を遮断" || ng "permissions: network 境界が未設定"
if grep -qE '^(sandbox_mode|\[sandbox_workspace_write\])' .codex/config.toml; then
  ng "config: permission profile と旧 sandbox_mode が混在"
else
  ok "config: 旧 sandbox_mode との混在なし"
fi
if grep -qE '^"\*\*/.*" = "(read|write)"$' .codex/config.toml; then
  ng "permissions: Codex が拒否する任意階層 read/write glob が残存"
else
  ok "permissions: 任意階層 read/write glob なし"
fi
if grep -q '@latest' .codex/config.toml || \
   { grep 'git+https://' .codex/config.toml | grep -vqE "@[0-9a-f]{$GIT_COMMIT_HEX_LENGTH}"; } || \
   ! grep -q 'chrome-devtools-mcp@[0-9]' .codex/config.toml; then
  ng "config: MCP に未固定バージョンが残存"
else
  ok "config: MCP 起動バージョンを全件固定"
fi
CM="$REPO/claude/.mcp.json"
CODEX_SERENA_SOURCE=$(awk -F'"' '/"--from", "git\+https:\/\/github.com\/oraios\/serena@/ { print $4 }' .codex/config.toml)
CLAUDE_SERENA_SOURCE=$(jq -r '.mcpServers.serena.args[1] // empty' "$CM" 2>/dev/null)
if printf '%s\n' "$CODEX_SERENA_SOURCE" | grep -qE "$PINNED_SERENA_SOURCE_PATTERN" && [ "$CLAUDE_SERENA_SOURCE" = "$CODEX_SERENA_SOURCE" ]; then
  ok "serena: Claude/Codex は同じcommitを固定"
else
  ng "serena: Claude/Codex の固定commitが不正または不一致"
fi
if jq -e --arg source "$CODEX_SERENA_SOURCE" '
  .mcpServers.serena.type == "stdio" and
  .mcpServers.serena.command == "uvx" and
  .mcpServers.serena.args == ["--from", $source, "serena", "start-mcp-server", "--context", "claude-code", "--project-from-cwd"]
' "$CM" >/dev/null 2>&1; then
  ok "serena: Claude Code contextでcurrent projectを起動"
else
  ng "serena: Claude MCP起動設定が不正"
fi
GROUP_FAILURES=
for DISABLED_TOOL in "${SERENA_CODE_MUTATION_TOOLS[@]}"; do
  grep -q "\"$DISABLED_TOOL\"" .codex/config.toml || append_group_failure "$DISABLED_TOOL"
done
report_group "serena: code変更toolを全件無効化" "$GROUP_FAILURES"
grep -q '"replace_regex"' .codex/config.toml && ng "serena: 廃止済みreplace_regexが残存" || ok "serena: 廃止済みtool名なし"
for MCP_SERVER in serena chrome-devtools; do
  GROUP_FAILURES=
  if [ "$MCP_SERVER" = "serena" ]; then
    mcp_server_approves_by_default "$MCP_SERVER" .codex/config.toml || append_group_failure "全toolの既定値がapproveではない"
    CONFIGURED_COUNT=$(awk -v prefix="[mcp_servers.$MCP_SERVER.tools." 'index($0, prefix) == 1 { count++ } END { print count + 0 }' .codex/config.toml)
    [ "$CONFIGURED_COUNT" = "0" ] || append_group_failure "不要なper-tool approveが残存"
    report_group "$MCP_SERVER: 全有効toolを自動承認" "$GROUP_FAILURES"
    continue
  fi
  mcp_server_prompts_by_default "$MCP_SERVER" .codex/config.toml || append_group_failure "未登録toolの既定値がpromptではない"
  APPROVED_COUNT=0
  while IFS= read -r MCP_TOOL; do
    APPROVED_COUNT=$((APPROVED_COUNT+1))
    mcp_tool_approved "$MCP_SERVER" "$MCP_TOOL" .codex/config.toml || append_group_failure "approve漏れ: $MCP_TOOL"
  done < <(jq -r --arg prefix "mcp__${MCP_SERVER}__" '.permissions.allow[] | select(startswith($prefix)) | ltrimstr($prefix)' "$REPO/claude/settings.local.json")
  CONFIGURED_COUNT=$(grep -c "^\[mcp_servers\.$MCP_SERVER\.tools\." .codex/config.toml)
  [ "$CONFIGURED_COUNT" = "$APPROVED_COUNT" ] || append_group_failure "allow一覧外のapprove混入"
  report_group "$MCP_SERVER: approval境界" "$GROUP_FAILURES"
done
[ -f .codex/prompt/.prompt.md ] && [ -f .codex/e2e/.e2e.md ] && ok "codex seed 配置" || ng "codex seed 配置漏れ"
jq -e . .codex/hooks.json >/dev/null 2>&1 && ok "hooks.json 構文" || ng "hooks.json 構文"
jq -e '[.hooks[][] | .hooks[] | has("timeout")] | all' .codex/hooks.json >/dev/null 2>&1 && ok "hook timeout 全件設定" || ng "hook timeout 設定漏れ"
GROUP_FAILURES=
for SCRIPT in protect-config.sh protect-locks.sh protect-review.sh; do
  BINDING_COUNT=$(jq --arg script "$SCRIPT" '[.hooks.PreToolUse[] | .hooks[].command | select(contains($script))] | length' .codex/hooks.json)
  [ "$BINDING_COUNT" = "$EXPECTED_DUAL_HOOK_BINDINGS" ] || append_group_failure "$SCRIPT: $BINDING_COUNT bindings"
done
report_group "保護hookを apply_patch/Bash の両方へ配線" "$GROUP_FAILURES"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("load-required-contract.sh"))] | length' .codex/hooks.json)" = "$EXPECTED_DUAL_HOOK_BINDINGS" ] && ok "必須契約hookを apply_patch/Bash の両方へ配線" || ng "必須契約hookの配線漏れ"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("protect-implementation-scope.sh"))] | length' .codex/hooks.json)" = "0" ] && ok "Codexはexact実装scope hookを配線しない" || ng "Codexにexact実装scope hookが残存"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("require-test.sh"))] | length' .codex/hooks.json)" = "0" ] && ok "Codexはsession marker依存のtest hookを配線しない" || ng "Codexにsession marker依存のtest hookが残存"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("deny-migration.sh"))] | length' .codex/hooks.json)" = "1" ] && ok "migration禁止hookをBashへ配線" || ng "migration禁止hookの配線漏れ"
if jq -e '[.hooks.PreToolUse[] | .hooks[].command | select(contains("overwrite.sh"))] | length == 0' .codex/hooks.json >/dev/null; then
  ok "未対応 ask hook を codex へ未配線"
else
  ng "未対応 ask hook が codex に配線されている"
fi
MISSING_HOOKS=0
for SCRIPT in $(jq -r '.hooks[][] | .hooks[].command' .codex/hooks.json | sed -nE 's|.*\.codex/hooks/shell/([^"/]+).*|\1|p' | sort -u); do
  [ -x ".codex/hooks/shell/$SCRIPT" ] || { ng "hook 参照先が存在しない: $SCRIPT"; MISSING_HOOKS=1; }
done
[ "$MISSING_HOOKS" = "0" ] && ok "hook 参照先が全件実行可能"
echo "== 5.25 codex config / rules 実機検査 =="
if command -v codex >/dev/null 2>&1; then
  CODEX_VERSION=$(codex --version | awk '{print $2}')
  if version_at_least "$CODEX_VERSION" "$MIN_SUPPORTED_CODEX_VERSION"; then
    ok "codex $CODEX_VERSION は最低version $MIN_SUPPORTED_CODEX_VERSION 以上"
  else
    ng "codex $CODEX_VERSION は非対応（$MIN_SUPPORTED_CODEX_VERSION 以上が必要）"
  fi
  mkdir -p "$S/codex-home"
  printf '[projects."%s"]\ntrust_level = "trusted"\n' "$PWD" > "$S/codex-home/config.toml"
  if printf '' | CODEX_HOME="$S/codex-home" codex -C "$PWD" app-server --strict-config --listen stdio:// > codex-config.out 2>&1; then
    ok "codex --strict-config で配布設定を読込"
  else
    ng "codex --strict-config で配布設定を読めない"
    cat codex-config.out
  fi
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- rm -rf tmp/example 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "prompt" ] && ok "rules: rm を prompt" || ng "rules: rm 判定失敗 out=[$OUT]"
  GROUP_FAILURES=
  for WRITER_COMMAND in "${FILESYSTEM_WRITER_COMMANDS[@]}"; do
    OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- "$WRITER_COMMAND" target 2>/dev/null)
    [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "prompt" ] || append_group_failure "$WRITER_COMMAND: $OUT"
  done
  report_group "rules: filesystem writerをprompt" "$GROUP_FAILURES"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- mkdir -p prompt-work 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.matchedRules | length' 2>/dev/null)" = "0" ] && ok "rules: sandbox内mkdirは承認対象外" || ng "rules: mkdirが承認対象 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- git push origin main 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "forbidden" ] && ok "rules: git push を forbidden" || ng "rules: push 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- git add src/example.ts 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: git add を allow" || ng "rules: git add 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- git commit -m message 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: git commit を allow" || ng "rules: git commit 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- git status --short 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.matchedRules | length' 2>/dev/null)" = "0" ] && ok "rules: git status は未制限" || ng "rules: git status 誤検出 out=[$OUT]"
  GROUP_FAILURES=
  for READ_COMMAND in cat find nl sort rg; do
    OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- "$READ_COMMAND" target 2>/dev/null)
    [ "$(echo "$OUT" | jq -r '.matchedRules | length' 2>/dev/null)" = "0" ] || append_group_failure "$READ_COMMAND: $OUT"
  done
  report_group "rules: 単一読み取りcommandは未制限" "$GROUP_FAILURES"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- ps -p "$$" -o pid=,stat=,etime=,command= 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: ps -p のprocess状態確認をallow" || ng "rules: ps -p 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- ps aux 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.matchedRules | length' 2>/dev/null)" = "0" ] && ok "rules: ps -p 以外へ許可を拡張しない" || ng "rules: ps の許可範囲が過剰 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- zsh -lc 'echo x > output.txt' 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "prompt" ] && ok "rules: opaque shell を prompt" || ng "rules: opaque shell 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/bootstrap/init-agent.sh codex 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: bootstrap の固定経路を allow" || ng "rules: bootstrap 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/e2e/apply-e2e-plan.sh "$S/e2e-plan.md" 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: e2e plan の固定経路を allow" || ng "rules: e2e plan 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/tdd/mark-prompt-done.sh user-api 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: mark-prompt-done の固定経路を allow" || ng "rules: mark-prompt-done 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/polish/quality-gate.sh user-api -- src/example.ts 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: quality-gate の固定経路を allow" || ng "rules: quality-gate 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/polish/capture-scope.sh user-api -- src/example.ts 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: polish scope記録の固定経路を allow" || ng "rules: polish scope記録判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/worker/delegate.sh nesting --hard-timeout-minutes 10 --idle-timeout-seconds 120 --poll-seconds 10 --timeout-reason scope=changed-production-paths,difficulty=low,basis=mechanical-nesting-qa nesting-abc123def456 src/example.ts 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: nesting限定QAの固定経路を allow" || ng "rules: nesting worker判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/worker/delegate.sh research task-id spec.md 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" != "allow" ] && ok "rules: research委任をallowしない" || ng "rules: research委任を許可 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/worker/delegate.sh smoke 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.matchedRules | length' 2>/dev/null)" = "0" ] && ok "rules: 課金smokeを自動許可しない" || ng "rules: worker smokeを誤許可 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- ./base/scripts/run-unit.sh test/features/purchase/unit/device-discount-utils.test.ts test/features/purchase/unit/purchase-api.integration.test.ts 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: 承認済みunit test runnerを allow" || ng "rules: unit test runner判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- yarn eslint --ext .ts,.js,.tsx features/mypage/resources/contract/components/ContractSecurityOptionForm.tsx 'features/mypage/routes/contract/pages/-.[number].option.security.add._index.tsx' 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: local ESLintを allow" || ng "rules: local ESLint判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash ./base/scripts/run-unit.sh test/features/purchase/unit/device-discount-utils.test.ts 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.matchedRules | length' 2>/dev/null)" = "0" ] && ok "rules: unit test runnerのallowを別起動形式へ拡張しない" || ng "rules: unit test runner許可が過剰 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/rebase/rebase.sh --check 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: rebase事前確認をallow" || ng "rules: rebase事前確認判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/rebase/rebase.sh --group 'feature: 日本語の説明' abc1234,def5678 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: rebase group実行をallow" || ng "rules: rebase group実行判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .codex/hooks/shell/protect-review.sh approve apps/api/infra/main.tf 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "prompt" ] && ok "rules: review対象の変更承認を prompt" || ng "rules: review対象の承認判定失敗 out=[$OUT]"
else
  echo "skip codex CLI が無いため config / rules 実機検査を省略"
fi

echo "== 5.5 session marker と発火スコープ（codex） =="
H=.codex/hooks/shell
UP=$(jq -n --arg cwd "$PWD" '{hook_event_name:"UserPromptSubmit",session_id:"SESS1",cwd:$cwd,prompt:"$tdd",model:"m",permission_mode:"default",transcript_path:null,turn_id:"t"}')
echo "$UP" | bash $H/session.sh
[ -f .codex/tmp/session.tdd.SESS1 ] && ok "session: \$tdd 起動で marker 記録" || ng "session: marker 記録失敗"
UPE=$(jq -n --arg cwd "$PWD" '{hook_event_name:"UserPromptSubmit",session_id:"ERR1",cwd:$cwd,prompt:"$errand boolean変更を実装して",model:"m",permission_mode:"default",transcript_path:null,turn_id:"t"}')
echo "$UPE" | bash $H/session.sh
[ -f .codex/tmp/session.errand.ERR1 ] && ok "session: \$errand 起動で marker 記録" || ng "session: errand marker 記録失敗"
UP2=$(jq -n --arg cwd "$PWD" '{hook_event_name:"UserPromptSubmit",session_id:"SESS9",cwd:$cwd,prompt:"tdd について教えて",model:"m",permission_mode:"default",transcript_path:null,turn_id:"t"}')
echo "$UP2" | bash $H/session.sh
[ ! -f .codex/tmp/session.tdd.SESS9 ] && ok "session: \$ 無しの言及では発火しない" || ng "session: 誤発火"
UPE2=$(jq -n --arg cwd "$PWD" '{hook_event_name:"UserPromptSubmit",session_id:"ERR9",cwd:$cwd,prompt:"errand について教えて",model:"m",permission_mode:"default",transcript_path:null,turn_id:"t"}')
echo "$UPE2" | bash $H/session.sh
[ ! -f .codex/tmp/session.errand.ERR9 ] && ok "session: \$ 無しのerrand言及では発火しない" || ng "session: errand誤発火"
UPM=$(jq -n --arg cwd "$PWD" '{hook_event_name:"UserPromptSubmit",session_id:"MEET1",cwd:$cwd,prompt:"$meeting 新機能を設計して",model:"m",permission_mode:"default",transcript_path:null,turn_id:"t"}')
echo "$UPM" | bash $H/session.sh
COWLICK_PATCH=$(jq -n --arg cwd "$PWD" '{session_id:"MEET1",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: .codex/prompt/branch-sample-prompt.md\n+x\n*** End Patch"}}')
COWLICK_LOAD=$(echo "$COWLICK_PATCH" | bash $H/load-required-contract.sh)
if [ "$(echo "$COWLICK_LOAD" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && echo "$COWLICK_LOAD" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -Fq '## Changes'; then
  ok "required-reading: Codex meetingの初回prompt編集で設計形式を注入"
else
  ng "required-reading: Codex meetingで設計形式を注入できない"
fi
[ -z "$(echo "$COWLICK_PATCH" | bash $H/load-required-contract.sh)" ] && ok "required-reading: Codex設計形式receipt後は棄権" || ng "required-reading: Codex設計形式receiptを再利用できない"
AP=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",turn_id:"t1",transcript_path:"/tmp/x.jsonl",cwd:$cwd,hook_event_name:"PreToolUse",model:"gpt-5.5",permission_mode:"bypassPermissions",tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: src/foo.ts\n+x\n*** End Patch\n"},tool_use_id:"call_x"}')
OUT=$(echo "$AP" | bash $H/require-test.sh)
[ "$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && ok "require-test: marker 一致で執行(実機同形ペイロード)" || ng "require-test: marker 一致 out=[$OUT]"
APERR=$(jq -n --arg cwd "$PWD" '{session_id:"ERR1",turn_id:"t1",transcript_path:"/tmp/x.jsonl",cwd:$cwd,hook_event_name:"PreToolUse",model:"gpt-5.5",permission_mode:"bypassPermissions",tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: src/errand.ts\n+x\n*** End Patch\n"},tool_use_id:"call_errand"}')
OUTERR=$(echo "$APERR" | bash $H/require-test.sh)
[ "$(echo "$OUTERR" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && ok "require-test: errand markerでもテスト先行を執行" || ng "require-test: errand markerで未テスト実装を許可 out=[$OUTERR]"
APMD=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: README.md\n+x\n*** End Patch"}}')
[ -z "$(echo "$APMD" | bash $H/require-test.sh)" ] && ok "require-test: md のみのパッチは棄権" || ng "require-test: md が棄権されない"
APCOMPONENT=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: src/view.tsx\n+x\n*** Update File: src/view.jsx\n+y\n*** Update File: src/useDevice.ts\n+z\n*** Update File: src/hooks/use-device.ts\n+w\n*** End Patch"}}')
[ -z "$(echo "$APCOMPONENT" | bash $H/require-test.sh)" ] && ok "require-test: jsx・tsx・React hookは明示除外" || ng "require-test: componentまたはReact hookを誤拒否"
APPRISMA=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: front/prisma/schema.prisma\n+x\n*** End Patch"}}')
[ -z "$(echo "$APPRISMA" | bash $H/require-test.sh)" ] && ok "require-test: schema.prisma は明示除外" || ng "require-test: schema.prisma を誤拒否"
APPRISMA_TS=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: front/prisma/schema.prisma\n+x\n*** Add File: src/schema-change.ts\n+y\n*** End Patch"}}')
[ "$(echo "$APPRISMA_TS" | bash $H/require-test.sh | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && ok "require-test: schema.prisma と未テストtsの混在を deny" || ng "require-test: schema例外がtsへ漏れた"
APMX=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: a.md\n+x\n*** Add File: src/bar.ts\n+y\n*** End Patch"}}')
[ "$(echo "$APMX" | bash $H/require-test.sh | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && ok "require-test: 複数ファイルパッチの一部違反を deny" || ng "require-test: 複数ファイル検査漏れ"
APB=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"echo hi"}}')
[ -z "$(echo "$APB" | bash $H/require-test.sh)" ] && ok "require-test: Bash は棄権" || ng "require-test: Bash"
AP2=$(jq -n --arg cwd "$PWD" '{session_id:"SESS2",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: src/foo.ts\n+x\n*** End Patch"}}')
[ -z "$(echo "$AP2" | bash $H/require-test.sh)" ] && ok "require-test: 別セッションの marker では発火しない" || ng "require-test: 残骸で発火"
rm -f .codex/tmp/session.tdd.SESS1
[ -z "$(echo "$AP" | bash $H/require-test.sh)" ] && ok "require-test: marker 無しは棄権" || ng "require-test: marker 無しで発火"
SE=$(jq -n --arg cwd "$PWD" '{hook_event_name:"SessionEnd",session_id:"SESS1",cwd:$cwd}')
echo "$SE" | bash $H/session.sh
[ ! -f .codex/tmp/session.tdd.SESS1 ] && ok "session: SessionEnd で自セッションの marker を掃除" || ng "session: 掃除漏れ"
SEERR=$(jq -n --arg cwd "$PWD" '{hook_event_name:"SessionEnd",session_id:"ERR1",cwd:$cwd}')
echo "$SEERR" | bash $H/session.sh
[ ! -f .codex/tmp/session.errand.ERR1 ] && ok "session: SessionEnd でerrand markerを掃除" || ng "session: errand marker掃除漏れ"
if ! grep -Fq 'implementation.active' "$H/session.sh" && ! grep -Fq 'protect-implementation-scope.sh' "$H/session.sh"; then
  ok "session hookは旧implementation scopeを管理しない"
else
  ng "session hookに旧implementation scope管理が残存"
fi
PG=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: .git/config\n+x\n*** End Patch"}}')
[ "$(echo "$PG" | bash $H/protect-git.sh | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && ok "protect-git: パッチ経由の .git 書き込みを deny" || ng "protect-git: apply_patch 素通し"
PE=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: .env\n+X=1\n*** End Patch"}}')
[ "$(echo "$PE" | bash $H/protect-env.sh | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && ok "protect-env: パッチ経由の .env 書き込みを deny" || ng "protect-env: apply_patch 素通し"
PE2=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: config/.env.production\n+X=1\n*** End Patch"}}')
[ "$(echo "$PE2" | bash $H/protect-env.sh | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && ok "protect-env: .env.production も deny" || ng "protect-env: variant 素通し"
PE3=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: src/env.ts\n+x\n*** End Patch"}}')
[ -z "$(echo "$PE3" | bash $H/protect-env.sh)" ] && ok "protect-env: env.ts は棄権(誤爆なし)" || ng "protect-env: env.ts 誤爆"
PL=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: yarn.lock\n+x\n*** End Patch"}}')
[ "$(echo "$PL" | bash $H/protect-locks.sh | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && ok "protect-locks: Codex apply_patch を deny" || ng "protect-locks: Codex apply_patch 素通し"
PRF=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: apps/api/infra/main.tf\n+x\n*** End Patch"}}')
[ "$(echo "$PRF" | bash $H/protect-review.sh | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && ok "protect-review: 未承認の Terraform を deny" || ng "protect-review: 未承認の Terraform が素通し"
if bash $H/protect-review.sh approve apps/api/infra/main.tf >/dev/null 2>&1 && [ -z "$(echo "$PRF" | bash $H/protect-review.sh)" ]; then
  ok "protect-review: 承認済みの変更を1回だけ許可"
else
  ng "protect-review: 承認済みの変更を許可できない"
fi
[ "$(echo "$PRF" | bash $H/protect-review.sh | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && ok "protect-review: 承認を再利用させない" || ng "protect-review: 承認tokenが再利用できる"
if bash $H/protect-review.sh approve ../outside/main.tf >/dev/null 2>&1; then ng "protect-review: repository外pathを承認"; else ok "protect-review: repository外pathを拒否"; fi
PRF_READ=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"cat apps/api/infra/main.tf"}}')
[ -z "$(echo "$PRF_READ" | bash $H/protect-review.sh)" ] && ok "protect-review: 読み取りは許可" || ng "protect-review: 読み取りを誤拒否"
PRISMA_EDIT=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: front/prisma/schema.prisma\n+x\n*** End Patch"}}')
[ -z "$(echo "$PRISMA_EDIT" | bash $H/protect-review.sh)" ] && ok "protect-review: schema.prisma編集は承認不要" || ng "protect-review: schema.prismaを誤拒否"
PAC=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: .codex/config.toml\n+x\n*** End Patch"}}')
[ "$(echo "$PAC" | bash $H/protect-config.sh | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && ok "protect-config: .codex patch を deny" || ng "protect-config: .codex patch 素通し"
PROMPT_PATCH=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: .codex/prompt/branch-sample-prompt.md\n+x\n*** End Patch"}}')
[ -z "$(echo "$PROMPT_PATCH" | bash $H/protect-config.sh)" ] && ok "protect-config: .codex/prompt patch は許可" || ng "protect-config: .codex/prompt patch を誤拒否"
PAC2=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: .agents/skills/e2e/SKILL.md\n+x\n*** End Patch"}}')
[ "$(echo "$PAC2" | bash $H/protect-config.sh | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && ok "protect-config: .agents patch を deny" || ng "protect-config: .agents patch 素通し"
echo x > codex-untracked.txt
GO=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",cwd:$cwd,tool_name:"Write",tool_input:{file_path:($cwd + "/codex-untracked.txt")}}')
[ "$(echo "$GO" | bash $H/overwrite.sh | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && ok "hook-io: codex の未対応 ask は deny" || ng "hook-io: codex ask が fail-open"

echo "== 6. テンプレート残渣チェック =="
command grep -rn "allowed-tools:.*Shell" "$REPO/skills" >/dev/null 2>&1 && ng "allowed-tools に Shell が残存" || ok "allowed-tools: Shell 残存なし"
command grep -rn "hookSpecificOutput" "$REPO/hooks/shell" 2>/dev/null | grep -v hook-io.sh | grep -q . && ng "hook-io 以外にスキーマ直書き" || ok "スキーマ直書きは hook-io のみ"
command grep -rn '\[claude\]' "$REPO/skills" "$REPO/hooks" "$REPO/AGENTS.md" 2>/dev/null | grep -q . && { ng "[claude] 直書き残存"; command grep -rn '\[claude\]' "$REPO/skills" "$REPO/hooks" "$REPO/AGENTS.md"; } || ok "[claude] 直書きゼロ"
find "$REPO/hooks" "$REPO/skills" "$REPO/rules" -type f -iname '*claude*' | grep -q . && { ng "共有ファイル名に製品名が残存"; find "$REPO/hooks" "$REPO/skills" "$REPO/rules" -type f -iname '*claude*'; } || ok "共有ファイル名は製品非依存"
command grep -rnE "$LEGACY_HOOK_NAME|$LEGACY_TEST_LABEL" "$REPO" --exclude-dir=.git 2>/dev/null | grep -q . && ng "旧commit hook名が残存" || ok "旧commit hook名の残存なし"

echo "== 7. 承認プロンプト回避の設定検査 =="
# Claude Code の Bash 照合はコマンド文字列そのままで行われ、末尾 ` *` / `:*` は
# 「スペース + 何か」を要求する。引数なしで呼ぶスクリプトをワイルドカード形だけで
# 登録すると一致せず承認プロンプトが復活するため、両形の登録を必須にする。
SJ="$REPO/claude/settings.json"; SL="$REPO/claude/settings.local.json"
GROUP_FAILURES=
for JSON_CONFIG in "$SJ" "$SL" "$CM"; do
  jq -e . "$JSON_CONFIG" >/dev/null 2>&1 || append_group_failure "$JSON_CONFIG"
done
report_group "Claude JSON設定の構文" "$GROUP_FAILURES"
jq -e '.sandbox.failIfUnavailable == true and .sandbox.autoAllowBashIfSandboxed == false and .sandbox.network.allowLocalBinding == false and (.sandbox.network.allowedDomains | length == 0)' "$SJ" >/dev/null 2>&1 && ok "Claude sandbox はfail-closedかつnetwork自動許可なし" || ng "Claude sandbox境界が不正"
jq -e '.permissions.allow | index("WebFetch(domain:localhost)") | not' "$SL" >/dev/null 2>&1 && ok "Claude localhost WebFetch 自動許可なし" || ng "Claude localhost WebFetch が自動許可"
if jq -e '.sandbox.excludedCommands | (index("bash .claude/skills/worker/delegate.sh nesting") != null and index("bash .claude/skills/worker/delegate.sh nesting *") != null)' "$SJ" >/dev/null 2>&1 && jq -e '.permissions.allow | (index("Bash(bash .claude/skills/worker/delegate.sh nesting)") != null and index("Bash(bash .claude/skills/worker/delegate.sh nesting:*)") != null)' "$SL" >/dev/null 2>&1; then
  ok "Claude: nesting限定QAだけを自動許可"
else
  ng "Claude: nesting限定QAの許可が不足"
fi
if ! jq -e '.permissions.allow[] | select(test("delegate\\.sh (research|survey)"))' "$SL" >/dev/null 2>&1 && ! jq -e '.sandbox.excludedCommands[] | select(test("delegate\\.sh (research|survey)"))' "$SJ" >/dev/null 2>&1; then
  ok "Claude: research / survey委任を自動許可しない"
else
  ng "Claude: research / survey委任の許可が残存"
fi
GROUP_FAILURES=
for READ_PERMISSION in "${CLAUDE_SAFE_READ_PERMISSIONS[@]}"; do
  jq -e --arg permission "$READ_PERMISSION" '.permissions.allow | index($permission)' "$SL" >/dev/null 2>&1 || append_group_failure "$READ_PERMISSION"
done
report_group "Claude: 単一読み取りcommandをallow" "$GROUP_FAILURES"
GROUP_FAILURES=
for WRITER_COMMAND in "${FILESYSTEM_WRITER_COMMANDS[@]}"; do
  WRITER_PERMISSION="Bash($WRITER_COMMAND:*)"
  jq -e --arg permission "$WRITER_PERMISSION" '.permissions.ask | index($permission)' "$SL" >/dev/null 2>&1 || append_group_failure "$WRITER_PERMISSION"
done
report_group "Claude: filesystem writerをask" "$GROUP_FAILURES"
jq -e '.permissions.allow | index("Bash(mkdir:*)")' "$SL" >/dev/null 2>&1 && jq -e '.permissions.ask | index("Bash(mkdir:*)") | not' "$SL" >/dev/null 2>&1 && ok "Claude: sandbox内mkdirをallow" || ng "Claude: mkdirが承認対象"
jq -e '.permissions.allow | index("Bash(zat:*)")' "$SL" >/dev/null 2>&1 && grep -Fq 'EDIT_RULES='\''{"*":"deny"}'\''' "$WORKER_RUNNER" && grep -Fq '機能の目的、要件、設計、変更範囲の調査は依頼しない' "$REPO/skills/unwind/SKILL.md" && ok "outline: zatは上位モデル、workerはnesting限定QAへ分離" || ng "outline: 上位調査と限定QAの境界が不足"
jq -e '.sandbox.excludedCommands | (index("./base/scripts/run-unit.sh") != null and index("./base/scripts/run-unit.sh *") != null)' "$SJ" >/dev/null 2>&1 && jq -e '.permissions.allow | (index("Bash(./base/scripts/run-unit.sh)") != null and index("Bash(./base/scripts/run-unit.sh:*)") != null)' "$SL" >/dev/null 2>&1 && ok "Claude: 承認済みunit test runnerをlocalでallow" || ng "Claude: unit test runnerの自動実行設定が不足"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("protect-locks.sh"))] | length' "$SJ")" = "$EXPECTED_DUAL_HOOK_BINDINGS" ] && ok "Claude lockfile保護hookをBash/Editへ配線" || ng "Claude lockfile保護hookの配線漏れ"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("protect-implementation-scope.sh"))] | length' "$SJ")" = "0" ] && ok "Claudeはexact実装scope hookを配線しない" || ng "Claudeにexact実装scope hookが残存"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("load-required-contract.sh"))] | length' "$SJ")" = "1" ] && grep -Fq 'load-required-contract.sh cowlick-design' "$REPO/skills/cowlick/SKILL.md" && ! grep -Fq 'worker/DELEGATION.md' "$REPO/hooks/shell/load-required-contract.sh" && ok "Claude必須契約hookをcowlick設計形式だけへ配線" || ng "Claude必須契約hookの配線漏れ"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("deny-migration.sh"))] | length' "$SJ")" = "1" ] && jq -e '.permissions.ask | index("Edit(**/schema.prisma)") | not' "$SL" >/dev/null && ok "Claude: schema.prismaは自動編集・migrationはhook拒否" || ng "Claude: Prisma境界が不正"
GROUP_FAILURES=
for MCP_TOOL in "${CLAUDE_UNAVAILABLE_SERENA_TOOLS[@]}"; do
  PERMISSION="mcp__serena__${MCP_TOOL}"
  jq -e --arg permission "$PERMISSION" '.permissions.allow | index($permission) | not' "$SL" >/dev/null 2>&1 || append_group_failure "$MCP_TOOL"
done
report_group "Claude serena: 利用不能toolを自動許可しない" "$GROUP_FAILURES"
GROUP_FAILURES=
for MCP_TOOL in "${SERENA_CODE_MUTATION_TOOLS[@]}"; do
  PERMISSION="mcp__serena__${MCP_TOOL}"
  jq -e --arg permission "$PERMISSION" '.permissions.deny | index($permission)' "$SL" >/dev/null 2>&1 || append_group_failure "$MCP_TOOL"
done
report_group "Claude serena: code変更toolを全件deny" "$GROUP_FAILURES"
jq -e '.permissions.allow + .permissions.deny | index("mcp__serena__replace_regex") | not' "$SL" >/dev/null 2>&1 && ok "Claude serena: 廃止済みtool名なし" || ng "Claude serena: 廃止済みreplace_regexが残存"
MISS=0
for SC in bootstrap/init-agent.sh tdd/mark-prompt-done.sh polish/quality-gate.sh polish/capture-scope.sh e2e/apply-e2e-plan.sh; do
  CMD="bash .claude/skills/$SC"
  jq -e --arg c "$CMD"          '.sandbox.excludedCommands | index($c)' "$SJ" >/dev/null 2>&1 || { ng "excludedCommands に引数なし形が無い: $SC"; MISS=1; }
  jq -e --arg c "$CMD *"        '.sandbox.excludedCommands | index($c)' "$SJ" >/dev/null 2>&1 || { ng "excludedCommands に引数あり形が無い: $SC"; MISS=1; }
  jq -e --arg c "Bash($CMD)"    '.permissions.allow | index($c)' "$SL" >/dev/null 2>&1 || { ng "allow に引数なし形が無い: $SC"; MISS=1; }
  jq -e --arg c "Bash($CMD:*)"  '.permissions.allow | index($c)' "$SL" >/dev/null 2>&1 || { ng "allow に引数あり形が無い: $SC"; MISS=1; }
done
[ "$MISS" = "0" ] && ok "固定スクリプトは引数あり・なし両形で登録済み"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
