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
CODEX_CONTEXT_EXTRA_APPROVED_SERENA_TOOLS=(search_for_pattern)
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
[ -x "$WORKER_RUNNER" ] || append_group_failure "exec bit: $WORKER_RUNNER"
report_group "実行ビット: hookと実行器全件" "$GROUP_FAILURES"
grep -q 'SOFT_BUDGET_USD="38"' "$WORKER_RUNNER" && grep -q 'HARD_BUDGET_USD="40"' "$WORKER_RUNNER" && ok "外部ワーカー予算: soft=38 hard=40" || ng "外部ワーカー予算が不正"
grep -q 'DEFAULT_MODEL="openrouter/minimax/minimax-m3"' "$WORKER_RUNNER" && grep -Fq 'MODEL="${DELEGATE_MODEL:-$DEFAULT_MODEL}"' "$WORKER_RUNNER" && grep -Fq 'MODEL_ID="${MODEL#openrouter/}"' "$WORKER_RUNNER" && ok "外部ワーカーモデル: MiniMax M3を既定値として差し替え可能" || ng "外部ワーカーモデルの既定値または差し替えが不正"
grep -Fq 'MODEL_VARIANT="${DELEGATE_MODEL_VARIANT:-}"' "$WORKER_RUNNER" && grep -q -- '--arg model_variant "$MODEL_VARIANT"' "$WORKER_RUNNER" && grep -q 'model_variant:(if $model_variant == "" then null else $model_variant end)' "$WORKER_RUNNER" && grep -q 'OPENCODE_COMMAND+=(--variant "$MODEL_VARIANT")' "$WORKER_RUNNER" && ! grep -q 'reasoningEffort' "$WORKER_RUNNER" && ok "外部ワーカーvariant: 既定はadaptive、明示時だけ指定" || ng "外部ワーカーvariantの任意指定が不正"
grep -q 'SURVEY_SCOPE_COUNT="4"' "$WORKER_RUNNER" && grep -q 'SURVEY_STEPS_PER_SCOPE="3"' "$WORKER_RUNNER" && grep -q 'SURVEY_MAX_STEPS="\$((SURVEY_SCOPE_COUNT \* SURVEY_STEPS_PER_SCOPE))"' "$WORKER_RUNNER" && grep -q '"steps":$survey_max_steps' "$WORKER_RUNNER" && grep -q -- '--agent delegate' "$WORKER_RUNNER" && ok "worker survey: 4段階ごとのagent step上限を固定" || ng "worker surveyのstep上限が不正"
grep -q 'SMOKE_IDLE_TIMEOUT_SECONDS="30"' "$WORKER_RUNNER" && grep -q 'requires explicit --hard-timeout-minutes' "$WORKER_RUNNER" && grep -q 'TIMEOUT_POLICY_SOURCE="explicit"' "$WORKER_RUNNER" && grep -q 'MIN_POLLS_PER_IDLE_WINDOW="3"' "$WORKER_RUNNER" && grep -q 'MIN_IDLE_WINDOWS_PER_HARD_TIMEOUT="2"' "$WORKER_RUNNER" && grep -q '^validate_timeout_reason()' "$WORKER_RUNNER" && grep -q -- '--arg timeout_reason "$TIMEOUT_REASON"' "$WORKER_RUNNER" && grep -q '^monitor_opencode()' "$WORKER_RUNNER" && grep -q '^terminate_process_group()' "$WORKER_RUNNER" && grep -q 'FINAL_STATUS=124' "$WORKER_RUNNER" && grep -q -- '--argjson timed_out "$TIMED_OUT"' "$WORKER_RUNNER" && ok "worker timeout: 明示値・理由・安全比率・固定smokeを検証して記録" || ng "worker timeout設定または理由の記録処理が不正"
grep -q '^write_task_state()' "$WORKER_RUNNER" && grep -q '^stop_running_children()' "$WORKER_RUNNER" && grep -q 'task is already active or has unfinished state' "$WORKER_RUNNER" && grep -q 'effective_status' "$WORKER_RUNNER" && grep -q 'HEAD+ignored-agent-context' "$WORKER_RUNNER" && grep -q 'context_snapshot_paths' "$WORKER_RUNNER" && ok "worker lifecycle: task状態・重複拒否・入力snapshotを記録" || ng "worker lifecycle管理が不正"
grep -q -- '--arg model_id "$MODEL_ID"' "$WORKER_RUNNER" && ! grep -q 'MODEL_ID="$MODEL_ID".*jq' "$WORKER_RUNNER" && ok "worker config: readonly定数をjq引数で受け渡す" || ng "worker config: readonly変数への再代入が残存"
grep -q '"zdr":true' "$WORKER_RUNNER" && grep -q '"data_collection":"deny"' "$WORKER_RUNNER" && ok "worker routing: ZDRとdata collection拒否" || ng "worker routingのprivacy強制漏れ"
grep -q '"bash":"deny"' "$WORKER_RUNNER" && grep -q '"external_directory":"deny"' "$WORKER_RUNNER" && grep -q 'opencode --pure run' "$WORKER_RUNNER" && ok "worker権限: shell・外部dir・pluginを拒否" || ng "worker権限境界が不正"
grep -Fq '".git/**":"deny"' "$WORKER_RUNNER" && grep -Fq '"**/.env.*":"deny"' "$WORKER_RUNNER" && ! grep -Fq '".codex/**":"deny"' "$WORKER_RUNNER" && ! grep -Fq '".claude/**":"deny"' "$WORKER_RUNNER" && ! grep -Fq '".agents/**":"deny"' "$WORKER_RUNNER" && grep -Fq '隔離入力の.codex/**、.claude/**、.agents/**' "$WORKER_RUNNER" && ok "worker読み取り: agent設定を根拠として許可しGit・envを拒否" || ng "workerのagent設定・Git・env読み取り境界が不正"
grep -Fq 'trap cleanup EXIT' "$WORKER_RUNNER" && grep -Fq "trap 'exit 130' INT" "$WORKER_RUNNER" && grep -Fq "trap 'exit 143' TERM" "$WORKER_RUNNER" && ok "worker中断: cleanup後に処理を継続しない" || ng "workerのsignal終了処理が不正"
grep -q 'SMOKE_PROMPT="hello"' "$WORKER_RUNNER" && grep -q 'if \$mode == "smoke" then "deny"' "$WORKER_RUNNER" && ok "worker smoke: hello固定・tool全拒否" || ng "worker smokeのpromptまたは権限が不正"
grep -q '^  nesting)' "$WORKER_RUNNER" && grep -q '修正案・コード変更は不要です' "$WORKER_RUNNER" && grep -q 'nesting path must be tracked' "$WORKER_RUNNER" && ok "worker nesting: 本体コードだけを読み取り検出" || ng "worker nesting検出モードが不正"
grep -q '^  survey)' "$WORKER_RUNNER" && grep -q 'survey mode requires task id and instruction' "$WORKER_RUNNER" && grep -q '識別子の完全一致と指定パス、機能語・ドメイン語、隣接モジュール、リポジトリ全体の順' "$WORKER_RUNNER" && grep -q '根拠が揃った時点で直ちに終了' "$WORKER_RUNNER" && ok "worker survey: 根拠に応じて調査範囲を段階拡張" || ng "worker surveyの段階調査契約が不正"
grep -q '^  show)' "$WORKER_RUNNER" && grep -q 'show mode requires task id' "$WORKER_RUNNER" && grep -q "cannot extract delegated report" "$WORKER_RUNNER" && ok "外部ワーカー結果: report抽出と固定showを提供" || ng "外部ワーカー結果の固定取得経路が不正"
grep -q '^  errand)' "$WORKER_RUNNER" && grep -q 'errand mode requires task id, instruction, --, and production paths' "$WORKER_RUNNER" && grep -q '短い実装指示に従い' "$WORKER_RUNNER" && ok "worker errand: 設計書なしの限定実装を受け付ける" || ng "worker errand実装モードが不正"
if grep -q '^  prepare)' "$WORKER_RUNNER" && grep -q 'delegation contract ready' "$WORKER_RUNNER" && grep -Fq 'delegate.sh prepare' "$REPO/skills/worker/DELEGATION.md" && [ "$(OPENROUTER_API_KEY= bash "$WORKER_RUNNER" prepare)" = 'delegate: delegation contract ready' ]; then
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
WORKER_CONTRACT="$REPO/skills/worker/DELEGATION.md"
COWLICK_FORMAT="$REPO/skills/cowlick/DESIGN_FORMAT.md"
REQUIRED_READING_HOOK="$REPO/hooks/shell/load-required-contract.sh"
for SKILL_FILE in "$MEETING_SKILL" "$PREFLIGHT_SKILL" "$COWLICK_SKILL" "$PONYTAIL_SKILL"; do
  [ -f "$SKILL_FILE" ] && ok "design skill存在: $(basename "$(dirname "$SKILL_FILE")")" || ng "design skill不在: $SKILL_FILE"
done
grep -q '^disable-model-invocation: true$' "$MEETING_SKILL" && grep -Fq 'ユーザーが `$meeting` を明示して' "$MEETING_SKILL" && grep -Fq '`$meeting` の明示呼び出しでだけ起動する' "$MEETING_SKILL" && grep -Fq '通常の自然言語による軽微な修正・追加依頼では起動しない' "$MEETING_SKILL" && grep -Fq '  - Skill(preflight)' "$MEETING_SKILL" && grep -Fq '  - Skill(cowlick *)' "$MEETING_SKILL" && grep -Fq '  - Skill(ponytail)' "$MEETING_SKILL" && grep -Fq '  - AskUserQuestion' "$MEETING_SKILL" && grep -Fq '  - Bash' "$MEETING_SKILL" && ok "meetingを明示起動だけに限定する" || ng "meetingの起動境界・skill境界が不正"
grep -q 'preflight → cowlick draft → ponytail' "$MEETING_SKILL" && ok "meetingの基本順序" || ng "meetingの基本順序が不正"
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
if sed -n '1,/^---$/p' "$PONYTAIL_SKILL" | grep -Eq 'allowed-tools:.*(Write|Edit|AskUserQuestion)'; then
  ng "ponytailが広域書き込み・質問toolを事前許可"
else
  ok "ponytailは調査toolだけを事前許可"
fi
grep -Fq 'bash [skills_root]/worker/delegate.sh prepare' "$MEETING_SKILL" && grep -Fq '各内部skillで`prepare`を繰り返さない' "$MEETING_SKILL" && grep -Fq 'workerの`survey`へ委任' "$PREFLIGHT_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh survey' "$PREFLIGHT_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh research' "$COWLICK_SKILL" && grep -Fq 'workerの`survey`へ委任' "$PONYTAIL_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh survey' "$PONYTAIL_SKILL" && grep -Fq 'worker/DELEGATION.md' "$REQUIRED_READING_HOOK" && ok "meetingが一度prepareして設計調査を固定実行器へ接続" || ng "meetingのprepareまたは設計調査の固定実行器が不正"
grep -Fq '明示的な認証失敗は再試行せず上位モデルが直ちに引き継ぐ' "$WORKER_CONTRACT" && grep -Fq '合計2回失敗したら上位モデルが引き継ぐ' "$WORKER_CONTRACT" && grep -Fq -- '--timeout-reason' "$WORKER_CONTRACT" && grep -Fq '| `low` | 30分 | 600秒 | 30秒 |' "$WORKER_CONTRACT" && grep -Fq '| `medium` | 45分 | 900秒 | 30秒 |' "$WORKER_CONTRACT" && grep -Fq '| `high` | 60分 | 900秒 | 30秒 |' "$WORKER_CONTRACT" && grep -Fq 'timeout後の再試行は値を短縮せず' "$WORKER_CONTRACT" && ok "worker共通契約がfallbackと余裕ある時間基準を一元管理" || ng "worker共通契約のfallbackまたは時間基準が不足"
grep -Fq '**明示要件**' "$PREFLIGHT_SKILL" && grep -Fq '**設計選択**' "$PREFLIGHT_SKILL" && grep -q '境界を新設しない基準案' "$PREFLIGHT_SKILL" && ok "preflightの要件由来・境界ゼロ契約" || ng "preflightの要件由来・境界ゼロ契約が不足"
grep -q '設計書ごと削除' "$COWLICK_SKILL" && grep -q '境界を新設しない基準案' "$COWLICK_SKILL" && grep -q '設計選択同士' "$COWLICK_SKILL" && ok "cowlickの最小draft契約" || ng "cowlickの最小draft契約が不足"
grep -Fq 'cowlick/DESIGN_FORMAT.md' "$REQUIRED_READING_HOOK" && grep -Fq 'Summary' "$COWLICK_FORMAT" && grep -Fq '## Changes' "$COWLICK_FORMAT" && grep -Fq 'error処理とDB書き込み、メール、外部API' "$COWLICK_FORMAT" && ok "cowlickの設計書形式を必要時に強制注入" || ng "cowlickの設計書形式参照が不正"
if grep -Fq 'DELEGATION.md' "$REPO"/skills/*/SKILL.md || grep -Fq 'DESIGN_FORMAT.md' "$REPO"/skills/*/SKILL.md; then
  ng "必要時注入する共通契約名がSKILL.mdへ重複"
else
  ok "共通契約は必要時までSKILL.mdへ載せない"
fi
grep -Fq '実装者が挙動を再設計せずコードへ変換できる密度' "$COWLICK_FORMAT" && grep -Fq 'guardの評価順、導出値と計算式' "$COWLICK_FORMAT" && grep -Fq '`where`の全条件と日付境界' "$COWLICK_FORMAT" && grep -Fq 'clientで検証する範囲とserverの最新dataで再検証する範囲' "$COWLICK_FORMAT" && grep -Fq '圧縮してよいのは重複説明と同一の外枠だけ' "$COWLICK_FORMAT" && grep -Fq '重要な分岐・式・順序・契約を保持' "$COWLICK_SKILL" && ok "cowlickの実装可能な疑似コード密度" || ng "cowlickの疑似コードが実装契約を省略可能"
grep -Fq '| 書き方 | 対象 | 例 |' "$COWLICK_FORMAT" && grep -Fq '予約語・演算子・構文、組み込み型と組み込みobject' "$COWLICK_FORMAT" && grep -Fq '標準library・外部library・frameworkのAPI、instance method・property名を英語' "$COWLICK_FORMAT" && grep -Fq '新しく設計する業務上の関数、引数、変数、型、結果field、error名、処理内容は日本語' "$COWLICK_FORMAT" && grep -Fq '既存symbol、schema field、file pathも参照を壊さないよう実名' "$COWLICK_FORMAT" && grep -Fq '予約語・構文を英語、新しく設計する識別子と処理内容を日本語' "$COWLICK_SKILL" && ok "cowlick疑似コードの英語構文・日本語識別子契約" || ng "cowlick疑似コードの言語規則が曖昧"
grep -Fq '次は書式と密度の例であり、この処理自体を要件として流用しない' "$COWLICK_FORMAT" && grep -Fq 'export async function 利用内容を確定する関数' "$COWLICK_FORMAT" && grep -Fq 'for (const 使用候補 of 使用候補一覧)' "$COWLICK_FORMAT" && grep -Fq 'return { 成功: true, 使用件数, 使用候補一覧 }' "$COWLICK_FORMAT" && ok "cowlick疑似コードの正例" || ng "cowlick疑似コードの正例が不足"
grep -q '## 必須監査成果物' "$PONYTAIL_SKILL" && grep -Fq '`ponytail_audit`' "$PONYTAIL_SKILL" && grep -Fq '`minimalAlternative`' "$PONYTAIL_SKILL" && grep -Fq '`counterexamples`' "$PONYTAIL_SKILL" && grep -Fq '`unresolved`' "$PONYTAIL_SKILL" && grep -q '何も削らなかった場合' "$PONYTAIL_SKILL" && grep -q '全fieldが埋まり.*ponytail_ready' "$PONYTAIL_SKILL" && ok "ponytailの横断削除・ready gate契約" || ng "ponytailの横断削除・ready gate契約が不足"
grep -Fq '入口、共有責務、全caller・consumer' "$PONYTAIL_SKILL" && grep -Fq '報告された症状とroot causeを分ける' "$PONYTAIL_SKILL" && grep -Fq '実装が一つだけのinterface' "$PONYTAIL_SKILL" && grep -Fq '測定可能な条件' "$PONYTAIL_SKILL" && grep -Fq '[delete|reuse|stdlib|native|yagni|shrink]' "$PONYTAIL_SKILL" && grep -Fq '最小の実行可能なテスト' "$PONYTAIL_SKILL" && ok "ponytailの理解・root cause・簡素化負債契約" || ng "ponytailの理解または簡素化境界が不足"
grep -Fq '重複説明と同一の外枠だけを統合' "$PONYTAIL_SKILL" && grep -Fq 'where・sort・tie-break' "$PONYTAIL_SKILL" && grep -Fq '文章一行へ畳まない' "$PONYTAIL_SKILL" && ok "ponytailは実装契約を失う圧縮を禁止" || ng "ponytailが疑似コードの重要契約を圧縮可能"
grep -Fq '同一file内の呼び出しを外部consumerに数えず' "$PONYTAIL_SKILL" && grep -Fq '別の値から導ける定数' "$PONYTAIL_SKILL" && grep -Fq '`counterexamples`' "$PONYTAIL_SKILL" && grep -Fq '実装ファイルがまだ存在しないことだけを理由に `blocked` にしない' "$PONYTAIL_SKILL" && ok "ponytailの要素単位consumer・反例監査契約" || ng "ponytailの要素単位consumerまたは反例監査契約が不足"
grep -Fq '一つのfindingはIDを付けて一度だけ説明' "$PONYTAIL_SKILL" && grep -Fq '同じ要件・原因・判断・置換先を持つ要素は一行へまとめる' "$PONYTAIL_SKILL" && grep -Fq '同じtopologyや根拠を別fieldで言い換えない' "$PONYTAIL_SKILL" && ok "ponytailの監査正本は重複せず簡潔" || ng "ponytailの監査成果物が重複可能"
grep -q 'ponytail_ready.*文字列だけでは通過させない' "$MEETING_SKILL" && grep -Fq '`ponytail_audit`の必須field' "$MEETING_SKILL" && grep -Fq '空の`unresolved`' "$MEETING_SKILL" && ok "meetingのponytail成果物検証" || ng "meetingがponytailのstatusだけを信用している"
grep -Fq 'topologyが入口から副作用まで繋がる' "$MEETING_SKILL" && grep -Fq '対応要件と直接の外部consumer' "$MEETING_SKILL" && grep -Fq '具体値の反例' "$MEETING_SKILL" && ok "meetingがponytailの主要成果物を独立検証" || ng "meetingのponytail独立検証が不足"
grep -Fq '`ponytail`の最後の設計レビューを下位モデルへ渡してはならない' "$MEETING_SKILL" && grep -Fq '設計判断、横断比較、採否、ドラフト修正は[agent_name]が行う' "$PONYTAIL_SKILL" && ok "ponytailの最終設計判断を上位モデルへ固定" || ng "ponytailが設計判断を下位モデルへ委任できる"
grep -q 'draft_ready.*停止' "$COWLICK_SKILL" && grep -q '^## apply' "$COWLICK_SKILL" && grep -q '`draft_conflict`' "$COWLICK_SKILL" && ok "cowlickのdraft/applyと既存draft境界" || ng "cowlickのmode・draft境界が不正"
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
[ -f "$WORKER_CONTRACT" ] || append_group_failure "worker共通契約なし"
[ -f "$COWLICK_FORMAT" ] || append_group_failure "cowlick設計形式なし"
report_group "progressive disclosure参照が全件存在" "$GROUP_FAILURES"
if bash "$SUITE/verify-context-mcp.sh" > "$S/context-mcp.out" 2>&1; then
  ok "dictionary skillとMCP配布設定を統合"
else
  ng "dictionary skillまたはMCP配布設定が不正"
  cat "$S/context-mcp.out"
fi

echo "== 軽微な実装委任と全体調査委任 =="
ERRAND_SKILL="$REPO/skills/errand/SKILL.md"
[ -f "$ERRAND_SKILL" ] && grep -q '^disable-model-invocation: true$' "$ERRAND_SKILL" && grep -q 'allow_implicit_invocation: false' "$REPO/skills/errand/agents/openai.yaml" && ok "errand スキルは明示起動だけ許可" || ng "errand スキルの明示起動境界が不正"
grep -Fq 'ユーザーが明示的に errand を呼んだ場合だけ' "$ERRAND_SKILL" && grep -Fq 'meeting / cowlick / ponytail は呼ばない' "$ERRAND_SKILL" && grep -Fq '識別子、path、番号、固有名詞を省略・翻訳・一般化しない' "$ERRAND_SKILL" && grep -Fq '最寄りの同型実装1件' "$ERRAND_SKILL" && ok "errand は識別子を保持して最寄り同型へ限定" || ng "errand の軽量調査境界が不正"
grep -Fq '外部ワーカーの`survey`を必ず1回実行' "$ERRAND_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh prepare' "$ERRAND_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh <mode>' "$ERRAND_SKILL" && grep -Fq '`errand` modeへ実装指示と`--`以降の許可path' "$ERRAND_SKILL" && grep -Fq 'テスト、設定、migration、Git、設計資産を変更させない' "$ERRAND_SKILL" && ok "errand はprepare・固定実行器と外部ワーカー実装境界を固定" || ng "errand のprepare・固定実行器または実装境界が不正"
grep -Fq '同型実装から名前・内容を一意に決められる新規本体ファイル' "$ERRAND_SKILL" && grep -q 'new allowed path parent must exist' "$WORKER_RUNNER" && grep -q 'new allowed path must not be ignored' "$WORKER_RUNNER" && ok "errand は一意な定型ファイル追加だけ許可" || ng "errand の新規ファイル境界が不正"
grep -Fq '未実装が前提である' "$ERRAND_SKILL" && grep -Fq '許可パスが複数あることだけを理由に停止してはならない' "$ERRAND_SKILL" && grep -Fq 'schema.prisma' "$ERRAND_SKILL" && grep -Fq 'migration commandと別workflow skillは実行しない' "$ERRAND_SKILL" && ok "errand は複数pathとPrisma schemaを許可しmigrationを禁止" || ng "errand の複数path・Prisma境界が不正"
grep -Fq '採用部分を許可pathへ反映して初回実装' "$ERRAND_SKILL" && grep -Fq '所属packageの既存typecheck' "$ERRAND_SKILL" && grep -Fq 'Prisma `format`、`validate`、`generate`' "$ERRAND_SKILL" && ok "errand は候補反映と検証範囲を固定" || ng "errand の候補反映または検証範囲が曖昧"
grep -Fq '初回実装は外部ワーカーの`candidate.patch`から始める' "$ERRAND_SKILL" && grep -Fq '2回続けて応答に失敗した場合' "$ERRAND_SKILL" && grep -Fq '修正を外部ワーカーへ再委任しない' "$ERRAND_SKILL" && grep -Fq '修正する／しない、部分採用、全体拒否の判断は上位モデル' "$ERRAND_SKILL" && grep -Fq '初回実装候補を作成してください' "$WORKER_RUNNER" && ok "errand は外部ワーカー初回実装・上位モデル判断とfallbackへ固定" || ng "errand の初回実装・修正責務が不正"
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
grep -Fq '外部ワーカーの`nesting` modeで検出だけを委任' "$UNWIND_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh prepare' "$UNWIND_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh nesting' "$UNWIND_SKILL" && grep -q '自力検出へ切り替えず' "$UNWIND_SKILL" && grep -q 'workerが検出した' "$POLISH_SKILL" && grep -Fq '上位モデルは返却された候補の修正・却下判断と検証だけを担当' "$UNWIND_SKILL" && ok "unwind はprepare・固定実行器で機械的検出を外部ワーカー、修正判断を上位へ固定" || ng "unwind のprepare・固定実行器または検出・判断責務分離が無い"
[ -x "$QUALITY_GATE_SCRIPT" ] && bash -n "$QUALITY_GATE_SCRIPT" && grep -Fq 'quality-gate.sh <機能名> -- <実変更path>...' "$POLISH_SKILL" && ! grep -Eq 'record|verify|HEAD.*receipt' "$QUALITY_GATE_SCRIPT" && ok "polish の単回path検査器が有効" || ng "polish の単回path検査器が不正"
[ -x "$CAPTURE_SCOPE_SCRIPT" ] && bash -n "$CAPTURE_SCOPE_SCRIPT" && grep -Fq 'capture-scope.sh <機能名> -- <相対path>...' "$TDD_SKILL" && grep -Fq 'capture-scope.sh list-changed <機能名>' "$TDD_SKILL" && ok "tdd は開始scopeを固定して実変更pathだけを選択" || ng "tdd の実変更path selectorが不正"
grep -Fq 'quality-gate.sh <機能名> -- <実変更path>...' "$POLISH_SKILL" && grep -Fq '現在の入力pathを「基準commitから実際に変更され、現在存在するfile」の一覧と順序込みで完全一致' "$POLISH_SKILL" && grep -Fq '入力された実変更pathだけが追跡済みかつclean' "$POLISH_SKILL" && grep -Fq '完了receiptの記録や後続での再検証は行わない' "$POLISH_SKILL" && grep -Fq '独自のESLint rule、`no-magic-numbers`、import規則を追加しない' "$POLISH_SKILL" && ! grep -Eq 'eslint|no-magic-numbers|no-restricted-syntax' "$QUALITY_GATE_SCRIPT" && ok "polish は実変更path一致とtracked・cleanだけを単回検査" || ng "polish の実変更path検査が不正"
! grep -Fq 'quality-gate.sh' "$MARK_PROMPT_DONE_SCRIPT" && grep -Fq 'polishのscope path検査が成功した後だけ' "$TDD_SKILL" && ok "tdd from-prompt は品質検査を再実行せずindexを更新" || ng "tdd from-prompt に不要な再検証がある"
grep -Fq '| `from-prompt` |' "$TDD_SKILL" && grep -Fq '| `<承認済み設計書path>` |' "$TDD_SKILL" && grep -Fq '設計書path modeでは`mark-prompt-done.sh`を使わず、indexへ触れない' "$TDD_SKILL" && ok "tdd はfrom-promptと設計書pathを明示的に分離" || ng "tdd の入力mode境界が不正"
grep -Fq '外部ワーカーの`survey`へ委任' "$TDD_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh prepare' "$TDD_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh <mode>' "$TDD_SKILL" && grep -Fq '候補が返った後の採否は上位モデルのレビュー責務' "$TDD_SKILL" && grep -Fq '外部ワーカーの2回連続応答失敗または認証失敗後だけ可' "$TDD_SKILL" && grep -Fq '外部ワーカー候補反映後の本体コード修正 | 可 | 禁止' "$TDD_SKILL" && ok "tdd はprepare・固定実行器・外部ワーカー初回実装・上位fallback・上位修正へ固定" || ng "tdd のprepare・固定実行器・外部ワーカー初回実装・上位fallback・上位修正が不正"
grep -Fq 'Step 1で設計書を選んでからStep 5の外部ワーカー初回実装候補を受領するまで' "$TDD_SKILL" && grep -Fq '外部ワーカーの`file:line`はreportの監査根拠' "$TDD_SKILL" && grep -Fq 'reportだけで[agent_name]がシナリオ設計とテスト資産の作成を完了' "$TDD_SKILL" && grep -Fq '単なる情報不足や「念のため」は疑義に含めず' "$TDD_SKILL" && grep -Fq '疑わしいclaim、疑義の根拠、読むpathまたは範囲を先にユーザーへ明示' "$TDD_SKILL" && grep -Fq '正常終了したが不完全なreportを、[agent_name]のRead / Grep / Glob / shell検索で補完してはならない' "$TDD_SKILL" && grep -Fq '足りない事実は限定surveyで補う' "$TDD_SKILL" && ! grep -Fq 'report受領後も直接読むのは重要な`file:line`の確認だけ' "$TDD_SKILL" && ok "tdd は通常調査を外部ワーカー、上位調査をfallback・具体的疑義へ固定" || ng "tdd が上位モデルの無条件再探索を許可"
grep -Fq 'テストシナリオ設計 | 可 | 禁止' "$TDD_SKILL" && grep -Fq 'テストシナリオ、期待値、assertion、fixture構成、テストコードを提案または変更させない' "$TDD_SKILL" && grep -Fq '[agent_name]が正常系、境界値、異常系、副作用、回帰リスクとテスト構造を設計' "$TDD_SKILL" && ok "tddのテスト設計と実装を上位モデルへ固定" || ng "tddがテスト設計をworkerへ委任可能"
grep -Fq '`schema.prisma`自体はテスト対象外' "$TDD_SKILL" && grep -Fq 'シナリオ承認とStep 3・4を省略' "$TDD_SKILL" && grep -Fq '本体コードの公開挙動変更が含まれる場合' "$TDD_SKILL" && ok "tddはschema.prismaの検証境界を固定" || ng "tddのschema.prisma検証境界が不正"
grep -Fq '`.jsx` / `.tsx` componentとReact hookには隣接unit testを作らず' "$TDD_SKILL" && grep -Fq '`.jsx` / `.tsx` componentとReact hookは隣接unit testの必須対象外' "$REPO/rules/typescript/tdd-pattern.md" && grep -Fq '*/hooks/*|*/use[A-Z]*.ts' "$REPO/hooks/shell/require-test.sh" && ok "componentとReact hookはunit test必須対象外" || ng "componentまたはReact hookのtest除外が不正"
grep -Fq '`target-test`、`direct-regression`、`typecheck`、`schema`' "$TDD_SKILL" && grep -Fq '無関係なpackageのtestやproject全体のtestは追加しない' "$TDD_SKILL" && grep -Fq '`tsc -p <tsconfig> --noEmit`' "$TDD_SKILL" && grep -Fq 'Prisma `format`、`validate`、`generate`' "$TDD_SKILL" && ok "tddは調査commandと最終検証の範囲を固定" || ng "tddの調査commandまたは最終検証が曖昧"
grep -Fq '開始scope全件、directory、glob、`git diff`で独自に広げたpathを使わない' "$POLISH_SKILL" && grep -Fq 'typecheckとPrisma検証はファイル単位で安全に分割できない' "$POLISH_SKILL" && grep -Fq '実変更pathだけを渡して`unwind`を必ず呼ぶ' "$POLISH_SKILL" && grep -Fq '`unwind`自身では差分を再探索・再検証しない' "$UNWIND_SKILL" && grep -Fq '`list-changed`をもう一度実行しない' "$POLISH_SKILL" && ok "polishとunwindは実変更pathを再探索せず対象化" || ng "polishまたはunwindが実変更pathを再探索"
grep -Fq 'Skill(polish)' "$TDD_SKILL" && grep -Fq '開始scope全件ではなく、この出力にある実変更pathだけをまとめて`polish`へ渡し' "$TDD_SKILL" && grep -Fq 'bash [skills_root]/tdd/mark-prompt-done.sh <機能名>' "$TDD_SKILL" && ok "tdd は実変更pathのpolish後だけfrom-promptのindexを更新" || ng "tdd のpolish対象または品質ゲートが不正"
grep -Fq 'capture-scope.sh <機能名> -- <相対path>...' "$TDD_SKILL" && grep -Fq '変更前に次を1回実行' "$TDD_SKILL" && ok "tdd はpolish対象の基準commitとpathを変更前に固定" || ng "tdd のscope path固定が不正"
grep -Fq 'ファイルごとには呼ばない' "$TDD_SKILL" && grep -Fq 'formatterがformat差分を自動修正' "$POLISH_SKILL" && grep -Fq '上位モデルがコードを判断して修正した場合は全品質ゲートを再実行' "$POLISH_SKILL" && ok "tdd はpolishを全path一括で原因別に反復" || ng "tdd のpolish実行単位または反復条件が不正"

echo "== 2. claude 配置シミュレーション =="
mkdir -p "$S/claude-sim/.claude"
cp "$REPO/AGENTS.md" "$S/claude-sim/"
cp -R "$REPO/hooks" "$S/claude-sim/.claude/hooks"
cp -R "$REPO/skills" "$S/claude-sim/.claude/skills"
cp -R "$REPO/rules" "$S/claude-sim/.claude/rules"
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
AP=".claude/skills/cowlick/apply-prompt.sh"
MD=".claude/skills/tdd/mark-prompt-done.sh"
QG=".claude/skills/polish/quality-gate.sh"
CS=".claude/skills/polish/capture-scope.sh"
mkdir -p draft-prompt
printf '# 実装順\n\n- [ ] branch-user-api-prompt.md\n- [ ] branch-user-form-prompt.md\n' > draft-prompt/.prompt.md
echo api > draft-prompt/branch-user-api-prompt.md
echo form > draft-prompt/branch-user-form-prompt.md
bash "$AP" > apply.out 2>&1
if [ -f .claude/prompt/.prompt.md ] && [ -f .claude/prompt/branch-user-api-prompt.md ] && [ -f .claude/prompt/branch-user-form-prompt.md ]; then
  ok "apply-prompt: index と設計書を固定宛先へ反映"
else
  ng "apply-prompt: 固定宛先への反映漏れ"; cat apply.out
fi
[ ! -d draft-prompt ] && ok "apply-prompt: 反映後に draft-prompt/ を畳む" || ng "apply-prompt: draft-prompt/ が残った"
# 引数を受け取らない = 削除先を外から動かせない、が安全性の根拠。引数追加の再発を検知する
grep -q 'SRC_DIR="draft-prompt"' "$AP" && ok "apply-prompt: 移動元がスクリプト内に固定" || ng "apply-prompt: 移動元が固定されていない"

mkdir -p draft-prompt
printf -- '- [ ] branch-billing-prompt.md\n' > draft-prompt/.prompt.md
echo billing > draft-prompt/branch-billing-prompt.md
bash "$AP" > apply2.out 2>&1
if [ -f .claude/prompt/branch-billing-prompt.md ] && [ ! -e .claude/prompt/branch-user-api-prompt.md ] && [ ! -e .claude/prompt/branch-user-form-prompt.md ]; then
  ok "apply-prompt: 前タスクの設計書を残さない"
else
  ng "apply-prompt: 前タスクの設計書が残った"; cat apply2.out
fi

mkdir -p draft-prompt
printf -- '- [ ] branch-a-prompt.md\n' > draft-prompt/.prompt.md
echo a > draft-prompt/branch-a-prompt.md
echo memo > draft-prompt/memo.txt
if bash "$AP" > apply3.out 2>&1; then ng "apply-prompt: 想定外ファイルを通した"; else ok "apply-prompt: 想定外ファイルを拒否"; fi
[ -d draft-prompt ] && ok "apply-prompt: 失敗時は draft-prompt/ を畳まない" || ng "apply-prompt: 失敗時に draft-prompt/ を消した"
rm -f draft-prompt/memo.txt

printf -- '- [ ] branch-a-prompt.md\n- [ ] branch-b-prompt.md\n' > draft-prompt/.prompt.md
if bash "$AP" > apply4.out 2>&1; then ng "apply-prompt: index と実体の食い違いを通した"; else ok "apply-prompt: index と実体の食い違いを拒否"; fi

printf -- '- [ ] branch-a-prompt.md\n- [ ] ../evil.md\n' > draft-prompt/.prompt.md
if bash "$AP" > apply5.out 2>&1; then ng "apply-prompt: 不正な index 行を通した"; else ok "apply-prompt: 不正な index 行を拒否"; fi
rm -rf draft-prompt

mkdir -p src
printf 'export function legacyNumber() { return 99 }\n' > src/rules.ts
printf 'export const untouched = true\n' > src/untouched.ts
git add src/rules.ts src/untouched.ts
git commit -qm "test: scope path fixtureを追加"
if bash "$CS" billing -- src/rules.ts src/untouched.ts src/planned.ts > quality-begin.out 2>&1; then ok "polish-scope: 基準commitと候補pathを固定"; else ng "polish-scope: 変更前scopeを記録できない"; cat quality-begin.out; fi
if bash "$CS" directory-scope -- src > quality-directory.out 2>&1; then ng "polish-scope: directory指定を通した"; else ok "polish-scope: 個別file以外を拒否"; fi
if bash "$CS" glob-scope -- 'src/*.ts' > quality-glob.out 2>&1; then ng "polish-scope: pathspec globを通した"; else ok "polish-scope: pathspec globを拒否"; fi
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
bash "$MD" billing > mark.out 2>&1
grep -qE '^\- \[x\] branch-billing-prompt\.md$' .claude/prompt/.prompt.md && ok "mark-prompt-done: index を [x] に倒す" || { ng "mark-prompt-done: [x] に倒せない"; cat mark.out; }
grep -q '^remaining: 0$' mark.out && ok "mark-prompt-done: 残件数を報告" || { ng "mark-prompt-done: 残件数の報告が無い"; cat mark.out; }
if bash "$MD" billing > mark2.out 2>&1; then ng "mark-prompt-done: 二重マークを通した"; else ok "mark-prompt-done: 二重マークを拒否"; fi
if bash "$MD" "../../etc/passwd" > mark3.out 2>&1; then ng "mark-prompt-done: 不正な機能名を通した"; else ok "mark-prompt-done: 不正な機能名を拒否"; fi
if bash "$MD" nonexistent > mark4.out 2>&1; then ng "mark-prompt-done: 未登録の機能名を通した"; else ok "mark-prompt-done: 未登録の機能名を拒否"; fi
rm -rf .claude/prompt

echo "== 2.75 workerの Bash 3.2 回帰（外部通信なし） =="
DELEGATE_REPO="$S/delegate-research"
DELEGATE_BIN="$DELEGATE_REPO/bin"
DELEGATE_SCRIPT="$DELEGATE_REPO/.claude/skills/worker/delegate.sh"
DELEGATE_TIMEOUT_REASON='scope=fixture,difficulty=low,basis=offline-runner-regression'
DELEGATE_TIMEOUT_ARGS=(--hard-timeout-minutes 4 --idle-timeout-seconds 120 --poll-seconds 5 --timeout-reason "$DELEGATE_TIMEOUT_REASON")
mkdir -p "$DELEGATE_BIN" "$(dirname "$DELEGATE_SCRIPT")"
cp .claude/skills/worker/delegate.sh "$DELEGATE_SCRIPT"
printf '#!/bin/bash\nprintf '\''{"data":{"usage_monthly":0,"usage":0,"limit":40,"limit_reset":"monthly"}}\\n'\''\n' > "$DELEGATE_BIN/curl"
printf '#!/bin/bash\njq -cn --arg text "$*" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/curl" "$DELEGATE_BIN/opencode"
cd "$DELEGATE_REPO"
git init -q
git config user.email tester@example.com
git config user.name tester
printf '# research spec\n' > spec.md
git add spec.md
git commit -qm "test: research fixture"
printf '/.codex/\n/.agents/\n/AGENTS.md\n' > .git/info/exclude
mkdir -p .codex/prompt .codex/rules .codex/tmp .agents/skills/sample
printf '# ignored agent instructions\n' > AGENTS.md
printf '# ignored design\n' > .codex/prompt/ignored-design.md
printf '# ignored rules\n' > .codex/rules/ignored.rules
printf '# ignored skill\n' > .agents/skills/sample/SKILL.md
printf 'must not enter delegated worktree\n' > .codex/tmp/private.txt
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" smoke > delegate-smoke.out 2>&1 && grep -Fq 'smoke: ok model=openrouter/minimax/minimax-m3 variant=default' delegate-smoke.out; then
  ok "delegate-openrouter: MiniMax M3の既定値でsmokeを完了"
else
  ng "delegate-openrouter: MiniMax M3の既定値またはsmokeが不正"; cat delegate-smoke.out
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test DELEGATE_MODEL='openrouter/example/example-model' DELEGATE_MODEL_VARIANT=high bash "$DELEGATE_SCRIPT" smoke > delegate-model-override.out 2>&1 && grep -Fq 'smoke: ok model=openrouter/example/example-model variant=high' delegate-model-override.out; then
  ok "delegate-openrouter: modelとvariantを環境変数で上書き"
else
  ng "delegate-openrouter: modelまたはvariantの上書きが不正"; cat delegate-model-override.out
fi
if DELEGATE_MODEL='minimax/minimax-m3' OPENROUTER_API_KEY= bash "$DELEGATE_SCRIPT" prepare > delegate-invalid-model.out 2>&1; then
  ng "delegate-openrouter: OpenRouterを通らないmodel指定を許可"
elif grep -Fq 'DELEGATE_MODEL must use the openrouter/<provider>/<model> format' delegate-invalid-model.out; then
  ok "delegate-openrouter: OpenRouter model形式を強制"
else
  ng "delegate-openrouter: 不正modelの拒否理由が不正"; cat delegate-invalid-model.out
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" research missing-timeout-policy spec.md > delegate-missing-timeout.out 2>&1; then
  ng "delegate-worker: timeoutと理由の省略を許可"
elif grep -Fq 'requires explicit --hard-timeout-minutes' delegate-missing-timeout.out; then
  ok "delegate-worker: 非smoke modeはtimeoutと理由を必須化"
else
  ng "delegate-worker: timeout省略時の拒否理由が不正"; cat delegate-missing-timeout.out
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" research --hard-timeout-minutes 1 --idle-timeout-seconds 30 --poll-seconds 5 --timeout-reason "$DELEGATE_TIMEOUT_REASON" invalid-hard spec.md > delegate-invalid-hard.out 2>&1; then
  ng "delegate-worker: hard timeoutの安全範囲外を許可"
elif PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" research --hard-timeout-minutes 4 --idle-timeout-seconds 120 --poll-seconds 60 --timeout-reason "$DELEGATE_TIMEOUT_REASON" invalid-poll-ratio spec.md > delegate-invalid-poll.out 2>&1; then
  ng "delegate-worker: idle内のpoll不足を許可"
elif PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" research --hard-timeout-minutes 2 --idle-timeout-seconds 90 --poll-seconds 5 --timeout-reason "$DELEGATE_TIMEOUT_REASON" invalid-hard-ratio spec.md > delegate-invalid-ratio.out 2>&1; then
  ng "delegate-worker: hard内のidle区間不足を許可"
elif PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" research --hard-timeout-minutes 4 --idle-timeout-seconds 120 --poll-seconds 5 --timeout-reason short invalid-reason spec.md > delegate-invalid-reason.out 2>&1; then
  ng "delegate-worker: 監査不能なtimeout理由を許可"
else
  ok "delegate-worker: timeout範囲・比率・理由schemaを強制"
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" research "${DELEGATE_TIMEOUT_ARGS[@]}" empty-research spec.md > delegate-empty.out 2>&1; then
  ok "delegate-worker: Bash 3.2で変更ゼロのresearchを完了"
else
  ng "delegate-worker: 変更ゼロのresearchで失敗"; cat delegate-empty.out
fi
EMPTY_RESULT="$DELEGATE_REPO/.claude/tmp/worker/empty-research/result.json"
if [ -f "$EMPTY_RESULT" ] && [ "$(jq -c '.changed_paths' "$EMPTY_RESULT")" = "[]" ]; then
  ok "delegate-worker: 変更ゼロを空配列で記録"
else
  ng "delegate-worker: 変更ゼロのresult.jsonが不正"
fi
printf '#!/bin/bash\njq -e '\''(.default_agent == "delegate") and (.agent.delegate.steps == 12)'\'' "$OPENCODE_CONFIG" >/dev/null || exit 41\n[ -f AGENTS.md ] && [ -f .codex/prompt/ignored-design.md ] && [ -f .codex/rules/ignored.rules ] && [ -f .agents/skills/sample/SKILL.md ] && [ ! -e .codex/tmp/private.txt ] || exit 42\njq -cn --arg text "$*" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
SURVEY_EXACT_IDENTIFIER='t47_20__kanzen_douki__device_nebiki_kanri_db'
SURVEY_SOURCE_HEAD=$(git rev-parse HEAD)
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" empty-survey "$SURVEY_EXACT_IDENTIFIER と同型の実装を調査する" > delegate-survey.out 2>&1; then
  ok "delegate-worker: surveyは設計書なしの読み取り調査を完了"
else
  ng "delegate-worker: surveyが失敗"; cat delegate-survey.out
fi
SURVEY_ROOT="$DELEGATE_REPO/.claude/tmp/worker/empty-survey"
SURVEY_RESULT="$SURVEY_ROOT/result.json"
if [ -f "$SURVEY_RESULT" ] && [ "$(jq -r '.mode' "$SURVEY_RESULT")" = "survey" ] && [ "$(jq -r '.report_file' "$SURVEY_RESULT")" = "report.md" ] && [ "$(jq -r '.step_limit' "$SURVEY_RESULT")" = "12" ] && [ "$(jq -r '.source_snapshot' "$SURVEY_RESULT")" = "HEAD+ignored-agent-context" ] && [ "$(jq -r '.source_head' "$SURVEY_RESULT")" = "$SURVEY_SOURCE_HEAD" ] && [ "$(jq -r '.source_worktree_dirty' "$SURVEY_RESULT")" = "true" ] && [ "$(jq -r '.timeout_policy_source' "$SURVEY_RESULT")" = "explicit" ] && [ "$(jq -r '.poll_seconds' "$SURVEY_RESULT")" = "5" ] && [ "$(jq -r '.timeout_reason' "$SURVEY_RESULT")" = "$DELEGATE_TIMEOUT_REASON" ] && [ "$(jq -c '.context_snapshot_paths' "$SURVEY_RESULT")" = '[".agents/skills/sample/SKILL.md",".codex/prompt/ignored-design.md",".codex/rules/ignored.rules","AGENTS.md"]' ] && [ ! -e "$SURVEY_ROOT/spec.md" ] && [ ! -e "$DELEGATE_REPO/.claude/tmp/worker/.empty-survey.task" ]; then
  ok "delegate-worker: surveyはignored agent資料を監査可能なsnapshotとして読む"
else
  ng "delegate-worker: surveyのignored agent資料snapshotまたはresult.jsonが不正"
fi
if grep -Fq "$SURVEY_EXACT_IDENTIFIER" "$SURVEY_ROOT/report.md" && grep -Fq '機能語・ドメイン語' "$SURVEY_ROOT/report.md" && grep -Fq '根拠が揃った時点で直ちに終了' "$SURVEY_ROOT/report.md" && grep -Fq 'report:' delegate-survey.out; then
  ok "delegate-worker: surveyの識別子と段階終了条件をreportへ返却"
else
  ng "delegate-worker: survey reportが識別子または段階調査契約を欠落"
fi
if PATH="$DELEGATE_BIN:$PATH" bash "$DELEGATE_SCRIPT" show empty-survey > delegate-show.out 2>&1 && grep -Fq 'metadata:' delegate-show.out && grep -Fq "$SURVEY_EXACT_IDENTIFIER" delegate-show.out; then
  ok "delegate-worker: showはAPI keyなしで調査結果を再表示"
else
  ng "delegate-worker: showで調査結果を再取得できない"; cat delegate-show.out
fi
mv "$SURVEY_ROOT/report.md" "$SURVEY_ROOT/report.saved"
if PATH="$DELEGATE_BIN:$PATH" bash "$DELEGATE_SCRIPT" show empty-survey > delegate-show-legacy.out 2>&1 && grep -Fq "$SURVEY_EXACT_IDENTIFIER" delegate-show-legacy.out; then
  ok "delegate-worker: showは旧jsonlから最終reportを復元"
else
  ng "delegate-worker: showで旧jsonlの最終reportを復元できない"; cat delegate-show-legacy.out
fi
mv "$SURVEY_ROOT/report.saved" "$SURVEY_ROOT/report.md"
printf '#!/bin/bash\njq -cn --arg text "$*" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
mkdir -p src
printf 'export const subject = true\n' > src/subject.ts
git add src/subject.ts
git commit -qm "test: nesting対象"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" nesting "${DELEGATE_TIMEOUT_ARGS[@]}" nesting-check src/subject.ts > delegate-nesting.out 2>&1; then
  ok "delegate-worker: nestingは追跡済み本体コードを読み取り検出"
else
  ng "delegate-worker: nestingが失敗"; cat delegate-nesting.out
fi
NESTING_RESULT="$DELEGATE_REPO/.claude/tmp/worker/nesting-check/result.json"
if [ -f "$NESTING_RESULT" ] && [ "$(jq -r '.mode' "$NESTING_RESULT")" = "nesting" ] && [ "$(jq -c '.changed_paths' "$NESTING_RESULT")" = "[]" ]; then
  ok "delegate-worker: nesting結果を変更なしで保存"
else
  ng "delegate-worker: nestingのresult.jsonが不正"
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" errand "${DELEGATE_TIMEOUT_ARGS[@]}" errand-check 'subject.tsのboolean定数をfalseに変更する' -- src/subject.ts > delegate-errand.out 2>&1; then
  ok "delegate-worker: errandは一時設計書なしで限定実装を完了"
else
  ng "delegate-worker: errandが失敗"; cat delegate-errand.out
fi
ERRAND_RESULT="$DELEGATE_REPO/.claude/tmp/worker/errand-check/result.json"
if [ -f "$ERRAND_RESULT" ] && [ "$(jq -r '.mode' "$ERRAND_RESULT")" = "errand" ] && [ ! -e "$DELEGATE_REPO/.claude/tmp/worker/errand-check/spec.md" ]; then
  ok "delegate-worker: errandは実装指示を永続化しない"
else
  ng "delegate-worker: errandの一時指示またはresult.jsonが不正"
fi
printf '#!/bin/bash\nprintf '\''export const addedSubject = true\\n'\'' > src/added-subject.ts\nprintf '\''{"type":"text","text":"added"}\\n'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" errand "${DELEGATE_TIMEOUT_ARGS[@]}" errand-new-file '同型に従いadded-subject.tsを追加する' -- src/added-subject.ts > delegate-errand-new.out 2>&1; then
  ok "delegate-worker: errandは既存directoryへの定型ファイル追加を許可"
else
  ng "delegate-worker: errandの定型ファイル追加に失敗"; cat delegate-errand-new.out
fi
ERRAND_NEW_ROOT="$DELEGATE_REPO/.claude/tmp/worker/errand-new-file"
if [ "$(jq -c '.changed_paths' "$ERRAND_NEW_ROOT/result.json" 2>/dev/null)" = '["src/added-subject.ts"]' ] && grep -Fq 'addedSubject' "$ERRAND_NEW_ROOT/candidate.patch"; then
  ok "delegate-worker: 新規本体ファイルを候補patchへ限定記録"
else
  ng "delegate-worker: 新規本体ファイルの候補patchが不正"
fi
if PATH="$DELEGATE_BIN:$PATH" bash "$DELEGATE_SCRIPT" show errand-new-file > delegate-show-patch.out 2>&1 && grep -Fq 'candidate.patch:' delegate-show-patch.out && grep -Fq 'addedSubject' delegate-show-patch.out; then
  ok "delegate-worker: showは候補patchを固定経路で再表示"
else
  ng "delegate-worker: showで候補patchを再取得できない"; cat delegate-show-patch.out
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" errand "${DELEGATE_TIMEOUT_ARGS[@]}" errand-missing-parent '存在しないdirectoryへ追加する' -- missing/added-subject.ts > delegate-errand-missing.out 2>&1; then
  ng "delegate-worker: 存在しない親directoryへの追加を許可"
else
  ok "delegate-worker: 存在しない親directoryへの追加を拒否"
fi
mkdir -p prisma
printf 'generator client {}\n' > prisma/schema.prisma
git add prisma/schema.prisma
git commit -qm "test: Prisma schema対象"
printf '#!/bin/bash\nprintf '\''model AddedSubject {}\\n'\'' >> prisma/schema.prisma\nprintf '\''{"type":"text","text":"schema added"}\\n'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" errand "${DELEGATE_TIMEOUT_ARGS[@]}" errand-prisma-schema '既存規約に従いPrisma modelを追加する' -- prisma/schema.prisma > delegate-errand-prisma.out 2>&1; then
  ok "delegate-worker: errandはschema.prismaの候補patchを作成"
else
  ng "delegate-worker: errandがschema.prismaを拒否"; cat delegate-errand-prisma.out
fi
PRISMA_RESULT_ROOT="$DELEGATE_REPO/.claude/tmp/worker/errand-prisma-schema"
if grep -Fq 'model AddedSubject' "$PRISMA_RESULT_ROOT/candidate.patch" && [ "$(jq -c '.changed_paths' "$PRISMA_RESULT_ROOT/result.json" 2>/dev/null)" = '["prisma/schema.prisma"]' ]; then
  ok "delegate-worker: Prisma変更を指定schemaだけに限定"
else
  ng "delegate-worker: Prisma候補patchの変更範囲が不正"
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" errand "${DELEGATE_TIMEOUT_ARGS[@]}" errand-migration-file 'migration fileを追加する' -- prisma/migrations/001.sql > delegate-errand-migration.out 2>&1; then
  ng "delegate-worker: migration fileを許可"
else
  ok "delegate-worker: migration fileを引き続き拒否"
fi
INTERRUPT_PID_FILE="$DELEGATE_REPO/interrupted-opencode.pid"
printf '#!/bin/bash\n/bin/sleep 0.01\n' > "$DELEGATE_BIN/sleep"
printf '#!/bin/bash\nprintf '\''%%s\\n'\'' "$$" > "%s"\nexec /bin/sleep 30\n' "$INTERRUPT_PID_FILE" > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/sleep" "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" interrupted-survey "$SURVEY_EXACT_IDENTIFIER の中断動作を調査する" > delegate-interrupted.out 2>&1 &
INTERRUPTED_RUNNER_PID=$!
INTERRUPT_WAIT_COUNT=0
while [ ! -f "$INTERRUPT_PID_FILE" ] && kill -0 "$INTERRUPTED_RUNNER_PID" 2>/dev/null && [ "$INTERRUPT_WAIT_COUNT" -lt 100 ]; do
  /bin/sleep 0.02
  INTERRUPT_WAIT_COUNT=$((INTERRUPT_WAIT_COUNT + 1))
done
INTERRUPTED_STATE="$DELEGATE_REPO/.claude/tmp/worker/.interrupted-survey.task/state.json"
PATH="$DELEGATE_BIN:$PATH" bash "$DELEGATE_SCRIPT" show interrupted-survey > delegate-show-running.out 2>&1
RUNNING_SHOW_STATUS=$?
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" interrupted-survey "$SURVEY_EXACT_IDENTIFIER の重複起動を試す" > delegate-duplicate.out 2>&1
DUPLICATE_STATUS=$?
if [ "$RUNNING_SHOW_STATUS" -eq 2 ] && grep -Fq '"effective_status": "running"' delegate-show-running.out && [ "$DUPLICATE_STATUS" -ne 0 ] && grep -Fq 'task is already active or has unfinished state' delegate-duplicate.out; then
  ok "delegate-worker: showで実行中を表示し同じtask-idの重複起動を拒否"
else
  ng "delegate-worker: 実行中表示または重複拒否が不正"; cat delegate-show-running.out; cat delegate-duplicate.out
fi
kill -TERM "$INTERRUPTED_RUNNER_PID" 2>/dev/null
wait "$INTERRUPTED_RUNNER_PID"
INTERRUPTED_STATUS=$?
INTERRUPTED_OPENCODE_PID=$(sed -n '1p' "$INTERRUPT_PID_FILE")
PATH="$DELEGATE_BIN:$PATH" bash "$DELEGATE_SCRIPT" show interrupted-survey > delegate-show-interrupted.out 2>&1
INTERRUPTED_SHOW_STATUS=$?
if [ "$INTERRUPTED_STATUS" -eq 143 ] && [ "$INTERRUPTED_SHOW_STATUS" -eq 1 ] && [ "$(jq -r '.lifecycle_status' "$INTERRUPTED_STATE" 2>/dev/null)" = "interrupted" ] && grep -Fq '"effective_status": "interrupted"' delegate-show-interrupted.out && ! kill -0 "$INTERRUPTED_OPENCODE_PID" 2>/dev/null && [ ! -e "$DELEGATE_REPO/.claude/tmp/worker/interrupted-survey" ]; then
  ok "delegate-worker: 親中断時にOpenCodeを終了してinterrupted状態を残す"
else
  ng "delegate-worker: 中断cleanupまたは状態記録が不正"; cat delegate-interrupted.out; cat delegate-show-interrupted.out
fi
rm -f "$DELEGATE_BIN/sleep" "$INTERRUPT_PID_FILE"
TIMEOUT_CLOCK="$DELEGATE_REPO/timeout-clock"
TIMEOUT_PID_FILE="$DELEGATE_REPO/timeout-opencode.pid"
printf '#!/bin/bash\nCLOCK_FILE="%s"\nvalue=$(sed -n '\''1p'\'' "$CLOCK_FILE")\nvalue=$((value + 61))\nprintf '\''%%s\\n'\'' "$value" > "$CLOCK_FILE"\nprintf '\''%%s\\n'\'' "$value"\n' "$TIMEOUT_CLOCK" > "$DELEGATE_BIN/date"
printf '#!/bin/bash\nif [ "${1:-}" = "5" ]; then /bin/sleep 0.2; fi\nexit 0\n' > "$DELEGATE_BIN/sleep"
printf '0\n' > "$TIMEOUT_CLOCK"
printf '#!/bin/bash\nprintf '\''%%s\\n'\'' "$$" > "%s"\nexec /bin/sleep 30\n' "$TIMEOUT_PID_FILE" > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/date" "$DELEGATE_BIN/sleep" "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" timeout-idle-survey "$SURVEY_EXACT_IDENTIFIER の同型実装を調査する" > delegate-timeout-idle.out 2>&1
IDLE_TIMEOUT_STATUS=$?
IDLE_TIMEOUT_ROOT="$DELEGATE_REPO/.claude/tmp/worker/timeout-idle-survey"
IDLE_TIMEOUT_PID=$(sed -n '1p' "$TIMEOUT_PID_FILE")
if [ "$IDLE_TIMEOUT_STATUS" -eq 124 ] && [ "$(jq -r '.timed_out' "$IDLE_TIMEOUT_ROOT/result.json" 2>/dev/null)" = "true" ] && [ "$(jq -r '.timeout_kind' "$IDLE_TIMEOUT_ROOT/result.json" 2>/dev/null)" = "idle" ] && [ "$(jq -r '.status' "$IDLE_TIMEOUT_ROOT/result.json" 2>/dev/null)" = "124" ] && [ "$(jq -r '.idle_timeout_seconds' "$IDLE_TIMEOUT_ROOT/result.json" 2>/dev/null)" = "120" ] && [ "$(jq -r '.hard_timeout_seconds' "$IDLE_TIMEOUT_ROOT/result.json" 2>/dev/null)" = "240" ] && [ "$(jq -r '.termination_grace_seconds' "$IDLE_TIMEOUT_ROOT/result.json" 2>/dev/null)" = "10" ] && grep -Fxq 'Delegated model did not return a final textual report.' "$IDLE_TIMEOUT_ROOT/report.md" && ! kill -0 "$IDLE_TIMEOUT_PID" 2>/dev/null; then
  ok "delegate-worker: 無出力timeoutを124で記録してprocess groupを終了"
else
  ng "delegate-worker: 無出力timeoutの終了・記録が不正"; cat delegate-timeout-idle.out
fi
printf '0\n' > "$TIMEOUT_CLOCK"
printf '#!/bin/bash\nprintf '\''%%s\\n'\'' "$$" > "%s"\nprintf '\''{"type":"step_start","timestamp":1}\\n'\''\nprintf '\''{"type":"text","timestamp":2,"text":"partial"}\\n'\''\nwhile :; do\n  /bin/sleep 0.05\n  printf '\''{"type":"step_start","timestamp":3}\\n'\''\ndone\n' "$TIMEOUT_PID_FILE" > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" timeout-hard-survey "$SURVEY_EXACT_IDENTIFIER の同型実装を調査する" > delegate-timeout-hard.out 2>&1
HARD_TIMEOUT_STATUS=$?
HARD_TIMEOUT_ROOT="$DELEGATE_REPO/.claude/tmp/worker/timeout-hard-survey"
HARD_TIMEOUT_PID=$(sed -n '1p' "$TIMEOUT_PID_FILE")
if [ "$HARD_TIMEOUT_STATUS" -eq 124 ] && [ "$(jq -r '.timeout_kind' "$HARD_TIMEOUT_ROOT/result.json" 2>/dev/null)" = "hard" ] && grep -Fxq 'Delegated model did not return a final textual report.' "$HARD_TIMEOUT_ROOT/report.md" && ! grep -Fq 'partial' "$HARD_TIMEOUT_ROOT/report.md" && ! kill -0 "$HARD_TIMEOUT_PID" 2>/dev/null; then
  ok "delegate-worker: 総時間timeoutで部分出力を最終reportへ昇格しない"
else
  ng "delegate-worker: 総時間timeoutまたは部分出力の扱いが不正"; cat delegate-timeout-hard.out; cat "$HARD_TIMEOUT_ROOT/result.json"
fi
rm -f "$DELEGATE_BIN/date" "$DELEGATE_BIN/sleep" "$TIMEOUT_CLOCK" "$TIMEOUT_PID_FILE"
printf '#!/bin/bash\nprintf '\''changed ignored rule\\n'\'' > .codex/rules/ignored.rules\nprintf '\''{"type":"text","text":"done"}\\n'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" rejected-context-mutation 'ignored ruleを調査する' > delegate-rejected-context.out 2>&1; then
  ng "delegate-worker: 読み取りsnapshotの変更を許可した"
elif grep -Fq 'delegated model changed an ignored context file: .codex/rules/ignored.rules' delegate-rejected-context.out && [ ! -e "$DELEGATE_REPO/.claude/tmp/worker/rejected-context-mutation" ]; then
  ok "delegate-worker: 読み取りsnapshotの変更をhash検証で拒否"
else
  ng "delegate-worker: 読み取りsnapshotの変更検出が不正"; cat delegate-rejected-context.out
fi
printf '#!/bin/bash\ntouch protected-change.txt\nprintf '\''{"type":"text","text":"done"}\\n'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" research "${DELEGATE_TIMEOUT_ARGS[@]}" rejected-research spec.md > delegate-rejected.out 2>&1; then
  ng "delegate-worker: research中の変更を許可した"
else
  ok "delegate-worker: research中の変更を拒否"
fi
if [ -e "$DELEGATE_REPO/.claude/tmp/worker/rejected-research" ]; then
  ng "delegate-worker: 後処理失敗の不完全な結果が残存"
else
  ok "delegate-worker: 後処理失敗の不完全な結果を残さない"
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
EB=$(grep '^BASE ' check.out | cut -d' ' -f2)
C1=$(git rev-parse HEAD~2); C2=$(git rev-parse HEAD~1); C3=$(git rev-parse HEAD)
printf '{"base":"%s","groups":[{"subject":"f1: f1と対応テストを追加した","commits":["%s","%s"]},{"subject":"f2.ts: f2を追加した","commits":["%s"]}]}\n' "$EB" "$C1" "$C2" "$C3" > plan.json
TREE_BEFORE=$(git rev-parse 'HEAD^{tree}')
if bash "$RS" plan.json --base "$BASE" > run.out 2>&1; then ok "squash 実行"; else ng "squash 失敗"; cat run.out; fi
[ "$(git rev-list --count "$EB..HEAD")" = "2" ] && ok "3→2 コミットへ縮約" || ng "コミット数が不正"
[ "$(git rev-parse 'HEAD^{tree}')" = "$TREE_BEFORE" ] && ok "tree 同一性" || ng "tree が変わった"
git branch --list 'backup/rebase-*' | grep -q . && ng "backup ブランチが残っている" || ok "成功時に backup ブランチを残さない"
git reflog show HEAD --format=%H | grep -qFx "$C3" && ok "元 HEAD を reflog から辿れる" || ng "元 HEAD が reflog から失われた"
grep -q "$C3" run.out && ok "報告に元 HEAD の sha を含む" || { ng "元 HEAD の sha を報告していない"; cat run.out; }
if bash "$RS" plan.json --base "$BASE" > again.out 2>&1; then ng "base 不一致 plan が通ってしまった"; else ok "base 不一致 plan を拒否"; fi
printf '{"base":"%s","groups":[{"subject":"タグ無し不正subject","commits":["%s"]}]}\n' "$(git rev-parse HEAD)" "$(git rev-parse HEAD)" > bad.json
if bash "$RS" bad.json --base "$(git rev-parse 'HEAD~1')" > bad.out 2>&1; then ng "不正 subject が通ってしまった"; else ok "不正 subject を拒否"; fi
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
  mcp_server_prompts_by_default "$MCP_SERVER" .codex/config.toml || append_group_failure "未登録toolの既定値がpromptではない"
  APPROVED_COUNT=0
  while IFS= read -r MCP_TOOL; do
    APPROVED_COUNT=$((APPROVED_COUNT+1))
    mcp_tool_approved "$MCP_SERVER" "$MCP_TOOL" .codex/config.toml || append_group_failure "approve漏れ: $MCP_TOOL"
  done < <(jq -r --arg prefix "mcp__${MCP_SERVER}__" '.permissions.allow[] | select(startswith($prefix)) | ltrimstr($prefix)' "$REPO/claude/settings.local.json")
  if [ "$MCP_SERVER" = "serena" ]; then
    for MCP_TOOL in "${CODEX_CONTEXT_EXTRA_APPROVED_SERENA_TOOLS[@]}"; do
      APPROVED_COUNT=$((APPROVED_COUNT+1))
      mcp_tool_approved "$MCP_SERVER" "$MCP_TOOL" .codex/config.toml || append_group_failure "context固有approve漏れ: $MCP_TOOL"
    done
  fi
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
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- mkdir -p draft-prompt 2>/dev/null)
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
  # 引数なしで呼ぶ apply-prompt.sh が rules に一致するか（引数前提の書き方だと取りこぼす）
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/cowlick/apply-prompt.sh 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: 引数なし apply-prompt を allow" || ng "rules: apply-prompt 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/tdd/mark-prompt-done.sh user-api 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: mark-prompt-done の固定経路を allow" || ng "rules: mark-prompt-done 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/polish/quality-gate.sh user-api -- src/example.ts 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: quality-gate の固定経路を allow" || ng "rules: quality-gate 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/polish/capture-scope.sh user-api -- src/example.ts 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: polish scope記録の固定経路を allow" || ng "rules: polish scope記録判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/worker/delegate.sh research --hard-timeout-minutes 10 --idle-timeout-seconds 120 --poll-seconds 5 --timeout-reason scope=spec,difficulty=medium,basis=contract-review task-id .codex/prompt/branch-task-prompt.md 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: delegate-worker の固定経路を allow" || ng "rules: delegate-worker 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/worker/delegate.sh smoke 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "prompt" ] && ok "rules: 課金smokeだけを prompt" || ng "rules: worker smoke判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- ./base/scripts/run-unit.sh test/features/purchase/unit/device-discount-utils.test.ts test/features/purchase/unit/purchase-api.integration.test.ts 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: 承認済みunit test runnerを allow" || ng "rules: unit test runner判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash ./base/scripts/run-unit.sh test/features/purchase/unit/device-discount-utils.test.ts 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.matchedRules | length' 2>/dev/null)" = "0" ] && ok "rules: unit test runnerのallowを別起動形式へ拡張しない" || ng "rules: unit test runner許可が過剰 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/rebase/rebase.sh --check 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: rebase事前確認をallow" || ng "rules: rebase事前確認判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/rebase/rebase.sh node_modules/.cache/rebase-plan.json 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: rebase plan実行をallow" || ng "rules: rebase plan実行判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .codex/hooks/shell/protect-review.sh approve apps/api/infra/main.tf 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "prompt" ] && ok "rules: review対象の変更承認を prompt" || ng "rules: review対象の承認判定失敗 out=[$OUT]"
else
  echo "skip codex CLI が無いため config / rules 実機検査を省略"
fi

echo "== 5.5 session marker と発火スコープ（codex） =="
H=.codex/hooks/shell
UP=$(jq -n --arg cwd "$PWD" '{hook_event_name:"UserPromptSubmit",session_id:"SESS1",cwd:$cwd,prompt:"$tdd src/foo.ts を回して",model:"m",permission_mode:"default",transcript_path:null,turn_id:"t"}')
echo "$UP" | bash $H/session.sh
[ -f .codex/tmp/session.tdd.SESS1 ] && ok "session: \$tdd 起動で marker 記録" || ng "session: marker 記録失敗"
UP2=$(jq -n --arg cwd "$PWD" '{hook_event_name:"UserPromptSubmit",session_id:"SESS9",cwd:$cwd,prompt:"tdd について教えて",model:"m",permission_mode:"default",transcript_path:null,turn_id:"t"}')
echo "$UP2" | bash $H/session.sh
[ ! -f .codex/tmp/session.tdd.SESS9 ] && ok "session: \$ 無しの言及では発火しない" || ng "session: 誤発火"
UPM=$(jq -n --arg cwd "$PWD" '{hook_event_name:"UserPromptSubmit",session_id:"MEET1",cwd:$cwd,prompt:"$meeting 新機能を設計して",model:"m",permission_mode:"default",transcript_path:null,turn_id:"t"}')
echo "$UPM" | bash $H/session.sh
COWLICK_PATCH=$(jq -n --arg cwd "$PWD" '{session_id:"MEET1",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: draft-prompt/branch-sample-prompt.md\n+x\n*** End Patch"}}')
COWLICK_LOAD=$(echo "$COWLICK_PATCH" | bash $H/load-required-contract.sh)
if [ "$(echo "$COWLICK_LOAD" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && echo "$COWLICK_LOAD" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -Fq '## Changes'; then
  ok "required-reading: Codex meetingの初回draft編集で設計形式を注入"
else
  ng "required-reading: Codex meetingで設計形式を注入できない"
fi
[ -z "$(echo "$COWLICK_PATCH" | bash $H/load-required-contract.sh)" ] && ok "required-reading: Codex設計形式receipt後は棄権" || ng "required-reading: Codex設計形式receiptを再利用できない"
AP=$(jq -n --arg cwd "$PWD" '{session_id:"SESS1",turn_id:"t1",transcript_path:"/tmp/x.jsonl",cwd:$cwd,hook_event_name:"PreToolUse",model:"gpt-5.5",permission_mode:"bypassPermissions",tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: src/foo.ts\n+x\n*** End Patch\n"},tool_use_id:"call_x"}')
OUT=$(echo "$AP" | bash $H/require-test.sh)
[ "$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && ok "require-test: marker 一致で執行(実機同形ペイロード)" || ng "require-test: marker 一致 out=[$OUT]"
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
jq -e '.permissions.ask | index("Bash(bash .claude/skills/worker/delegate.sh smoke)")' "$SL" >/dev/null 2>&1 && ok "Claude: 課金smokeだけをask" || ng "Claude: worker smokeのask漏れ"
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
jq -e '.sandbox.excludedCommands | (index("./base/scripts/run-unit.sh") != null and index("./base/scripts/run-unit.sh *") != null)' "$SJ" >/dev/null 2>&1 && jq -e '.permissions.allow | (index("Bash(./base/scripts/run-unit.sh)") != null and index("Bash(./base/scripts/run-unit.sh:*)") != null)' "$SL" >/dev/null 2>&1 && ok "Claude: 承認済みunit test runnerをlocalでallow" || ng "Claude: unit test runnerの自動実行設定が不足"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("protect-locks.sh"))] | length' "$SJ")" = "$EXPECTED_DUAL_HOOK_BINDINGS" ] && ok "Claude lockfile保護hookをBash/Editへ配線" || ng "Claude lockfile保護hookの配線漏れ"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("load-required-contract.sh"))] | length' "$SJ")" = "1" ] && grep -Fq 'load-required-contract.sh cowlick-design' "$REPO/skills/cowlick/SKILL.md" && ok "Claude必須契約hookをworker/cowlickへ配線" || ng "Claude必須契約hookの配線漏れ"
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
for SC in bootstrap/init-agent.sh cowlick/apply-prompt.sh tdd/mark-prompt-done.sh polish/quality-gate.sh polish/capture-scope.sh worker/delegate.sh e2e/apply-e2e-plan.sh; do
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
