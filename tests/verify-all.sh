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
SURVEY_REQUEST_VALIDATOR="$REPO/skills/worker/validate-survey-request.sh"
CLAUDE_IMPLEMENTER="$REPO/claude/agents/implementer.md"
CODEX_IMPLEMENTER="$REPO/codex/agents/implementer.toml"
IMPLEMENTATION_SCOPE_HOOK="$REPO/hooks/shell/protect-implementation-scope.sh"
IMPLEMENTER_READ_SCRIPT="$REPO/skills/tdd/implementer-read.sh"
IMPLEMENTER_PREFLIGHT_SCRIPT="$REPO/skills/tdd/preflight-implementer.sh"
[ -x "$WORKER_RUNNER" ] || append_group_failure "exec bit: $WORKER_RUNNER"
[ -x "$IMPLEMENTER_READ_SCRIPT" ] || append_group_failure "exec bit: $IMPLEMENTER_READ_SCRIPT"
[ -x "$IMPLEMENTER_PREFLIGHT_SCRIPT" ] || append_group_failure "exec bit: $IMPLEMENTER_PREFLIGHT_SCRIPT"
report_group "実行ビット: hookと実行器全件" "$GROUP_FAILURES"
grep -q 'SOFT_BUDGET_USD="38"' "$WORKER_RUNNER" && grep -q 'HARD_BUDGET_USD="40"' "$WORKER_RUNNER" && ok "外部ワーカー予算: soft=38 hard=40" || ng "外部ワーカー予算が不正"
grep -q 'DEFAULT_MODEL="openrouter/minimax/minimax-m3"' "$WORKER_RUNNER" && grep -Fq 'MODEL="${DELEGATE_MODEL:-$DEFAULT_MODEL}"' "$WORKER_RUNNER" && grep -Fq 'MODEL_ID="${MODEL#openrouter/}"' "$WORKER_RUNNER" && ok "外部ワーカーモデル: MiniMax M3を既定値として差し替え可能" || ng "外部ワーカーモデルの既定値または差し替えが不正"
grep -Fq 'MODEL_VARIANT="${DELEGATE_MODEL_VARIANT:-}"' "$WORKER_RUNNER" && grep -q -- '--arg model_variant "$MODEL_VARIANT"' "$WORKER_RUNNER" && grep -q 'model_variant:(if $model_variant == "" then null else $model_variant end)' "$WORKER_RUNNER" && grep -q 'OPENCODE_COMMAND+=(--variant "$MODEL_VARIANT")' "$WORKER_RUNNER" && ! grep -q 'reasoningEffort' "$WORKER_RUNNER" && ok "外部ワーカーvariant: 既定はadaptive、明示時だけ指定" || ng "外部ワーカーvariantの任意指定が不正"
grep -q 'MISSING_REPORT_STATUS="65"' "$WORKER_RUNNER" && grep -q 'MALFORMED_REPORT_STATUS="66"' "$WORKER_RUNNER" && grep -q 'PARTIAL_REPORT_STATUS="67"' "$WORKER_RUNNER" && grep -q 'report_status:\$report_status' "$WORKER_RUNNER" && ok "worker report: 欠落・破損・部分応答を別statusへ分類" || ng "worker reportのprotocol失敗分類が不足"
grep -q '^build_evidence_packet()' "$WORKER_RUNNER" && grep -q '^claims_have_evidence()' "$WORKER_RUNNER" && grep -Fq 'code below was not copied by the worker' "$WORKER_RUNNER" && grep -q -- '--argjson evidence "$EVIDENCE_JSON"' "$WORKER_RUNNER" && ok "worker evidence: snapshotからclaim根拠を抽出" || ng "worker evidenceの抽出・記録処理が不足"
grep -q 'MAX_EVIDENCE_REFERENCES="20"' "$WORKER_RUNNER" && grep -q 'RECOMMENDED_EVIDENCE_REFERENCES="12"' "$WORKER_RUNNER" && grep -Fq 'MAX_SURVEY_CLAIMS="$MAX_SURVEY_REQUEST_CLAIMS"' "$WORKER_RUNNER" && grep -q 'MAX_SURVEY_EVIDENCE_PER_CLAIM="3"' "$WORKER_RUNNER" && grep -q 'MAX_EVIDENCE_LINES_PER_REFERENCE="80"' "$WORKER_RUNNER" && grep -q 'MAX_EVIDENCE_TOTAL_LINES="400"' "$WORKER_RUNNER" && grep -Fq '1範囲あたり最大%s行' "$WORKER_RUNNER" && grep -Fq 'signature・対象branch/call・return/side effect' "$WORKER_RUNNER" && ok "worker evidence: validator定数をpromptと検証へ共有" || ng "worker evidenceのclaim・範囲上限またはprompt共有が不足"
if ! grep -Eq '^  (implement|errand)\)' "$WORKER_RUNNER" && grep -q 'mode must be research, survey, nesting, prepare, smoke, or show' "$WORKER_RUNNER"; then
  ok "workerは読み取り調査modeだけを公開"
else
  ng "workerに実装modeが残存"
fi
grep -q 'XDG_DATA_HOME="\$OPENCODE_XDG_DATA_HOME"' "$WORKER_RUNNER" && grep -q 'XDG_STATE_HOME="\$OPENCODE_XDG_STATE_HOME"' "$WORKER_RUNNER" && grep -q 'XDG_CACHE_HOME="\$OPENCODE_XDG_CACHE_HOME"' "$WORKER_RUNNER" && grep -q 'XDG_CONFIG_HOME="\$OPENCODE_XDG_CONFIG_HOME"' "$WORKER_RUNNER" && grep -q 'TMPDIR="\$OPENCODE_TMPDIR"' "$WORKER_RUNNER" && ok "worker OpenCode状態: task単位XDG・tmp分離" || ng "worker OpenCode状態: XDG・tmp分離が不足"
grep -q 'SURVEY_STEPS_PER_CLAIM="8"' "$WORKER_RUNNER" && grep -q 'MAX_SURVEY_REQUEST_CLAIMS="1"' "$WORKER_RUNNER" && grep -q 'SURVEY_FINALIZATION_STEPS="3"' "$WORKER_RUNNER" && grep -q 'SURVEY_OUTLINE_EXTRA_STEPS="4"' "$WORKER_RUNNER" && grep -Fq 'SURVEY_MAX_STEPS="$((SURVEY_CLAIM_COUNT * SURVEY_STEPS_PER_CLAIM + SURVEY_FINALIZATION_STEPS))"' "$WORKER_RUNNER" && grep -Fq 'SURVEY_MAX_STEPS="$((SURVEY_MAX_STEPS + SURVEY_OUTLINE_EXTRA_STEPS))"' "$WORKER_RUNNER" && grep -q '"steps":$survey_max_steps' "$WORKER_RUNNER" && grep -q -- '--agent delegate' "$WORKER_RUNNER" && ok "worker survey: 単一claimとzat有効時だけの追加stepを固定" || ng "worker surveyの単一claimまたはstep上限が不正"
grep -q 'SMOKE_IDLE_TIMEOUT_SECONDS="30"' "$WORKER_RUNNER" && grep -q 'requires explicit --hard-timeout-minutes' "$WORKER_RUNNER" && grep -q 'TIMEOUT_POLICY_SOURCE="explicit"' "$WORKER_RUNNER" && grep -q 'MIN_POLLS_PER_IDLE_WINDOW="3"' "$WORKER_RUNNER" && grep -q 'MIN_IDLE_WINDOWS_PER_HARD_TIMEOUT="2"' "$WORKER_RUNNER" && grep -q '^validate_timeout_reason()' "$WORKER_RUNNER" && grep -q -- '--arg timeout_reason "$TIMEOUT_REASON"' "$WORKER_RUNNER" && grep -q '^monitor_opencode()' "$WORKER_RUNNER" && grep -q 'last_event_type' "$WORKER_RUNNER" && grep -q 'valid_event_observed' "$WORKER_RUNNER" && grep -q '^terminate_process_group()' "$WORKER_RUNNER" && grep -q 'FINAL_STATUS=124' "$WORKER_RUNNER" && grep -q -- '--argjson timed_out "$TIMED_OUT"' "$WORKER_RUNNER" && ok "worker timeout: 有効event・明示値・理由・安全比率を検証して記録" || ng "worker timeout設定・event観測・理由記録が不正"
grep -q '^write_task_state()' "$WORKER_RUNNER" && grep -q '^stop_running_children()' "$WORKER_RUNNER" && grep -q 'task is already active or has unfinished state' "$WORKER_RUNNER" && grep -q 'effective_status' "$WORKER_RUNNER" && grep -q 'source_ref:\$source_ref' "$WORKER_RUNNER" && grep -q 'context_snapshot_paths' "$WORKER_RUNNER" && ok "worker lifecycle: task状態・重複拒否・revision snapshotを記録" || ng "worker lifecycle管理が不正"
grep -q -- '--arg model_id "$MODEL_ID"' "$WORKER_RUNNER" && ! grep -q 'MODEL_ID="$MODEL_ID".*jq' "$WORKER_RUNNER" && ok "worker config: readonly定数をjq引数で受け渡す" || ng "worker config: readonly変数への再代入が残存"
grep -q '"zdr":true' "$WORKER_RUNNER" && grep -q '"data_collection":"deny"' "$WORKER_RUNNER" && ok "worker routing: ZDRとdata collection拒否" || ng "worker routingのprivacy強制漏れ"
grep -Fq '{"*":"deny","zat *":"allow"}' "$WORKER_RUNNER" && grep -Fq 'EDIT_RULES='\''{"*":"deny"}'\''' "$WORKER_RUNNER" && grep -q '"external_directory":"deny"' "$WORKER_RUNNER" && grep -q 'opencode --pure run' "$WORKER_RUNNER" && ok "worker権限: editを全拒否しzat以外のshell・外部dir・pluginを拒否" || ng "workerの読み取り専用権限境界が不正"
grep -Fq '".git/**":"deny"' "$WORKER_RUNNER" && grep -Fq '"**/.env.*":"deny"' "$WORKER_RUNNER" && ! grep -Fq '".codex/**":"deny"' "$WORKER_RUNNER" && ! grep -Fq '".claude/**":"deny"' "$WORKER_RUNNER" && ! grep -Fq '".agents/**":"deny"' "$WORKER_RUNNER" && grep -Fq '隔離入力の.codex/**、.claude/**、.agents/**' "$WORKER_RUNNER" && ok "worker読み取り: agent設定を根拠として許可しGit・envを拒否" || ng "workerのagent設定・Git・env読み取り境界が不正"
grep -Fq 'trap cleanup EXIT' "$WORKER_RUNNER" && grep -Fq "trap 'exit 130' INT" "$WORKER_RUNNER" && grep -Fq "trap 'exit 143' TERM" "$WORKER_RUNNER" && ok "worker中断: cleanup後に処理を継続しない" || ng "workerのsignal終了処理が不正"
grep -q 'SMOKE_PROMPT="hello"' "$WORKER_RUNNER" && grep -q 'if \$mode == "smoke" then "deny"' "$WORKER_RUNNER" && ok "worker smoke: hello固定・tool全拒否" || ng "worker smokeのpromptまたは権限が不正"
grep -q '^  nesting)' "$WORKER_RUNNER" && grep -q '修正案・コード変更は不要です' "$WORKER_RUNNER" && grep -q 'nesting path must be tracked' "$WORKER_RUNNER" && ok "worker nesting: 本体コードだけを読み取り検出" || ng "worker nesting検出モードが不正"
grep -q '^  survey)' "$WORKER_RUNNER" && grep -q 'survey mode requires task id and one structured request JSON argument' "$WORKER_RUNNER" && grep -q 'validate-survey-request.sh' "$WORKER_RUNNER" && grep -q 'failed validation before external execution' "$WORKER_RUNNER" && grep -q 'anchorsの完全一致、機能語・ドメイン語、隣接モジュール、リポジトリ全体の順' "$WORKER_RUNNER" && grep -Fq '別kindの定義' "$WORKER_RUNNER" && ok "worker survey: 構造化依頼を外部実行前に検証して段階調査" || ng "worker surveyの構造化依頼または段階調査契約が不正"
VALID_SURVEY_REQUEST='{"purpose":"移植元の変換規則を確認する","claims":[{"id":"C1","kind":"behavior","subject":"固定長入力変換","question":"入力から出力列を生成する規則は何か","anchors":["sagawa-delivery-import","tool-def.tsx"],"done_when":"入力位置と出力列を直接示す根拠がある","exclude":["admin-2026","全test基盤"]}]}'
INVALID_SURVEY_REQUEST='{"purpose":"境界を詰め込む","claims":[]}'
MULTI_SURVEY_REQUEST='{"purpose":"旧新を同時に調べる","claims":[{"id":"C1","kind":"behavior","subject":"旧実装","question":"旧実装の入力は何か","anchors":["old"],"done_when":"入力の根拠がある","exclude":["current"]},{"id":"C2","kind":"behavior","subject":"現実装","question":"現実装の入力は何か","anchors":["current"],"done_when":"入力の根拠がある","exclude":["old"]}]}'
DENSE_SURVEY_REQUEST='{"purpose":"過密claimを拒否する","claims":[{"id":"C1","kind":"behavior","subject":"同期batch","question":"入口、入力、変換、保存、出力をすべて確認せよ","anchors":["sync"],"done_when":"全体の根拠がある","exclude":["test"]}]}'
DENSE_SURVEY_ERROR=$(bash "$SURVEY_REQUEST_VALIDATOR" "$DENSE_SURVEY_REQUEST" 2>&1)
DENSE_SURVEY_STATUS=$?
if [ -x "$SURVEY_REQUEST_VALIDATOR" ] && bash "$SURVEY_REQUEST_VALIDATOR" "$VALID_SURVEY_REQUEST" | jq -e '.claims[0].id == "C1" and .claims[0].kind == "behavior"' >/dev/null && ! bash "$SURVEY_REQUEST_VALIDATOR" "$INVALID_SURVEY_REQUEST" >/dev/null 2>&1 && ! bash "$SURVEY_REQUEST_VALIDATOR" "$MULTI_SURVEY_REQUEST" >/dev/null 2>&1 && [ "$DENSE_SURVEY_STATUS" -ne 0 ] && printf '%s' "$DENSE_SURVEY_ERROR" | grep -Fq 'C1.question has 4 enumerators (maximum 2)'; then
  ok "worker survey validator: 1 task 1 claimと列挙密度を外部実行前に強制"
else
  ng "worker survey validatorの単一claimまたは密度検証が不正"
fi
grep -Fq 'git worktree add --detach "$WORKTREE" "$SOURCE_COMMIT"' "$WORKER_RUNNER" && grep -Fq -- '--source-ref is only valid for survey and research' "$WORKER_RUNNER" && grep -Fq 'read-only delegated model changed a protected path' "$WORKER_RUNNER" && ok "worker snapshot: revisionを固定し変更を機械拒否" || ng "workerのrevision snapshotまたは読み取り専用検査が不正"
grep -Fq 'Evidenceのpath、開始行、終了行、件数は追加・削除・変更してはなりません' "$WORKER_RUNNER" && grep -Fq 'repair parent must have formatting-only invalid_output' "$WORKER_RUNNER" && grep -q 'EVIDENCE_FAILURE_KIND="range_too_wide"' "$WORKER_RUNNER" && grep -q 'NEXT_ACTION="supplement"' "$WORKER_RUNNER" && grep -q 'FAILURE_CLASS="step_limit_exhausted"' "$WORKER_RUNNER" && ok "worker再試行: 形式修正と意味上の証拠補完を機械分離" || ng "worker再試行のrepair・supplement分類が不正"
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
WORKER_CONTRACT="$REPO/skills/worker/DELEGATION.md"
COWLICK_FORMAT="$REPO/skills/cowlick/DESIGN_FORMAT.md"
REQUIRED_READING_HOOK="$REPO/hooks/shell/load-required-contract.sh"
for SKILL_FILE in "$MEETING_SKILL" "$PREFLIGHT_SKILL" "$COWLICK_SKILL" "$PONYTAIL_SKILL"; do
  [ -f "$SKILL_FILE" ] && ok "design skill存在: $(basename "$(dirname "$SKILL_FILE")")" || ng "design skill不在: $SKILL_FILE"
done
grep -q '^disable-model-invocation: true$' "$MEETING_SKILL" && grep -Fq 'ユーザーが `$meeting` を明示して' "$MEETING_SKILL" && grep -Fq '`$meeting` の明示呼び出しでだけ起動する' "$MEETING_SKILL" && grep -Fq '通常の自然言語による軽微な修正・追加依頼では起動しない' "$MEETING_SKILL" && grep -Fq '  - Skill(preflight)' "$MEETING_SKILL" && grep -Fq '  - Skill(cowlick *)' "$MEETING_SKILL" && grep -Fq '  - Skill(ponytail)' "$MEETING_SKILL" && grep -Fq '  - AskUserQuestion' "$MEETING_SKILL" && grep -Fq '  - Bash' "$MEETING_SKILL" && ok "meetingを明示起動だけに限定する" || ng "meetingの起動境界・skill境界が不正"
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
grep -Fq 'bash [skills_root]/worker/delegate.sh prepare' "$MEETING_SKILL" && grep -Fq '各内部skillで`prepare`を繰り返さない' "$MEETING_SKILL" && grep -Fq 'workerの`survey`へ委任' "$PREFLIGHT_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh survey' "$PREFLIGHT_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh research' "$COWLICK_SKILL" && grep -Fq 'workerの`survey`へ委任' "$PONYTAIL_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh survey' "$PONYTAIL_SKILL" && grep -Fq 'worker/DELEGATION.md' "$REQUIRED_READING_HOOK" && ok "meetingが一度prepareして設計調査を固定実行器へ接続" || ng "meetingのprepareまたは設計調査の固定実行器が不正"
grep -Fq '同じ調査を並行委任しない' "$WORKER_CONTRACT" && grep -Fq 'コード、test、schema、設定、設計書の作成・変更、実装案の生成' "$WORKER_CONTRACT" && grep -Fq '一つの変更判断に必要な最小の事実だけを聞く' "$WORKER_CONTRACT" && grep -Fq '初回を含め三回で止める' "$WORKER_CONTRACT" && grep -Fq 'smokeはユーザーが明示許可した時だけ実行する' "$WORKER_CONTRACT" && ok "worker共通契約は読み取り調査と上位モデルの判断境界へ限定" || ng "worker共通契約の読み取り専用境界が不足"
grep -Fq 'claims_follow_contract "$report_path"' "$WORKER_RUNNER" && grep -Fq 'MAX_RENDERED_REPORT_LINES="300"' "$WORKER_RUNNER" && grep -Fq 'full artifact:' "$WORKER_RUNNER" && ! grep -Fq 'candidate.patch' "$WORKER_RUNNER" && grep -Fq -- '--repair-of' "$WORKER_RUNNER" && grep -Fq 'or $repair_of != "" then "deny"' "$WORKER_RUNNER" && ok "worker結果はrunnerが形式を検証し調査artifactだけを保持" || ng "worker結果の形式検証または調査artifact保持が不足"
grep -Fq 'EVIDENCE_CONTEXT_LINES="8"' "$WORKER_RUNNER" && grep -Fq 'MAX_INFORMATION_ATTEMPTS="3"' "$WORKER_RUNNER" && grep -Fq '初回を含め三回で止める' "$WORKER_CONTRACT" && grep -Fq '広域探索やfile全体のReadはしない' "$WORKER_CONTRACT" && grep -Fq '再surveyより有利な理由を残す' "$WORKER_CONTRACT" && ok "worker不足は限定再調査と例外的な直接確認へ固定" || ng "worker再調査・上位直接確認の境界が不足"
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
grep -Fq '次は書式と密度の例であり、この処理自体を要件として流用しない' "$COWLICK_FORMAT" && grep -Fq '候補一覧[].length' "$COWLICK_FORMAT" && grep -Fq '候補一覧[].slice(...)' "$COWLICK_FORMAT" && grep -Fq '利用結果{}' "$COWLICK_FORMAT" && grep -Fq 'for (const 使用候補 of 使用候補一覧[])' "$COWLICK_FORMAT" && grep -Fq 'return 利用結果{}' "$COWLICK_FORMAT" && ok "cowlick疑似コードの正例" || ng "cowlick疑似コードの正例が不足"
grep -q '## 必須監査成果物' "$PONYTAIL_SKILL" && grep -Fq '`ponytail_audit`' "$PONYTAIL_SKILL" && grep -Fq '`minimalAlternative`' "$PONYTAIL_SKILL" && grep -Fq '`counterexamples`' "$PONYTAIL_SKILL" && grep -Fq '`unresolved`' "$PONYTAIL_SKILL" && grep -q '何も削らなかった場合' "$PONYTAIL_SKILL" && grep -q '全fieldが埋まり.*ponytail_ready' "$PONYTAIL_SKILL" && ok "ponytailの横断削除・ready gate契約" || ng "ponytailの横断削除・ready gate契約が不足"
grep -Fq '入口、共有責務、全caller・consumer' "$PONYTAIL_SKILL" && grep -Fq '報告された症状とroot causeを分ける' "$PONYTAIL_SKILL" && grep -Fq '実装が一つだけのinterface' "$PONYTAIL_SKILL" && grep -Fq '測定可能な条件' "$PONYTAIL_SKILL" && grep -Fq '[delete|reuse|stdlib|native|yagni|shrink]' "$PONYTAIL_SKILL" && grep -Fq '最小の実行可能なテスト' "$PONYTAIL_SKILL" && ok "ponytailの理解・root cause・簡素化負債契約" || ng "ponytailの理解または簡素化境界が不足"
grep -Fq '重複説明と同一の外枠だけを統合' "$PONYTAIL_SKILL" && grep -Fq 'where・sort・tie-break' "$PONYTAIL_SKILL" && grep -Fq '文章一行へ畳まない' "$PONYTAIL_SKILL" && ok "ponytailは実装契約を失う圧縮を禁止" || ng "ponytailが疑似コードの重要契約を圧縮可能"
grep -Fq '同一file内の呼び出しを外部consumerに数えず' "$PONYTAIL_SKILL" && grep -Fq '別の値から導ける定数' "$PONYTAIL_SKILL" && grep -Fq '`counterexamples`' "$PONYTAIL_SKILL" && grep -Fq '実装ファイルがまだ存在しないことだけを理由に `blocked` にしない' "$PONYTAIL_SKILL" && ok "ponytailの要素単位consumer・反例監査契約" || ng "ponytailの要素単位consumerまたは反例監査契約が不足"
grep -Fq '一つのfindingはIDを付けて一度だけ説明' "$PONYTAIL_SKILL" && grep -Fq '同じ要件・原因・判断・置換先を持つ要素は一行へまとめる' "$PONYTAIL_SKILL" && grep -Fq '同じtopologyや根拠を別fieldで言い換えない' "$PONYTAIL_SKILL" && ok "ponytailの監査正本は重複せず簡潔" || ng "ponytailの監査成果物が重複可能"
grep -q 'ponytail_ready.*文字列だけでは通過させない' "$MEETING_SKILL" && grep -Fq '`ponytail_audit`の必須field' "$MEETING_SKILL" && grep -Fq '空の`unresolved`' "$MEETING_SKILL" && ok "meetingのponytail成果物検証" || ng "meetingがponytailのstatusだけを信用している"
grep -Fq 'topologyが入口から副作用まで繋がる' "$MEETING_SKILL" && grep -Fq '対応要件と直接の外部consumer' "$MEETING_SKILL" && grep -Fq '具体値の反例' "$MEETING_SKILL" && ok "meetingがponytailの主要成果物を独立検証" || ng "meetingのponytail独立検証が不足"
grep -Fq '`ponytail`の最後の設計レビューを下位モデルへ渡してはならない' "$MEETING_SKILL" && grep -Fq '設計判断、横断比較、採否、設計書の修正は[agent_name]が行う' "$PONYTAIL_SKILL" && ok "ponytailの最終設計判断を上位モデルへ固定" || ng "ponytailが設計判断を下位モデルへ委任できる"
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
[ -f "$WORKER_CONTRACT" ] || append_group_failure "worker共通契約なし"
[ -f "$COWLICK_FORMAT" ] || append_group_failure "cowlick設計形式なし"
[ -f "$REPO/skills/tdd/SCENARIO_FLOW.md" ] || append_group_failure "tdd/errand共通シナリオフローなし"
report_group "progressive disclosure参照が全件存在" "$GROUP_FAILURES"
if bash "$SUITE/verify-context-mcp.sh" > "$S/context-mcp.out" 2>&1; then
  ok "dictionary skillとMCP配布設定を統合"
else
  ng "dictionary skillまたはMCP配布設定が不正"
  cat "$S/context-mcp.out"
fi

echo "== 軽微な実装委任と全体調査委任 =="
ERRAND_SKILL="$REPO/skills/errand/SKILL.md"
SCENARIO_FLOW="$REPO/skills/tdd/SCENARIO_FLOW.md"
[ -f "$CLAUDE_IMPLEMENTER" ] && grep -q '^model: claude-sonnet-5$' "$CLAUDE_IMPLEMENTER" && grep -q '^effort: max$' "$CLAUDE_IMPLEMENTER" && grep -q '^tools: Read, Grep, Glob, Edit, Write$' "$CLAUDE_IMPLEMENTER" && ! grep -Eq '^tools:.*(Bash|Agent)' "$CLAUDE_IMPLEMENTER" && ok "Claude implementer: Sonnet 5 maxと非shell tool境界を固定" || ng "Claude implementerのmodel・effort・tool境界が不正"
[ -f "$CODEX_IMPLEMENTER" ] && grep -q '^model = "gpt-5.6-luna"$' "$CODEX_IMPLEMENTER" && grep -q '^model_reasoning_effort = "max"$' "$CODEX_IMPLEMENTER" && grep -q '^sandbox_mode = "workspace-write"$' "$CODEX_IMPLEMENTER" && ok "Codex implementer: Luna maxとworkspace writeを固定" || ng "Codex implementerのmodel・effort・sandbox境界が不正"
grep -Fq 'This is an implementation action, not a review, approval, or scenario-classification task' "$CLAUDE_IMPLEMENTER" "$CODEX_IMPLEMENTER" && grep -Fq 'an omitted or rejected test scenario never removes a requirement' "$CLAUDE_IMPLEMENTER" "$CODEX_IMPLEMENTER" && grep -Fq 'Do not return only an explanation or classification' "$CLAUDE_IMPLEMENTER" "$CODEX_IMPLEMENTER" && grep -Fq 'Outcome: implemented' "$CLAUDE_IMPLEMENTER" "$CODEX_IMPLEMENTER" && ok "implementer: test採否を実装省略に使わず分類回答を成功にしない" || ng "implementerの実装action・出力契約が不足"
grep -Fq '`claude/agents/` | `<repo>/.claude/agents/`' "$REPO/README.md" && grep -Fq '`codex/agents/` | `<repo>/.codex/agents/`' "$REPO/README.md" && ok "README: 両agent定義の配布先を明記" || ng "README: implementer定義の配布先が不足"
for IMPLEMENTER_FILE in "$CLAUDE_IMPLEMENTER" "$CODEX_IMPLEMENTER"; do
  if grep -Fq '半年後の保守者' "$IMPLEMENTER_FILE" && grep -Fq '不要なhelper分割、過度な抽象化、将来用の拡張点' "$IMPLEMENTER_FILE" && grep -Fq '`filter().map()`' "$IMPLEMENTER_FILE" && grep -Fq '`reduce()`' "$IMPLEMENTER_FILE" && grep -Fq '多少冗長でも読みやすい' "$IMPLEMENTER_FILE"; then
    ok "implementer可読性契約: $(basename "$IMPLEMENTER_FILE")"
  else
    ng "implementer可読性契約が不足: $IMPLEMENTER_FILE"
  fi
done
[ -f "$ERRAND_SKILL" ] && grep -q '^disable-model-invocation: true$' "$ERRAND_SKILL" && grep -q 'allow_implicit_invocation: false' "$REPO/skills/errand/agents/openai.yaml" && ok "errand スキルは明示起動だけ許可" || ng "errand スキルの明示起動境界が不正"
grep -Fq 'ユーザーが明示的にerrandを呼んだ場合だけ' "$ERRAND_SKILL" && grep -Fq 'meeting / cowlick / ponytail / tddは呼ばない' "$ERRAND_SKILL" && grep -Fq '識別子、path、番号、固有名詞を省略・翻訳・一般化しない' "$ERRAND_SKILL" && grep -Fq '最寄りの同型実装1件' "$ERRAND_SKILL" && grep -Fq 'validatorを通る`C1` 1件だけのJSON' "$ERRAND_SKILL" && grep -Fq '`--source-ref <revision>`' "$ERRAND_SKILL" && ok "errand は識別子を保持して単一claimのsurveyへ限定" || ng "errand の軽量調査境界が不正"
grep -q 'AskUserQuestion' "$ERRAND_SKILL" && grep -Fq 'command: .[agent_name]/hooks/shell/require-test.sh' "$ERRAND_SKILL" && grep -Fq '../tdd/SCENARIO_FLOW.md' "$ERRAND_SKILL" && grep -Fq '新しいテストまたはテストファイルが必要なことは停止理由にしない' "$ERRAND_SKILL" && grep -Fq 'ユーザーが選択したものだけをテストへ変換する' "$ERRAND_SKILL" && ok "errand はユーザー選択後のテスト追加を許可" || ng "errand が追加テストで停止またはユーザー選択なしで変更可能"
grep -Fq '必要な事実ごとにworkerの`survey`を別task-idで実行' "$ERRAND_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh prepare' "$ERRAND_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh survey' "$ERRAND_SKILL" && grep -Fq 'implementerへ判断に使った検証済みsurvey task-idとartifact pathを全件渡し' "$ERRAND_SKILL" && grep -Fq 'implementerにテスト、設定、migration、Git、設計資産を変更させない' "$ERRAND_SKILL" && ok "errand はworker調査と専用implementer実装を分離" || ng "errand のworker調査・implementer実装境界が不正"
grep -Fq '同型実装から名前・内容を一意に決められる新規本体ファイル' "$ERRAND_SKILL" && grep -q '親directoryが存在しない' "$REPO/skills/polish/capture-scope.sh" && grep -q 'ignoredされている' "$REPO/skills/polish/capture-scope.sh" && ok "errand は一意な定型ファイル追加だけ許可" || ng "errand の新規ファイル境界が不正"
grep -Fq '未実装、複数、または対応テストが未作成であることだけを理由に停止しない' "$ERRAND_SKILL" && grep -Fq 'schema.prisma' "$ERRAND_SKILL" && grep -Fq 'migration fileの作成' "$ERRAND_SKILL" && ok "errand は複数path・未作成test・Prisma schemaを許可しmigrationを禁止" || ng "errand の複数path・test・Prisma境界が不正"
grep -Fq '初回実装は専用`implementer` subagent' "$ERRAND_SKILL" && grep -Fq 'cleanな許可pathに限り一度だけ再起動' "$ERRAND_SKILL" && grep -Fq '修正をworkerまたはimplementerへ再委任しない' "$ERRAND_SKILL" && grep -Fq '修正する／しない、部分採用、全体拒否の判断は上位モデル' "$ERRAND_SKILL" && ok "errand は専用subagent初回実装・上位モデル判断とfallbackへ固定" || ng "errand の初回実装・修正責務が不正"
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
[ -x "$CAPTURE_SCOPE_SCRIPT" ] && bash -n "$CAPTURE_SCOPE_SCRIPT" && [ -x "$IMPLEMENTATION_SCOPE_HOOK" ] && bash -n "$IMPLEMENTATION_SCOPE_HOOK" && [ -x "$IMPLEMENTER_READ_SCRIPT" ] && [ -x "$IMPLEMENTER_PREFLIGHT_SCRIPT" ] && grep -Fq 'capture-scope.sh <機能名> -- <相対path>...' "$TDD_SKILL" && grep -Fq 'preflight-implementer.sh [agent_name]' "$SCENARIO_FLOW" && grep -Fq 'capture-scope.sh activate <scope名>' "$SCENARIO_FLOW" && grep -Fq 'capture-scope.sh handoff-to-parent <scope名>' "$SCENARIO_FLOW" && grep -Fq 'capture-scope.sh deactivate <scope名>' "$SCENARIO_FLOW" && grep -Fq 'capture-scope.sh list-changed <機能名>' "$TDD_SKILL" && ok "tdd は開始scope・実装mode・安全な読み取り・実変更pathを固定" || ng "tdd のscope selectorまたは実装scope hookが不正"
grep -Fq 'quality-gate.sh <機能名> -- <実変更path>...' "$POLISH_SKILL" && grep -Fq '現在の入力pathを「基準commitから実際に変更され、現在存在するfile」の一覧と順序込みで完全一致' "$POLISH_SKILL" && grep -Fq '入力された実変更pathだけが追跡済みかつclean' "$POLISH_SKILL" && grep -Fq '完了receiptの記録や後続での再検証は行わない' "$POLISH_SKILL" && grep -Fq '独自のESLint rule、`no-magic-numbers`、import規則を追加しない' "$POLISH_SKILL" && ! grep -Eq 'eslint|no-magic-numbers|no-restricted-syntax' "$QUALITY_GATE_SCRIPT" && ok "polish は実変更path一致とtracked・cleanだけを単回検査" || ng "polish の実変更path検査が不正"
! grep -Fq 'quality-gate.sh' "$MARK_PROMPT_DONE_SCRIPT" && grep -Fq '完了マークを付けるか明示的に確認する' "$TDD_SKILL" && grep -Fq 'ユーザーが付けると回答した場合だけ' "$TDD_SKILL" && ok "tdd はユーザー判断だけでindexを更新" || ng "tdd が完了マークを自動判定"
grep -Fq 'SCENARIO_FLOW.md' "$TDD_SKILL" && grep -Fq '../tdd/SCENARIO_FLOW.md' "$ERRAND_SKILL" && [ -f "$SCENARIO_FLOW" ] && grep -Fq '`tdd`と`errand`は、調査後の実装をこの契約へ集約する' "$SCENARIO_FLOW" && ok "tddとerrandはシナリオ駆動実装を一つの共通契約へ集約" || ng "tddとerrandの共通フロー参照が不正"
grep -Fq 'workerの`survey`へ委任' "$TDD_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh prepare' "$TDD_SKILL" && grep -Fq 'bash [skills_root]/worker/delegate.sh survey' "$TDD_SKILL" && grep -Fq 'subagentが利用不能またはcleanな再実行も失敗した場合だけ可' "$TDD_SKILL" && grep -Fq '初回実装後の本体コード修正 | 可 | 禁止 | 禁止' "$TDD_SKILL" && ok "tdd はworker調査・専用subagent初回実装・上位fallbackと修正へ固定" || ng "tdd の調査・実装・fallback・修正境界が不正"
grep -Fq '設計書を選んでから共通フローでimplementerの初回実装を受領するまで' "$TDD_SKILL" && grep -Fq '`evidence_status: verified`のコードがclaimを直接支え' "$TDD_SKILL" && grep -Fq '`--supplement-of`で初回を含む合計3回まで限定survey' "$TDD_SKILL" && grep -Fq '3回目までは保存範囲の不足自体を直接確認の理由にしない' "$TDD_SKILL" && grep -Fq '全file Read、path発見のためのRead' "$TDD_SKILL" && ok "tdd は検証済みevidenceを標準根拠、直接探索を例外へ固定" || ng "tdd が上位モデルの無条件再探索を許可"
grep -Fq '## 1. テストシナリオ候補をまとめて提示する' "$SCENARIO_FLOW" && grep -Fq '採用するシナリオ、外すシナリオ、修正点を指定してください。' "$SCENARIO_FLOW" && grep -Fq '全件採用を既定または要求する言い方をしない' "$SCENARIO_FLOW" && grep -Fq 'どの候補を採用・不採用・修正するかはユーザーが決める' "$SCENARIO_FLOW" && grep -Fq '実装要件や実装要否を提案・再分類しない' "$SCENARIO_FLOW" && grep -Fq '実装要件を省略する根拠にしてはならない' "$SCENARIO_FLOW" && grep -Fq '選択が確定するまでファイルを変更しない' "$SCENARIO_FLOW" && grep -Fq 'workerにはシナリオ、期待値、assertion、fixture構成、テストコードを提案または変更させない' "$SCENARIO_FLOW" && grep -Fq '新しいテストが必要であることだけを理由に停止しない' "$SCENARIO_FLOW" && grep -Fq '旧revisionを読むtaskには`--source-ref <revision>`' "$SCENARIO_FLOW" && grep -Fq 'validatorのstdoutを改変せず渡し' "$SCENARIO_FLOW" && grep -Fq '`fork_turns: "none"`' "$SCENARIO_FLOW" && grep -Fq '`reasoning_effort: "max"`' "$SCENARIO_FLOW" && grep -Fq 'generic agentによる代用は禁止' "$SCENARIO_FLOW" && grep -Fq 'child agent IDが空' "$SCENARIO_FLOW" && grep -Fq 'wait先が空' "$SCENARIO_FLOW" && ok "共通フローはtest選択権・実装範囲・freshなLuna maxを固定" || ng "共通フローのtest選択権・実装境界またはsubagent起動が不正"
grep -Fq '半年後に負債にならないかを必ずレビュー' "$SCENARIO_FLOW" && grep -Fq '関数ジャンプ' "$SCENARIO_FLOW" && grep -Fq 'YAGNI' "$SCENARIO_FLOW" && grep -Fq '`filter().map()`' "$SCENARIO_FLOW" && grep -Fq '`reduce()`' "$SCENARIO_FLOW" && grep -Fq '多少冗長でも局所的に理解できる' "$SCENARIO_FLOW" && ok "上位モデルは半年後の負債と可読性を必須レビュー" || ng "上位モデルの保守性・可読性レビュー契約が不足"
grep -Fq '次のtest除外pathだけの変更では対応test/specの作成・実行とRed / Greenを要求せず' "$SCENARIO_FLOW" && grep -Fq 'basenameが`constants.ts`または`constants.js`' "$SCENARIO_FLOW" && grep -Fq '`constants/`配下' "$SCENARIO_FLOW" && grep -Fq 'その挙動だけを通常どおりシナリオ、Red、Greenの対象' "$SCENARIO_FLOW" && ok "共通フローはschema・定数のtest除外境界を固定" || ng "共通フローのschema・定数test除外境界が不正"
grep -Fq '`.jsx` / `.tsx` componentとReact hookには、そのためだけの隣接unit testを新設しない' "$SCENARIO_FLOW" && grep -Fq '`.jsx` / `.tsx` componentとReact hookは隣接unit testの必須対象外' "$REPO/rules/typescript/tdd-pattern.md" && grep -Fq '*/hooks/*|*/use[A-Z]*.ts' "$REPO/hooks/shell/require-test.sh" && ok "componentとReact hookはunit test必須対象外" || ng "componentまたはReact hookのtest除外が不正"
grep -Fq '`target-test`、`direct-regression`、`typecheck`、`schema`' "$SCENARIO_FLOW" && grep -Fq '無関係なpackageのtestやproject全体のtestを追加しない' "$SCENARIO_FLOW" && grep -Fq '`tsc -p <tsconfig> --noEmit`' "$SCENARIO_FLOW" && grep -Fq 'Prisma `format`、`validate`、`generate`' "$SCENARIO_FLOW" && ok "共通フローは調査commandと最終検証の範囲を固定" || ng "共通フローの調査commandまたは最終検証が曖昧"
grep -Fq '`scope-related`' "$SCENARIO_FLOW" && grep -Fq '`unrelated`' "$SCENARIO_FLOW" && grep -Fq '`uncertain`' "$SCENARIO_FLOW" && grep -Fq 'ignored / untracked test' "$SCENARIO_FLOW" && grep -Fq '対象外の失敗だけでタスクを未完了と決めない' "$ERRAND_SKILL" && grep -Fq 'どの分類もユーザーの完了マーク判断を代行しない' "$POLISH_SKILL" && grep -Fq 'どの分類が残っていてもそれから完了マークを自動判定せず' "$SCENARIO_FLOW" && ok "tdd・errand・polishは対象外失敗と完了判断を分離" || ng "対象外失敗がタスク完了を自動阻止"
grep -Fq '開始scope全件、directory、glob、`git diff`で独自に広げたpathを使わない' "$POLISH_SKILL" && grep -Fq 'typecheckとPrisma検証はファイル単位で安全に分割できない' "$POLISH_SKILL" && grep -Fq '実変更pathだけを渡して`unwind`を必ず呼ぶ' "$POLISH_SKILL" && grep -Fq '`unwind`自身では差分を再探索・再検証しない' "$UNWIND_SKILL" && grep -Fq '`list-changed`をもう一度実行しない' "$POLISH_SKILL" && ok "polishとunwindは実変更pathを再探索せず対象化" || ng "polishまたはunwindが実変更pathを再探索"
grep -Fq 'Skill(polish)' "$TDD_SKILL" && grep -Fq '開始scope全件ではなく、この出力にある実変更pathだけをまとめて`polish`へ渡し' "$TDD_SKILL" && grep -Fq 'bash [skills_root]/tdd/mark-prompt-done.sh <機能名>' "$TDD_SKILL" && ok "tdd は実変更pathのpolish後だけindexを更新" || ng "tdd のpolish対象または品質ゲートが不正"
grep -Fq 'capture-scope.sh <機能名> -- <相対path>...' "$TDD_SKILL" && grep -Fq '変更前に次を1回実行' "$TDD_SKILL" && ok "tdd はpolish対象の基準commitとpathを変更前に固定" || ng "tdd のscope path固定が不正"
grep -Fq 'ファイルごとには呼ばない' "$TDD_SKILL" && grep -Fq 'formatterがformat差分を自動修正' "$POLISH_SKILL" && grep -Fq '上位モデルがコードを判断して修正した場合は全品質ゲートを再実行' "$POLISH_SKILL" && ok "tdd はpolishを全path一括で原因別に反復" || ng "tdd のpolish実行単位または反復条件が不正"

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
IMPLEMENTATION_VALIDATOR=".claude/skills/tdd/validate-implementation-request.sh"
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
IMPLEMENTATION_TASK_DIR=".claude/tmp/worker/implementation-survey"
mkdir -p "$IMPLEMENTATION_TASK_DIR"
printf 'Outcome: fulfilled\n' > "$IMPLEMENTATION_TASK_DIR/report.md"
printf '# Verified evidence\n' > "$IMPLEMENTATION_TASK_DIR/evidence.md"
jq -n \
  --arg report_blob "$(git hash-object "$IMPLEMENTATION_TASK_DIR/report.md")" \
  --arg evidence_blob "$(git hash-object "$IMPLEMENTATION_TASK_DIR/evidence.md")" \
  '{mode:"survey",task_id:"implementation-survey",status:0,output_contract_status:"valid",outcome:"fulfilled",evidence_status:"verified",changed_paths:[],report_file:"report.md",evidence_file:"evidence.md",report_blob:$report_blob,evidence_blob:$evidence_blob}' \
  > "$IMPLEMENTATION_TASK_DIR/result.json"
mkdir -p tests/approved
printf 'test fixture\n' > tests/approved/implementation-flow.test.ts
git add tests/approved/implementation-flow.test.ts
git commit -qm "test: implementation requestのtest fixture"
IMPLEMENTATION_REQUEST=$(jq -cn '{version:3,action:"implement",scope:"implementation-check",spec:null,implementation_instruction:"要件R1と、テストシナリオを作らない要件R2を両方とも初回実装する",worker_tasks:[{task_id:"implementation-survey",result:".claude/tmp/worker/implementation-survey/result.json",report:".claude/tmp/worker/implementation-survey/report.md",evidence:".claude/tmp/worker/implementation-survey/evidence.md"}],test_scenarios:[{id:"S1",contract:"要件R1は入力が有効な場合に期待値を返す"}],test_paths:["tests/approved/implementation-flow.test.ts"],red:{command:"npm test",status:1,reason:"期待値差で失敗"},test_exemption:null,allowed_paths:["src/rules.ts"]}')
if bash "$CS" implementation-check -- src/rules.ts > implementation-capture.out 2>&1 && \
   bash "$IMPLEMENTATION_VALIDATOR" "$IMPLEMENTATION_REQUEST" > implementation-request.out 2>&1 && \
   jq -e '.implementation_instruction | contains("テストシナリオを作らない要件R2")' implementation-request.out >/dev/null && \
   jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"PARENT1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .claude/skills/polish/capture-scope.sh activate implementation-check"}}' | bash ".claude/hooks/shell/protect-implementation-scope.sh" >/dev/null && \
   bash "$CS" activate implementation-check > implementation-activate.out 2>&1; then
  ok "implementation-scope: test対象外の実装要件を保持してcleanな本体file scopeをactivate"
else
  ng "implementation-scope: activate失敗"; cat implementation-capture.out implementation-activate.out
fi
IMPLEMENTATION_HOOK=".claude/hooks/shell/protect-implementation-scope.sh"
REQUIRE_TEST_HOOK=".claude/hooks/shell/require-test.sh"
ALLOW_EDIT=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"IMPL1",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:($cwd + "/src/rules.ts")}}' | bash "$IMPLEMENTATION_HOOK")
ALLOW_NON_ADJACENT_TEST=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"IMPL1",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:($cwd + "/src/rules.ts")}}' | bash "$REQUIRE_TEST_HOOK")
DENY_PARENT_EDIT=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"PARENT1",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:($cwd + "/src/rules.ts")}}' | bash "$IMPLEMENTATION_HOOK")
DENY_EDIT=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"IMPL1",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:($cwd + "/src/untouched.ts")}}' | bash "$IMPLEMENTATION_HOOK")
ALLOW_IMPLEMENTER_READ=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"IMPL1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .claude/skills/tdd/implementer-read.sh src/rules.ts"}}' | bash "$IMPLEMENTATION_HOOK")
ALLOW_PARENT_READ=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"PARENT1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .claude/skills/tdd/implementer-read.sh .claude/tmp/worker/implementation-survey/evidence.md"}}' | bash "$IMPLEMENTATION_HOOK")
DENY_BASH=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"IMPL1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"git status --short"}}' | bash "$IMPLEMENTATION_HOOK")
DENY_READ_CHAIN=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"IMPL1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .claude/skills/tdd/implementer-read.sh src/rules.ts; git status"}}' | bash "$IMPLEMENTATION_HOOK")
DENY_SUBAGENT_DEACTIVATE=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"IMPL1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .claude/skills/polish/capture-scope.sh deactivate implementation-check"}}' | bash "$IMPLEMENTATION_HOOK")
ALLOW_PARENT_DEACTIVATE=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"PARENT1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .claude/skills/polish/capture-scope.sh deactivate implementation-check"}}' | bash "$IMPLEMENTATION_HOOK")
ALLOW_PARENT_HANDOFF=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"PARENT1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .claude/skills/polish/capture-scope.sh handoff-to-parent implementation-check"}}' | bash "$IMPLEMENTATION_HOOK")
DENY_SUBAGENT_HANDOFF=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"IMPL1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .claude/skills/polish/capture-scope.sh handoff-to-parent implementation-check"}}' | bash "$IMPLEMENTATION_HOOK")
IMPLEMENTER_READ_OUTPUT=$(bash .claude/skills/tdd/implementer-read.sh src/rules.ts)
if [ -z "$ALLOW_EDIT" ] && [ -z "$ALLOW_NON_ADJACENT_TEST" ] && [ -z "$ALLOW_IMPLEMENTER_READ" ] && [ -z "$ALLOW_PARENT_READ" ] && printf '%s' "$IMPLEMENTER_READ_OUTPUT" | grep -Fq 'legacyNumber' && [ "$(echo "$DENY_PARENT_EDIT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && [ "$(echo "$DENY_EDIT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && [ "$(echo "$DENY_BASH" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && [ "$(echo "$DENY_READ_CHAIN" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && [ "$(echo "$DENY_SUBAGENT_DEACTIVATE" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && [ -z "$ALLOW_PARENT_DEACTIVATE" ] && [ -z "$ALLOW_PARENT_HANDOFF" ] && [ "$(echo "$DENY_SUBAGENT_HANDOFF" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ]; then
  ok "implementation-scope: subagentは許可fileを読み書きし親は読み取りだけ可能"
else
  ng "implementation-scope: Claude hookのsubagent境界が不正"
fi
if bash "$CS" handoff-to-parent implementation-check > implementation-handoff.out 2>&1; then
  ALLOW_PARENT_FALLBACK_EDIT=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"PARENT1",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:($cwd + "/src/rules.ts")}}' | bash "$IMPLEMENTATION_HOOK")
  DENY_IMPLEMENTER_FALLBACK_EDIT=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"IMPL1",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:($cwd + "/src/rules.ts")}}' | bash "$IMPLEMENTATION_HOOK")
  ALLOW_FALLBACK_TEST=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"PARENT1",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:($cwd + "/src/rules.ts")}}' | bash "$REQUIRE_TEST_HOOK")
  if [ -z "$ALLOW_PARENT_FALLBACK_EDIT" ] && [ -z "$ALLOW_FALLBACK_TEST" ] && [ "$(echo "$DENY_IMPLEMENTER_FALLBACK_EDIT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ]; then
    ok "implementation-scope: handoff後はrequestとtest_pathsを維持して親だけ書き込み可"
  else
    ng "implementation-scope: parent fallbackのowner・request境界が不正"
  fi
else
  ng "implementation-scope: parent fallbackへhandoffできない"; cat implementation-handoff.out
fi
if bash "$CS" deactivate implementation-check > implementation-deactivate.out 2>&1 && ! bash .claude/skills/tdd/implementer-read.sh src/rules.ts >/dev/null 2>&1; then ok "implementation-scope: 完了後にactive receiptを解除"; else ng "implementation-scope: deactivate失敗"; cat implementation-deactivate.out; fi
mkdir -p local-only-tests
printf '/local-only-tests/\n' > .gitignore
printf 'local ignored test fixture\n' > local-only-tests/implementation-flow.test.ts
IGNORED_TEST_REQUEST=$(printf '%s' "$IMPLEMENTATION_REQUEST" | jq -c '.test_paths=["local-only-tests/implementation-flow.test.ts"]')
if bash "$IMPLEMENTATION_VALIDATOR" "$IGNORED_TEST_REQUEST" > implementation-ignored-test.out 2>&1 && \
   jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"PARENT2",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .claude/skills/polish/capture-scope.sh activate implementation-check"}}' | bash "$IMPLEMENTATION_HOOK" >/dev/null && \
   bash "$CS" activate implementation-check > implementation-ignored-activate.out 2>&1; then
  ALLOW_IGNORED_TEST=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"IMPL2",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:($cwd + "/src/rules.ts")}}' | bash "$REQUIRE_TEST_HOOK")
  if [ -z "$ALLOW_IGNORED_TEST" ]; then
    ok "implementation request: ignore対象のローカルtestをRedとして許可"
  else
    ng "implementation request: ignore対象testのmappingをhookが拒否"
  fi
  bash "$CS" deactivate implementation-check >/dev/null 2>&1 || ng "implementation-scope: ignore対象test確認後のdeactivate失敗"
else
  ng "implementation request: ignore対象のローカルtestを拒否"; cat implementation-ignored-test.out implementation-ignored-activate.out 2>/dev/null
fi
rm -f .gitignore
rm -f local-only-tests/implementation-flow.test.ts
rmdir local-only-tests
MISSING_RED_REQUEST=$(printf '%s' "$IMPLEMENTATION_REQUEST" | jq -c 'del(.red)')
EXEMPT_SOURCE_REQUEST=$(printf '%s' "$IMPLEMENTATION_REQUEST" | jq -c '.test_scenarios=[] | .test_paths=[] | .red=null | .test_exemption={paths:.allowed_paths,reason:"不正な免除"}')
LEGACY_SCENARIO_REQUEST=$(printf '%s' "$IMPLEMENTATION_REQUEST" | jq -c 'del(.test_scenarios) | .version=2 | .approved_scenarios=[{id:"S1",contract:"実装範囲と混同する旧field"}]')
printf 'ignored test fixture\n' > src/untracked.test.ts
UNTRACKED_TEST_REQUEST=$(printf '%s' "$IMPLEMENTATION_REQUEST" | jq -c '.test_paths=["src/untracked.test.ts"]')
if bash "$IMPLEMENTATION_VALIDATOR" "$MISSING_RED_REQUEST" > implementation-missing-red.out 2>&1; then
  ng "implementation request: Red欠落を許可"
elif bash "$IMPLEMENTATION_VALIDATOR" "$EXEMPT_SOURCE_REQUEST" > implementation-invalid-exemption.out 2>&1; then
  ng "implementation request: 本体コードのtest免除を許可"
elif bash "$IMPLEMENTATION_VALIDATOR" "$LEGACY_SCENARIO_REQUEST" > implementation-legacy-scenario.out 2>&1; then
  ng "implementation request: actionもscenario契約もない旧schemaを許可"
elif bash "$IMPLEMENTATION_VALIDATOR" "$UNTRACKED_TEST_REQUEST" > implementation-untracked-test.out 2>&1; then
  ng "implementation request: 未追跡testをRed根拠として許可"
else
  ok "implementation request: Red欠落・不正免除・旧schema・未追跡testを起動前に拒否"
fi
rm -f src/untracked.test.ts
printf 'stale patch\n' > "$IMPLEMENTATION_TASK_DIR/candidate.patch"
if bash "$IMPLEMENTATION_VALIDATOR" "$IMPLEMENTATION_REQUEST" > implementation-candidate-patch.out 2>&1; then
  ng "implementation request: worker candidate.patch混入を許可"
else
  ok "implementation request: read-only worker artifactだけを受理"
fi
rm "$IMPLEMENTATION_TASK_DIR/candidate.patch"
if bash "$CS" unvalidated-implementation -- src/untouched.ts > implementation-unvalidated-capture.out 2>&1 && bash "$CS" activate unvalidated-implementation > implementation-unvalidated-activate.out 2>&1; then
  ng "implementation-scope: request validatorを飛ばしてactivate"
  bash "$CS" deactivate unvalidated-implementation >/dev/null 2>&1 || true
else
  ok "implementation-scope: 検証済みrequestなしのactivateを拒否"
fi
mkdir -p tests
if bash "$CS" root-test-scope -- tests/integration.ts > implementation-root-test.out 2>&1; then
  ng "implementation-scope: root tests pathを許可"
else
  ok "implementation-scope: root tests pathを拒否"
fi
if bash "$CS" protected-scope -- src/sample.test.ts > implementation-protected-capture.out 2>&1 && bash "$CS" activate protected-scope > implementation-protected-activate.out 2>&1; then
  ng "implementation-scope: test資産を許可pathへ含めた"
  bash "$CS" deactivate protected-scope >/dev/null 2>&1 || true
else
  ok "implementation-scope: test資産を許可pathから拒否"
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
DELEGATE_VALIDATOR="$DELEGATE_REPO/.claude/skills/worker/validate-survey-request.sh"
DELEGATE_TIMEOUT_REASON='scope=fixture,difficulty=low,basis=offline-runner-regression'
DELEGATE_TIMEOUT_ARGS=(--hard-timeout-minutes 4 --idle-timeout-seconds 120 --poll-seconds 5 --timeout-reason "$DELEGATE_TIMEOUT_REASON")
mkdir -p "$DELEGATE_BIN" "$(dirname "$DELEGATE_SCRIPT")"
cp .claude/skills/worker/delegate.sh "$DELEGATE_SCRIPT"
cp .claude/skills/worker/validate-survey-request.sh "$DELEGATE_VALIDATOR"
printf '#!/bin/bash\n[ -z "${CURL_CALL_MARKER:-}" ] || : > "$CURL_CALL_MARKER"\nprintf '\''{"data":{"usage_monthly":0,"usage":0,"limit":40,"limit_reset":"monthly"}}\\n'\''\n' > "$DELEGATE_BIN/curl"
printf '#!/bin/bash\nif [ "$*" = "hello" ]; then jq -cn --arg text hello '\''{type:"text",text:$text}'\''; exit; fi\njq -e '\''.permission.bash == "deny"'\'' "$OPENCODE_CONFIG" >/dev/null || exit 40\nprompt=$(printf '\''%%s'\'' "$*" | tr '\''\\n'\'' '\'' '\'')\ntext=$(printf '\''Outcome: fulfilled\n## Claims\n### C1\nClaim: fixtureを確認した\nEvidence:\n- `spec.md:1-1`\nInterpretation: %%s\nLimitations: none\n## Remaining\nnone\n'\'' "$prompt")\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/curl" "$DELEGATE_BIN/opencode"
printf '%s\n' \
  '#!/bin/bash' \
  'if [ "$*" = "hello" ]; then jq -cn --arg text hello '\''{type:"text",text:$text}'\''; exit; fi' \
  'jq -e '\''.permission.bash == "deny"'\'' "$OPENCODE_CONFIG" >/dev/null || exit 40' \
  'text='\''Outcome: fulfilled
## Claims
### C1
Claim: fixtureを確認した
Evidence:
- `spec.md:1-1`
Interpretation: fixture
Limitations: none
## Remaining
none'\''' \
  'jq -cn --arg text "$text" '\''{type:"text",text:$text}'\''' \
  > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
cd "$DELEGATE_REPO"
git init -q
git config user.email tester@example.com
git config user.name tester
printf '# research spec\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\nline 11\nline 12\n' > spec.md
awk 'BEGIN { for (line = 1; line <= 100; line++) print "line " line }' > long-evidence.txt
git add spec.md long-evidence.txt
git commit -qm "test: research fixture"
git branch legacy-fixture
printf 'current only\n' > current-only.txt
git add current-only.txt
git commit -qm "test: current revision fixture"
NO_CONTEXT_SURVEY_REQUEST='{"purpose":"agent contextなしのsourceを確認する","claims":[{"id":"C1","kind":"behavior","subject":"spec見出し","question":"specの見出しは何か","anchors":["research spec"],"done_when":"見出しを直接示す根拠がある","exclude":["test","runtime"]}]}'
if PATH="$DELEGATE_BIN:/usr/bin:/bin" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" no-context-survey "$NO_CONTEXT_SURVEY_REQUEST" > delegate-no-context.out 2>&1 && [ "$(jq -c '.context_snapshot_paths' "$DELEGATE_REPO/.claude/tmp/worker/no-context-survey/result.json" 2>/dev/null)" = '[]' ] && [ "$(jq -r '.source_snapshot' "$DELEGATE_REPO/.claude/tmp/worker/no-context-survey/result.json" 2>/dev/null)" = 'HEAD' ] && [ "$(jq -r '.evidence_status' "$DELEGATE_REPO/.claude/tmp/worker/no-context-survey/result.json" 2>/dev/null)" = 'verified' ] && [ "$(jq -r '.outline_tool' "$DELEGATE_REPO/.claude/tmp/worker/no-context-survey/result.json" 2>/dev/null)" = 'null' ]; then
  ok "delegate-worker: zat未導入でも従来権限でevidenceを生成"
else
  ng "delegate-worker: 空のcontext snapshotで失敗"; cat delegate-no-context.out
fi
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
INVALID_SURVEY_CALL_MARKER="$DELEGATE_REPO/invalid-survey-called-curl"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test CURL_CALL_MARKER="$INVALID_SURVEY_CALL_MARKER" bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" invalid-structured-survey '{"purpose":"bad","claims":[]}' > delegate-invalid-structured-survey.out 2>&1; then
  ng "delegate-worker: 空claimの構造化surveyを許可"
elif [ ! -e "$INVALID_SURVEY_CALL_MARKER" ] && grep -Fq 'failed validation before external execution' delegate-invalid-structured-survey.out; then
  ok "delegate-worker: 不正survey依頼をHTTP前に拒否"
else
  ng "delegate-worker: 不正survey依頼の事前拒否が不正"; cat delegate-invalid-structured-survey.out
fi
INVALID_SOURCE_CALL_MARKER="$DELEGATE_REPO/invalid-source-called-curl"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test CURL_CALL_MARKER="$INVALID_SOURCE_CALL_MARKER" bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" --source-ref missing-fixture invalid-source-survey '{"purpose":"旧実装を確認する","claims":[{"id":"C1","kind":"behavior","subject":"旧実装","question":"旧実装の入力は何か","anchors":["legacy"],"done_when":"入力の根拠がある","exclude":["current"]}]}' > delegate-invalid-source.out 2>&1; then
  ng "delegate-worker: 存在しないsource revisionを許可"
elif [ ! -e "$INVALID_SOURCE_CALL_MARKER" ] && grep -Fq -- '--source-ref does not resolve to a commit' delegate-invalid-source.out; then
  ok "delegate-worker: 不正source revisionをHTTP前に拒否"
else
  ng "delegate-worker: source revisionの事前拒否が不正"; cat delegate-invalid-source.out
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" --source-ref HEAD --source-ref legacy-fixture duplicate-source-survey '{"purpose":"旧実装を確認する","claims":[{"id":"C1","kind":"behavior","subject":"旧実装","question":"旧実装の入力は何か","anchors":["legacy"],"done_when":"入力の根拠がある","exclude":["current"]}]}' > delegate-duplicate-source.out 2>&1; then
  ng "delegate-worker: source revisionの重複指定を許可"
elif grep -Fq -- '--source-ref may be specified only once' delegate-duplicate-source.out; then
  ok "delegate-worker: HEAD明示を含むsource revision重複を拒否"
else
  ng "delegate-worker: source revision重複の拒否理由が不正"; cat delegate-duplicate-source.out
fi
if PATH="$DELEGATE_BIN:/usr/bin:/bin" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" research "${DELEGATE_TIMEOUT_ARGS[@]}" empty-research spec.md > delegate-empty.out 2>&1; then
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
printf '#!/bin/bash\nexit 0\n' > "$DELEGATE_BIN/zat"
chmod +x "$DELEGATE_BIN/zat"
printf '#!/bin/bash\njq -e '\''(.default_agent == "delegate") and (.agent.delegate.steps == 15) and (.permission.bash["*"] == "deny") and (.permission.bash["zat *"] == "allow") and (.permission.bash | length == 2) and (.permission.edit["*"] == "deny") and (.permission.edit | length == 1)'\'' "$OPENCODE_CONFIG" >/dev/null || exit 41\n[ -f AGENTS.md ] && [ -f .codex/prompt/ignored-design.md ] && [ -f .codex/rules/ignored.rules ] && [ -f .agents/skills/sample/SKILL.md ] && [ ! -e .codex/tmp/private.txt ] || exit 42\nprompt=$(printf '\''%%s'\'' "$*" | tr '\''\\n'\'' '\'' '\'')\nprintf '\''%%s\n'\'' "$prompt" | grep -Fq '\''zat出力自体はEvidenceにしない'\'' || exit 43\nprintf '\''%%s\n'\'' "$prompt" | grep -Fq '\''読んだだけの隣接fileを引用しない'\'' || exit 44\nprintf '\''%%s\n'\'' "$prompt" | grep -Fq '\''単一tracked file'\'' || exit 45\nprintf '\''%%s\n'\'' "$prompt" | grep -Fq '\''help・version確認'\'' || exit 46\nprintf '\''%%s\n'\'' "$prompt" | grep -Fq '\''do not try another zat command'\'' || exit 47\nprintf '\''%%s\n'\'' "$prompt" | grep -Fq '\''symbol全rangeをEvidenceへ転記してはなりません'\'' || exit 48\ntext=$(printf '\''Outcome: fulfilled\n## Claims\n### C1\nClaim: fixtureを確認した\nEvidence:\n- `spec.md:1-1`\nInterpretation: %%s\nLimitations: none\n## Remaining\nnone\n'\'' "$prompt")\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
printf '%s\n' \
  '#!/bin/bash' \
  'jq -e '\''(.default_agent == "delegate") and (.agent.delegate.steps == 15) and (.permission.bash["zat *"] == "allow") and (.permission.edit["*"] == "deny")'\'' "$OPENCODE_CONFIG" >/dev/null || exit 41' \
  '[ -f AGENTS.md ] && [ -f .codex/prompt/ignored-design.md ] && [ -f .codex/rules/ignored.rules ] && [ -f .agents/skills/sample/SKILL.md ] && [ ! -e .codex/tmp/private.txt ] || exit 42' \
  'prompt=$(printf '\''%s'\'' "$*" | tr '\''\n'\'' '\'' '\'')' \
  'printf '\''%s\n'\'' "$prompt" | grep -Fq '\''zat出力自体はEvidenceにしない'\'' || exit 43' \
  'printf '\''%s\n'\'' "$prompt" | grep -Fq '\''読んだだけの隣接fileを引用しない'\'' || exit 44' \
  'printf '\''%s\n'\'' "$prompt" | grep -Fq '\''単一tracked file'\'' || exit 45' \
  'printf '\''%s\n'\'' "$prompt" | grep -Fq '\''help・version確認'\'' || exit 46' \
  'printf '\''%s\n'\'' "$prompt" | grep -Fq '\''do not try another zat command'\'' || exit 47' \
  'printf '\''%s\n'\'' "$prompt" | grep -Fq '\''symbol全rangeをEvidenceへ転記してはなりません'\'' || exit 48' \
  'text='\''Outcome: fulfilled
## Claims
### C1
Claim: t47_20__kanzen_douki__device_nebiki_kanri_db 機能語・ドメイン語 done_whenを満たした時点
Evidence:
- `spec.md:1-1`
Interpretation: fixture
Limitations: none
## Remaining
none'\''' \
  'jq -cn --arg text "$text" '\''{type:"text",text:$text}'\''' \
  > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
SURVEY_EXACT_IDENTIFIER='t47_20__kanzen_douki__device_nebiki_kanri_db'
SURVEY_REQUEST=$(jq -cn --arg anchor "$SURVEY_EXACT_IDENTIFIER" '{purpose:"同型実装の境界を確認する",claims:[{id:"C1",kind:"integration",subject:"指定識別子の同型実装",question:"指定識別子と同じ責務を持つ統合境界は何か",anchors:[$anchor],done_when:"直接の統合点を示す根拠がある",exclude:["全DB","全test基盤"]}]}')
SURVEY_SUPPLEMENT_ONE=$(jq -cn '{purpose:"caller境界を補完する",claims:[{id:"C1",kind:"control_flow",subject:"O2のcaller境界",question:"O2を呼び出す直接callerは何か",anchors:["O2"],done_when:"直接callerを示す根拠がある",exclude:["runtime","全test基盤"]}]}')
SURVEY_SUPPLEMENT_TWO=$(jq -cn '{purpose:"runtime境界を補完する",claims:[{id:"C1",kind:"contract",subject:"O3のruntime境界",question:"O3が依存するruntime契約は何か",anchors:["O3"],done_when:"runtime契約を示す根拠がある",exclude:["caller","全test基盤"]}]}')
SURVEY_SUPPLEMENT_THREE=$(jq -cn '{purpose:"追加境界を補完する",claims:[{id:"C1",kind:"integration",subject:"O4の追加境界",question:"O4の直接統合点は何か",anchors:["O4"],done_when:"統合点を示す根拠がある",exclude:["runtime","全test基盤"]}]}')
ABSENCE_REQUEST=$(jq -cn '{purpose:"tracked test不在を確認する",claims:[{id:"C1",kind:"test_absence",subject:"exact anchorのtest参照",question:"tracked test/specにexact anchorが存在しないか",anchors:["no_test_anchor"],done_when:"tracked test/spec一致が0件と機械検証される",exclude:["production実装の解釈"]}]}')
if PATH="/usr/bin:/bin" bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" test-absence-survey "$ABSENCE_REQUEST" > delegate-test-absence.out 2>&1 && \
   jq -e '.status == 0 and .outcome == "fulfilled" and .output_contract_status == "valid" and .evidence_status == "verified" and .tool_call_count == 0 and .usage_before == 0 and .limit_reset == "not_used" and .evidence[0].source == "verified_absence_search"' ".claude/tmp/worker/test-absence-survey/result.json" >/dev/null; then
  ok "delegate-worker: test不在を外部modelなしで機械検証"
else
  ng "delegate-worker: deterministic test absenceが不正"; cat delegate-test-absence.out
fi
mkdir -p tests
printf 'no_test_anchor\n' > tests/integration.ts
git add tests/integration.ts
git commit -qm "test: root tests absence contradiction fixture"
PATH="/usr/bin:/bin" bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" contradicted-absence-survey "$ABSENCE_REQUEST" > delegate-contradicted-absence.out 2>&1
CONTRADICTED_ABSENCE_STATUS=$?
if [ "$CONTRADICTED_ABSENCE_STATUS" -eq 68 ] && jq -e '.evidence_status == "invalid" and .evidence_failure_kind == "absence_contradicted" and .evidence[0].test_matches == ["tests/integration.ts"]' ".claude/tmp/worker/contradicted-absence-survey/result.json" >/dev/null; then
  ok "delegate-worker: root testsの反証を不在扱いしない"
else
  ng "delegate-worker: root tests absence contradictionの検出が不正"; cat delegate-contradicted-absence.out
fi
SURVEY_SOURCE_HEAD=$(git rev-parse HEAD)
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" empty-survey "$SURVEY_REQUEST" > delegate-survey.out 2>&1; then
  ok "delegate-worker: surveyは設計書なしの読み取り調査を完了"
else
  ng "delegate-worker: surveyが失敗"; cat delegate-survey.out
fi
SURVEY_ROOT="$DELEGATE_REPO/.claude/tmp/worker/empty-survey"
SURVEY_RESULT="$SURVEY_ROOT/result.json"
if [ -f "$SURVEY_RESULT" ] && [ "$(jq -r '.mode' "$SURVEY_RESULT")" = "survey" ] && [ "$(jq -r '.outline_tool' "$SURVEY_RESULT")" = "zat" ] && [ "$(jq -r '.report_file' "$SURVEY_RESULT")" = "report.md" ] && [ "$(jq -r '.evidence_file' "$SURVEY_RESULT")" = "evidence.md" ] && [ "$(jq -r '.evidence_status' "$SURVEY_RESULT")" = "verified" ] && [ "$(jq -r '.output_contract_status' "$SURVEY_RESULT")" = "valid" ] && [ "$(jq -r '.outcome' "$SURVEY_RESULT")" = "fulfilled" ] && [ "$(jq -r '.step_limit' "$SURVEY_RESULT")" = "15" ] && [ "$(jq -r '.source_ref' "$SURVEY_RESULT")" = "HEAD" ] && [ "$(jq -r '.source_snapshot' "$SURVEY_RESULT")" = "HEAD+ignored-agent-context" ] && [ "$(jq -r '.source_head' "$SURVEY_RESULT")" = "$SURVEY_SOURCE_HEAD" ] && [ "$(jq -r '.source_worktree_dirty' "$SURVEY_RESULT")" = "true" ] && [ "$(jq -r '.timeout_policy_source' "$SURVEY_RESULT")" = "explicit" ] && [ "$(jq -r '.poll_seconds' "$SURVEY_RESULT")" = "5" ] && [ "$(jq -r '.timeout_reason' "$SURVEY_RESULT")" = "$DELEGATE_TIMEOUT_REASON" ] && [ "$(jq -c '.context_snapshot_paths' "$SURVEY_RESULT")" = '[".agents/skills/sample/SKILL.md",".codex/prompt/ignored-design.md",".codex/rules/ignored.rules","AGENTS.md"]' ] && [ ! -e "$SURVEY_ROOT/spec.md" ] && [ ! -e "$DELEGATE_REPO/.claude/tmp/worker/.empty-survey.task" ]; then
  ok "delegate-worker: surveyはignored agent資料を監査可能なsnapshotとして読む"
else
  ng "delegate-worker: surveyのignored agent資料snapshotまたはresult.jsonが不正"
fi
if grep -Fq "$SURVEY_EXACT_IDENTIFIER" "$SURVEY_ROOT/report.md" && grep -Fq '機能語・ドメイン語' "$SURVEY_ROOT/report.md" && grep -Fq 'done_whenを満たした時点' "$SURVEY_ROOT/report.md" && grep -Fq '# research spec' "$SURVEY_ROOT/evidence.md" && grep -Fq '     9  line 9' "$SURVEY_ROOT/evidence.md" && [ "$(jq -r '.evidence[0].context_start_line' "$SURVEY_RESULT")" = "1" ] && [ "$(jq -r '.evidence[0].context_end_line' "$SURVEY_RESULT")" = "9" ] && [ "$(jq -r '.evidence[0].blob' "$SURVEY_RESULT")" = "$(git hash-object spec.md)" ] && grep -Fq 'report:' delegate-survey.out; then
  ok "delegate-worker: surveyのclaimへsnapshot由来コードと前後文脈を添付"
else
  ng "delegate-worker: survey reportまたは検証済みevidenceが不正"
fi
echo "== worker tool call metrics =="
TOOL_METRICS_MODE_FILE="$DELEGATE_REPO/tool-metrics-mode"
TOOL_METRICS_REPORT="$DELEGATE_REPO/tool-metrics-report.md"
printf '%s\n' \
  'Outcome: fulfilled' \
  '## Claims' \
  '### C1' \
  'Claim: tool metrics fixture' \
  'Evidence:' \
  '- `spec.md:1-1`' \
  'Interpretation: fixture' \
  'Limitations: none' \
  '## Remaining' \
  'none' > "$TOOL_METRICS_REPORT"
printf '%s\n' \
  '#!/bin/bash' \
  "mode=\$(sed -n '1p' \"$TOOL_METRICS_MODE_FILE\")" \
  "text=\$(cat \"$TOOL_METRICS_REPORT\")" \
  'case "$mode" in' \
  '  zat)' \
  '    jq -cn "{type:\"tool_use\",part:{tool:\"bash\",state:{status:\"completed\",input:{command:\"zat skills/worker/delegate.sh\"}}}}"' \
  '    jq -cn "{type:\"tool_use\",part:{tool:\"bash\",state:{status:\"completed\",input:{command:\"grep -n tool_use skills/worker/delegate.sh\"}}}}"' \
  '    jq -cn "{type:\"tool_use\",part:{tool:\"read\",state:{status:\"completed\",input:{path:\"spec.md\"}}}}"' \
  '    ;;' \
  '  no-zat)' \
  '    jq -cn "{type:\"tool_use\",part:{tool:\"grep\",state:{status:\"completed\",input:{pattern:\"tool_use\",path:\"skills/worker/delegate.sh\"}}}}"' \
  '    jq -cn "{type:\"tool_use\",part:{tool:\"read\",state:{status:\"completed\",input:{path:\"spec.md\"}}}}"' \
  '    ;;' \
  '  denied)' \
  '    jq -cn "{type:\"tool_use\",part:{tool:\"bash\",state:{status:\"denied\",input:{command:\"cat .env\"}}}}"' \
  '    jq -cn "{type:\"tool_use\",part:{tool:\"read\",state:{status:\"error\",input:{path:\".env\"}}}}"' \
  '    ;;' \
  '  malformed-event)' \
  '    jq -cn "{type:\"tool_use\",part:{tool:\"grep\",state:{status:\"completed\",input:{pattern:\"tool_use\"}}}}"' \
  '    jq -cn "{type:\"tool_use\",part:{tool:\"invalid\",state:{status:\"completed\"}}}"' \
  '    jq -cn "{type:\"tool_use\",part:{tool:\"bash\",state:{status:\"completed\",input:{command:\"rg tool_use\"}}}}"' \
  '    ;;' \
  '  malformed-line)' \
  '    jq -cn "{type:\"tool_use\",part:{tool:\"read\",state:{status:\"completed\",input:{path:\"spec.md\"}}}}"' \
  '    printf "%s\\n" "not-json"' \
  '    ;;' \
  'esac' \
  'jq -cn --arg text "$text" "{type:\"text\",text:\$text}"' \
  > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
run_tool_metrics_fixture() {
  local mode="$1"
  local task_id="tool-metrics-$mode"
  printf '%s\n' "$mode" > "$TOOL_METRICS_MODE_FILE"
  PATH="$DELEGATE_BIN:/usr/bin:/bin" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" "$task_id" "$SURVEY_REQUEST" > "$task_id.out" 2>&1
}
if run_tool_metrics_fixture zat && jq -e '.status == 0 and .tool_call_count == 3 and .tool_calls_by_name == {bash:1,read:1,zat:1} and .denied_tool_call_count == 0' "$DELEGATE_REPO/.claude/tmp/worker/tool-metrics-zat/result.json" >/dev/null 2>&1; then
  ok "delegate-worker: zat bashをzatへ分離してtool callを集計"
else
  ng "delegate-worker: zat使用時のtool call集計が不正"; cat tool-metrics-zat.out
fi
if run_tool_metrics_fixture no-zat && jq -e '.status == 0 and .tool_call_count == 2 and .tool_calls_by_name == {grep:1,read:1} and (.tool_calls_by_name.zat // 0) == 0' "$DELEGATE_REPO/.claude/tmp/worker/tool-metrics-no-zat/result.json" >/dev/null 2>&1; then
  ok "delegate-worker: zat未使用のtool call集計を保存"
else
  ng "delegate-worker: zat未使用時のtool call集計が不正"; cat tool-metrics-no-zat.out
fi
if run_tool_metrics_fixture denied && jq -e '.status == 0 and .tool_call_count == 2 and .denied_tool_call_count == 2 and .tool_calls_by_name == {bash:1,read:1}' "$DELEGATE_REPO/.claude/tmp/worker/tool-metrics-denied/result.json" >/dev/null 2>&1; then
  ok "delegate-worker: denied/error tool callを別集計"
else
  ng "delegate-worker: denied/error tool call集計が不正"; cat tool-metrics-denied.out
fi
if run_tool_metrics_fixture malformed-event && jq -e '.status == 0 and .tool_call_count == 2 and .tool_calls_by_name == {bash:1,grep:1} and .denied_tool_call_count == 0' "$DELEGATE_REPO/.claude/tmp/worker/tool-metrics-malformed-event/result.json" >/dev/null 2>&1; then
  ok "delegate-worker: malformed tool_use eventを無視して正常結果を保持"
else
  ng "delegate-worker: malformed tool_use eventの扱いが不正"; cat tool-metrics-malformed-event.out
fi
run_tool_metrics_fixture malformed-line
TOOL_METRICS_MALFORMED_STATUS=$?
if [ "$TOOL_METRICS_MALFORMED_STATUS" -eq 66 ] && jq -e '.status == 66 and .failure_class == "malformed_report" and .next_action == "retry" and .tool_call_count == 1 and .tool_calls_by_name == {read:1}' "$DELEGATE_REPO/.claude/tmp/worker/tool-metrics-malformed-line/result.json" >/dev/null 2>&1; then
  ok "delegate-worker: malformed lineは計測を壊さず既存protocol分類を維持"
else
  ng "delegate-worker: malformed lineの計測またはprotocol分類が不正"; cat tool-metrics-malformed-line.out
fi
if PATH="$DELEGATE_BIN:$PATH" bash "$DELEGATE_SCRIPT" show empty-survey > delegate-show.out 2>&1 && grep -Fq 'worker-result:' delegate-show.out && grep -Fq 'evidence: verified' delegate-show.out && grep -Fq "$SURVEY_EXACT_IDENTIFIER" delegate-show.out; then
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
LEGACY_SOURCE_HEAD=$(git rev-parse legacy-fixture)
printf '#!/bin/bash\n[ ! -e current-only.txt ] || exit 43\ntext='\''Outcome: fulfilled\n## Claims\n### C1\nClaim: legacy revisionを確認した\nEvidence:\n- `spec.md:1-1`\nInterpretation: fixture\nLimitations: none\n## Remaining\nnone'\''\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" --source-ref legacy-fixture legacy-source-survey "$SURVEY_REQUEST" > delegate-legacy-source.out 2>&1 && [ "$(jq -r '.source_ref' "$DELEGATE_REPO/.claude/tmp/worker/legacy-source-survey/result.json" 2>/dev/null)" = "legacy-fixture" ] && [ "$(jq -r '.source_head' "$DELEGATE_REPO/.claude/tmp/worker/legacy-source-survey/result.json" 2>/dev/null)" = "$LEGACY_SOURCE_HEAD" ] && [ "$(jq -r '.source_snapshot' "$DELEGATE_REPO/.claude/tmp/worker/legacy-source-survey/result.json" 2>/dev/null)" = "legacy-fixture+ignored-agent-context" ]; then
  ok "delegate-worker: 指定revisionから隔離worktreeとevidenceを作成"
else
  ng "delegate-worker: 指定revisionのsnapshotが不正"; cat delegate-legacy-source.out
fi
printf '#!/bin/bash\ntext='\''\n\nOutcome: fulfilled## Claims\n### C1\nClaim: report formatを正規化した\nEvidence:\n- `spec.md:1-1`\nInterpretation: fixture\nLimitations: none\n## Remaining\nnone'\''\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" normalized-report-survey "$SURVEY_REQUEST" > delegate-normalized-report.out 2>&1; then
  NORMALIZED_REPORT_ROOT="$DELEGATE_REPO/.claude/tmp/worker/normalized-report-survey"
  if [ "$(jq -r '.report_normalized' "$NORMALIZED_REPORT_ROOT/result.json" 2>/dev/null)" = "true" ] && [ "$(sed -n '1p' "$NORMALIZED_REPORT_ROOT/report.md")" = "Outcome: fulfilled" ] && [ "$(grep -Fxc '## Claims' "$NORMALIZED_REPORT_ROOT/report.md")" = "1" ] && [ "$(grep -Ec '^Outcome: ' "$NORMALIZED_REPORT_ROOT/report.md")" = "1" ] && [ "$(grep -Fxc '## Remaining' "$NORMALIZED_REPORT_ROOT/report.md")" = "1" ] && grep -Fq 'Outcome: fulfilled## Claims' "$NORMALIZED_REPORT_ROOT/opencode.jsonl"; then
    ok "delegate-worker: rawを保持して先頭空行と固定見出し連結だけを正規化"
  else
    ng "delegate-worker: reportの安全正規化またはraw保持が不正"
  fi
else
  ng "delegate-worker: 正規化可能なreportを失敗扱い"; cat delegate-normalized-report.out
fi
printf '%s\n' \
  '#!/bin/bash' \
  'physical=$(pwd -P)' \
  'text=$(printf '\''Outcome: fulfilled\n## Claims\n### C1\nClaim: physical pathを正規化した\nEvidence:\n- `%s/spec.md:1-1`\nInterpretation: fixture\nLimitations: none\n## Remaining\nnone\n'\'' "$physical")' \
  'jq -cn --arg text "$text" '\''{type:"text",text:$text}'\''' \
  > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" physical-path-survey "$SURVEY_REQUEST" > delegate-physical-path.out 2>&1 && \
   grep -Fxq -- '- `spec.md:1-1`' ".claude/tmp/worker/physical-path-survey/report.md" && \
   jq -e '.report_normalized == true and .output_contract_status == "valid" and .evidence_status == "verified"' ".claude/tmp/worker/physical-path-survey/result.json" >/dev/null; then
  ok "delegate-worker: isolated worktreeの物理絶対pathだけを相対化"
else
  ng "delegate-worker: physical absolute evidence pathの正規化が不正"; cat delegate-physical-path.out
fi
printf '#!/bin/bash\nprintf '\''{"type":"step_start","timestamp":1}\\n'\''\nprintf '\''{"type":"step_finish","timestamp":2,"part":{"reason":"stop"}}\\n'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" missing-report-survey "$SURVEY_REQUEST" > delegate-missing-report.out 2>&1
MISSING_REPORT_STATUS=$?
MISSING_REPORT_ROOT="$DELEGATE_REPO/.claude/tmp/worker/missing-report-survey"
PATH="$DELEGATE_BIN:$PATH" bash "$DELEGATE_SCRIPT" show missing-report-survey > delegate-show-missing-report.out 2>&1
SHOW_MISSING_REPORT_STATUS=$?
if [ "$MISSING_REPORT_STATUS" -eq 65 ] && [ "$SHOW_MISSING_REPORT_STATUS" -eq 65 ] && [ "$(jq -r '.opencode_status' "$MISSING_REPORT_ROOT/result.json" 2>/dev/null)" = "0" ] && [ "$(jq -r '.status' "$MISSING_REPORT_ROOT/result.json" 2>/dev/null)" = "65" ] && [ "$(jq -r '.report_status' "$MISSING_REPORT_ROOT/result.json" 2>/dev/null)" = "missing" ] && grep -Fxq 'Delegated model did not return a final textual report.' "$MISSING_REPORT_ROOT/report.md" && grep -Fq 'report:' delegate-show-missing-report.out; then
  ok "delegate-worker: 本文なし正常終了を失敗として成果物へ保存"
else
  ng "delegate-worker: 空応答の失敗分類または再表示statusが不正"; cat delegate-missing-report.out; cat delegate-show-missing-report.out
fi
printf '#!/bin/bash\nprintf '\''{"type":"step_start","timestamp":1}\\n'\''\nprintf '\''{"type":"text","timestamp":2,"text":"format missing"}\\n'\''\nprintf '\''{"type":"step_finish","timestamp":3,"part":{"reason":"stop"}}\\n'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" invalid-output-survey "$SURVEY_REQUEST" > delegate-invalid-output.out 2>&1
INVALID_OUTPUT_STATUS=$?
INVALID_OUTPUT_ROOT="$DELEGATE_REPO/.claude/tmp/worker/invalid-output-survey"
if [ "$INVALID_OUTPUT_STATUS" -eq 69 ] && [ "$(jq -r '.report_status' "$INVALID_OUTPUT_ROOT/result.json" 2>/dev/null)" = "complete" ] && [ "$(jq -r '.output_contract_status' "$INVALID_OUTPUT_ROOT/result.json" 2>/dev/null)" = "invalid" ] && [ "$(jq -r '.failure_class' "$INVALID_OUTPUT_ROOT/result.json" 2>/dev/null)" = "invalid_output" ] && [ "$(jq -r '.next_action' "$INVALID_OUTPUT_ROOT/result.json" 2>/dev/null)" = "supplement" ]; then
  ok "delegate-worker: source rangeのない断片をformat repairへ回さない"
else
  ng "delegate-worker: 出力契約欠落の分類が不正"; cat delegate-invalid-output.out
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" --repair-of invalid-output-survey forbidden-fragment-repair > delegate-forbidden-fragment-repair.out 2>&1; then
  ng "delegate-worker: source rangeのないtool断片をrepair"
elif grep -Fq 'repair parent has no source range to preserve' delegate-forbidden-fragment-repair.out; then
  ok "delegate-worker: 証拠ゼロのformat repairを起動前に拒否"
else
  ng "delegate-worker: 証拠ゼロrepairの拒否理由が不正"; cat delegate-forbidden-fragment-repair.out
fi
printf '#!/bin/bash\nfor step in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do jq -cn --argjson step "$step" '\''{type:"step_start",step:$step}'\''; done\njq -cn --arg text "format missing after step limit" '\''{type:"text",text:$text}'\''\njq -cn '\''{type:"step_finish",part:{reason:"stop"}}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" exhausted-step-survey "$SURVEY_REQUEST" > delegate-exhausted-step.out 2>&1
EXHAUSTED_STEP_STATUS=$?
EXHAUSTED_STEP_ROOT="$DELEGATE_REPO/.claude/tmp/worker/exhausted-step-survey"
if [ "$EXHAUSTED_STEP_STATUS" -eq 69 ] && [ "$(jq -r '.failure_class' "$EXHAUSTED_STEP_ROOT/result.json" 2>/dev/null)" = "step_limit_exhausted" ] && [ "$(jq -r '.next_action' "$EXHAUSTED_STEP_ROOT/result.json" 2>/dev/null)" = "supplement" ] && [ "$(jq -r '.step_limit_reached' "$EXHAUSTED_STEP_ROOT/result.json" 2>/dev/null)" = "true" ]; then
  ok "delegate-worker: step上限後の契約不備をformat repairへ渡さない"
else
  ng "delegate-worker: step上限到達の失敗分類が不正"; cat delegate-exhausted-step.out
fi
printf '#!/bin/bash\ntext='\''Outcome: fulfilled\n## Claims\n### C1\nEvidence:\n- `spec.md:1-1`\nClaim: 順序が不正\nInterpretation: fixture\nLimitations: none\n## Remaining\nnone'\''\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" invalid-claim-order-survey "$SURVEY_REQUEST" > delegate-invalid-claim-order.out 2>&1
INVALID_CLAIM_ORDER_STATUS=$?
INVALID_CLAIM_ORDER_ROOT="$DELEGATE_REPO/.claude/tmp/worker/invalid-claim-order-survey"
if [ "$INVALID_CLAIM_ORDER_STATUS" -eq 69 ] && [ "$(jq -r '.output_contract_status' "$INVALID_CLAIM_ORDER_ROOT/result.json" 2>/dev/null)" = "invalid" ]; then
  ok "delegate-worker: claim fieldの固定順を強制"
else
  ng "delegate-worker: claim field順の検証が不正"; cat delegate-invalid-claim-order.out
fi
printf '#!/bin/bash\ntext='\''Outcome: fulfilled\n## Claims\n### C1\nClaim: Evidenceの空白が不正\nEvidence:\n- `spec.md: 1-1`\nInterpretation: fixture\nLimitations: none\n## Remaining\nnone'\''\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" spaced-evidence-survey "$SURVEY_REQUEST" > delegate-spaced-evidence.out 2>&1
SPACED_EVIDENCE_STATUS=$?
if [ "$SPACED_EVIDENCE_STATUS" -eq 69 ] && [ "$(jq -r '.output_contract_status' "$DELEGATE_REPO/.claude/tmp/worker/spaced-evidence-survey/result.json" 2>/dev/null)" = "invalid" ]; then
  ok "delegate-worker: Evidenceのpathと行番号間の空白を拒否"
else
  ng "delegate-worker: Evidence空白の検証が不正"; cat delegate-spaced-evidence.out
fi
printf '#!/bin/bash\njq -e '\''(.permission.read["*"] == "deny") and (.permission.read[".delegate-request/parent-report.md"] == "allow") and (.permission.read[".delegate-request/parent-evidence.md"] == "allow") and (.permission.grep == "deny") and (.permission.glob == "deny") and (.permission.lsp == "deny")'\'' "$OPENCODE_CONFIG" >/dev/null || exit 71\n[ -f .delegate-request/parent-report.md ] && [ -f .delegate-request/parent-evidence.md ] || exit 72\ngrep -Fq "Claim: Evidenceの空白が不正" .delegate-request/parent-report.md || exit 73\ntext='\''Outcome: fulfilled\n## Claims\n### C1\nClaim: Evidenceの空白が不正\nEvidence:\n- `spec.md:1-1`\nInterpretation: fixture\nLimitations: none\n## Remaining\nnone'\''\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" --repair-of spaced-evidence-survey repaired-claim-survey > delegate-repaired-claim.out 2>&1 && [ "$(jq -r '.repair_of' "$DELEGATE_REPO/.claude/tmp/worker/repaired-claim-survey/result.json" 2>/dev/null)" = "spaced-evidence-survey" ] && [ "$(jq -r '.repair_attempt' "$DELEGATE_REPO/.claude/tmp/worker/repaired-claim-survey/result.json" 2>/dev/null)" = "1" ] && [ "$(jq -r '.information_attempt' "$DELEGATE_REPO/.claude/tmp/worker/repaired-claim-survey/result.json" 2>/dev/null)" = "1" ] && [ "$(jq -r '.evidence_status' "$DELEGATE_REPO/.claude/tmp/worker/repaired-claim-survey/result.json" 2>/dev/null)" = "verified" ]; then
  ok "delegate-worker: 形式不備だけをrepository再調査なしで修正"
else
  ng "delegate-worker: --repair-ofの権限制限または形式修正が不正"; cat delegate-repaired-claim.out
fi
printf '#!/bin/bash\njq -cn --arg text "still invalid after repair" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" --repair-of spaced-evidence-survey failed-claim-repair-survey > delegate-failed-claim-repair.out 2>&1
FAILED_CLAIM_REPAIR_STATUS=$?
FAILED_CLAIM_REPAIR_RESULT="$DELEGATE_REPO/.claude/tmp/worker/failed-claim-repair-survey/result.json"
if [ "$FAILED_CLAIM_REPAIR_STATUS" -eq 69 ] && [ "$(jq -r '.repair_attempt' "$FAILED_CLAIM_REPAIR_RESULT" 2>/dev/null)" = "1" ] && [ "$(jq -r '.failure_class' "$FAILED_CLAIM_REPAIR_RESULT" 2>/dev/null)" = "invalid_output" ] && [ "$(jq -r '.next_action' "$FAILED_CLAIM_REPAIR_RESULT" 2>/dev/null)" = "supplement" ]; then
  ok "delegate-worker: 証拠を失ったrepair結果を採用せず限定surveyへ戻す"
else
  ng "delegate-worker: 形式修正再失敗後のnext actionが不正"; cat delegate-failed-claim-repair.out
fi
printf '#!/bin/bash\ntext='\''Outcome: fulfilled\n## Claims\n### C1\nClaim: evidenceが多すぎる\nEvidence:\n- `spec.md:1-1`\n- `spec.md:2-2`\n- `spec.md:3-3`\n- `spec.md:4-4`\nInterpretation: fixture\nLimitations: none\n## Remaining\nnone'\''\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" excessive-claim-evidence-survey "$SURVEY_REQUEST" > delegate-excessive-claim-evidence.out 2>&1
EXCESSIVE_CLAIM_EVIDENCE_STATUS=$?
if [ "$EXCESSIVE_CLAIM_EVIDENCE_STATUS" -eq 69 ] && [ "$(jq -r '.output_contract_status' "$DELEGATE_REPO/.claude/tmp/worker/excessive-claim-evidence-survey/result.json" 2>/dev/null)" = "invalid" ]; then
  ok "delegate-worker: surveyの各claimをEvidence 3件以下へ強制"
else
  ng "delegate-worker: claim単位のEvidence上限検証が不正"; cat delegate-excessive-claim-evidence.out
fi
printf '#!/bin/bash\ntext='\''Outcome: fulfilled\n## Claims\n### C1\nClaim: 1\nEvidence:\n- `spec.md:1-1`\nInterpretation: fixture\nLimitations: none\n### C2\nClaim: 2\nEvidence:\n- `spec.md:1-1`\nInterpretation: fixture\nLimitations: none\n## Remaining\nnone'\''\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" excessive-claims-survey "$SURVEY_REQUEST" > delegate-excessive-claims.out 2>&1
EXCESSIVE_CLAIMS_STATUS=$?
if [ "$EXCESSIVE_CLAIMS_STATUS" -eq 69 ] && [ "$(jq -r '.output_contract_status' "$DELEGATE_REPO/.claude/tmp/worker/excessive-claims-survey/result.json" 2>/dev/null)" = "invalid" ]; then
  ok "delegate-worker: surveyをC1 1件へ強制"
else
  ng "delegate-worker: surveyのclaim上限検証が不正"; cat delegate-excessive-claims.out
fi
printf '#!/bin/bash\nprintf '\''{"type":"step_start","timestamp":1}\\n'\''\nprintf '\''{"type":"text","timestamp":2,"text":"partial report"}\\n'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" partial-report-survey "$SURVEY_REQUEST" > delegate-partial-report.out 2>&1
PARTIAL_REPORT_STATUS=$?
PARTIAL_REPORT_ROOT="$DELEGATE_REPO/.claude/tmp/worker/partial-report-survey"
if [ "$PARTIAL_REPORT_STATUS" -eq 67 ] && [ "$(jq -r '.report_status' "$PARTIAL_REPORT_ROOT/result.json" 2>/dev/null)" = "partial" ] && [ "$(jq -r '.failure_class' "$PARTIAL_REPORT_ROOT/result.json" 2>/dev/null)" = "partial_report" ] && grep -Fxq 'partial report' "$PARTIAL_REPORT_ROOT/report.md"; then
  ok "delegate-worker: stopなしの途中reportを非zeroで保持"
else
  ng "delegate-worker: 部分reportの分類または保存が不正"; cat delegate-partial-report.out
fi
printf '#!/bin/bash\nprintf '\''{"type":"step_start","timestamp":1}\\n'\''\ntext='\''Outcome: fulfilled\n## Claims\n### C1\nClaim: complete report\nEvidence:\n- `spec.md:1-1`\nInterpretation: fixture\nLimitations: none\n## Remaining\nnone'\''\njq -cn --arg text "$text" '\''{type:"text",timestamp:2,text:$text}'\''\nprintf '\''{"type":"step_finish","timestamp":3,"part":{"reason":"stop"}}\\n'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" complete-report-survey "$SURVEY_REQUEST" > delegate-complete-report.out 2>&1 && [ "$(jq -r '.status' "$DELEGATE_REPO/.claude/tmp/worker/complete-report-survey/result.json" 2>/dev/null)" = "0" ] && [ "$(jq -r '.report_status' "$DELEGATE_REPO/.claude/tmp/worker/complete-report-survey/result.json" 2>/dev/null)" = "complete" ] && grep -Fq 'Claim: complete report' "$DELEGATE_REPO/.claude/tmp/worker/complete-report-survey/report.md"; then
  ok "delegate-worker: stop後の契約準拠reportとevidenceをcompleteとして保存"
else
  ng "delegate-worker: 正常な最終文章の分類が不正"; cat delegate-complete-report.out
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" --retry-of complete-report-survey retry-lineage-survey "$SURVEY_REQUEST" > delegate-retry-lineage.out 2>&1 && [ "$(jq -r '.retry_of' "$DELEGATE_REPO/.claude/tmp/worker/retry-lineage-survey/result.json" 2>/dev/null)" = "complete-report-survey" ] && [ "$(jq -r '.attempt' "$DELEGATE_REPO/.claude/tmp/worker/retry-lineage-survey/result.json" 2>/dev/null)" = "2" ] && [ "$(jq -r '.information_attempt' "$DELEGATE_REPO/.claude/tmp/worker/retry-lineage-survey/result.json" 2>/dev/null)" = "1" ] && [ "$(jq -r '.retry_request_match' "$DELEGATE_REPO/.claude/tmp/worker/retry-lineage-survey/result.json" 2>/dev/null)" = "true" ] && [ -n "$(jq -r '.request_digest' "$DELEGATE_REPO/.claude/tmp/worker/retry-lineage-survey/result.json" 2>/dev/null)" ]; then
  ok "delegate-worker: retry親・attempt・実効request digestを記録"
else
  ng "delegate-worker: retry lineageの記録が不正"; cat delegate-retry-lineage.out
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" --supplement-of complete-report-survey supplement-one-survey "$SURVEY_SUPPLEMENT_ONE" > delegate-supplement-one.out 2>&1 && [ "$(jq -r '.supplement_of' "$DELEGATE_REPO/.claude/tmp/worker/supplement-one-survey/result.json" 2>/dev/null)" = "complete-report-survey" ] && [ "$(jq -r '.information_attempt' "$DELEGATE_REPO/.claude/tmp/worker/supplement-one-survey/result.json" 2>/dev/null)" = "2" ] && [ "$(jq -r '.supplement_request_changed' "$DELEGATE_REPO/.claude/tmp/worker/supplement-one-survey/result.json" 2>/dev/null)" = "true" ]; then
  ok "delegate-worker: 情報補完1回目の系譜とdigest変更を記録"
else
  ng "delegate-worker: 情報補完1回目の記録が不正"; cat delegate-supplement-one.out
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" --supplement-of supplement-one-survey supplement-two-survey "$SURVEY_SUPPLEMENT_TWO" > delegate-supplement-two.out 2>&1 && [ "$(jq -r '.information_attempt' "$DELEGATE_REPO/.claude/tmp/worker/supplement-two-survey/result.json" 2>/dev/null)" = "3" ]; then
  ok "delegate-worker: 情報調査を初回含む3回まで許可"
else
  ng "delegate-worker: 情報調査3回目の記録が不正"; cat delegate-supplement-two.out
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" --supplement-of supplement-two-survey supplement-three-survey "$SURVEY_SUPPLEMENT_THREE" > delegate-supplement-three.out 2>&1; then
  ng "delegate-worker: 情報調査の4回目を許可"
elif grep -Fq 'information survey limit reached after 3 attempts' delegate-supplement-three.out; then
  ok "delegate-worker: 情報調査を初回含む3回で打ち切る"
else
  ng "delegate-worker: 情報調査上限の拒否理由が不正"; cat delegate-supplement-three.out
fi
printf '#!/bin/bash\ntext='\''Outcome: partial\n## Claims\n### C1\nClaim: 調査途中\nEvidence:\nInterpretation: 上限前に完了できなかった\nLimitations: O2未確認\n## Remaining\nO2'\''\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" incomplete-outcome-survey "$SURVEY_REQUEST" > delegate-incomplete-outcome.out 2>&1
INCOMPLETE_OUTCOME_STATUS=$?
INCOMPLETE_OUTCOME_ROOT="$DELEGATE_REPO/.claude/tmp/worker/incomplete-outcome-survey"
if [ "$INCOMPLETE_OUTCOME_STATUS" -eq 70 ] && [ "$(jq -r '.report_status' "$INCOMPLETE_OUTCOME_ROOT/result.json" 2>/dev/null)" = "complete" ] && [ "$(jq -r '.outcome' "$INCOMPLETE_OUTCOME_ROOT/result.json" 2>/dev/null)" = "partial" ] && [ "$(jq -r '.failure_class' "$INCOMPLETE_OUTCOME_ROOT/result.json" 2>/dev/null)" = "incomplete_outcome" ] && [ "$(jq -r '.next_action' "$INCOMPLETE_OUTCOME_ROOT/result.json" 2>/dev/null)" = "supplement" ]; then
  ok "delegate-worker: 完全に受信した未完了outcomeを通信失敗と分離"
else
  ng "delegate-worker: 未完了outcomeの分類が不正"; cat delegate-incomplete-outcome.out
fi
printf '#!/bin/bash\ntext='\''Outcome: fulfilled\n## Claims\n### C1\nClaim: 根拠範囲が広すぎる\nEvidence:\n- `long-evidence.txt:1-100`\nInterpretation: fixture\nLimitations: none\n## Remaining\nnone'\''\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" invalid-evidence-survey "$SURVEY_REQUEST" > delegate-invalid-evidence.out 2>&1
INVALID_EVIDENCE_STATUS=$?
INVALID_EVIDENCE_ROOT="$DELEGATE_REPO/.claude/tmp/worker/invalid-evidence-survey"
if [ "$INVALID_EVIDENCE_STATUS" -eq 0 ] && [ "$(jq -r '.evidence_status' "$INVALID_EVIDENCE_ROOT/result.json" 2>/dev/null)" = "verified" ] && [ "$(jq -r '.report_normalized' "$INVALID_EVIDENCE_ROOT/result.json" 2>/dev/null)" = "true" ] && grep -Fxq -- '- `long-evidence.txt:1-80`' "$INVALID_EVIDENCE_ROOT/report.md" && grep -Fxq -- '- `long-evidence.txt:81-100`' "$INVALID_EVIDENCE_ROOT/report.md" && grep -Fxq '## E1 `long-evidence.txt:1-80`' "$INVALID_EVIDENCE_ROOT/evidence.md" && grep -Fxq '## E2 `long-evidence.txt:81-100`' "$INVALID_EVIDENCE_ROOT/evidence.md"; then
  ok "delegate-worker: 80行超のEvidence rangeを分割してpacket見出しと一致"
else
  ng "delegate-worker: Evidence rangeの自動分割またはpacket照合が不正"; cat delegate-invalid-evidence.out
fi
printf '#!/bin/bash\ntext='\''Outcome: fulfilled\n## Claims\n### C1\nClaim: 存在しない行を引用した\nEvidence:\n- `long-evidence.txt:1-101`\nInterpretation: fixture\nLimitations: none\n## Remaining\nnone'\''\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" out-of-bounds-evidence-survey "$SURVEY_REQUEST" > delegate-out-of-bounds-evidence.out 2>&1
OUT_OF_BOUNDS_STATUS=$?
OUT_OF_BOUNDS_ROOT="$DELEGATE_REPO/.claude/tmp/worker/out-of-bounds-evidence-survey"
if [ "$OUT_OF_BOUNDS_STATUS" -eq 68 ] && [ "$(jq -r '.evidence_failure_kind' "$OUT_OF_BOUNDS_ROOT/result.json" 2>/dev/null)" = "out_of_bounds" ] && grep -Fq 'Invalid range' "$OUT_OF_BOUNDS_ROOT/evidence.md"; then
  ok "delegate-worker: 存在しないEvidence行をpublish前に拒否"
else
  ng "delegate-worker: 存在しないEvidence行の検証が不正"; cat delegate-out-of-bounds-evidence.out
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" --repair-of out-of-bounds-evidence-survey forbidden-evidence-repair > delegate-forbidden-evidence-repair.out 2>&1; then
  ng "delegate-worker: 範囲外Evidenceを形式修正へ渡した"
elif grep -Fq 'evidence selection requires supplement' delegate-forbidden-evidence-repair.out; then
  ok "delegate-worker: 範囲外Evidenceをrepairせずsupplementへ固定"
else
  ng "delegate-worker: Evidence範囲のrepair拒否理由が不正"; cat delegate-forbidden-evidence-repair.out
fi
printf '#!/bin/bash\nprintf '\''not-json\\n'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" malformed-report-survey "$SURVEY_REQUEST" > delegate-malformed-report.out 2>&1
MALFORMED_REPORT_STATUS=$?
MALFORMED_REPORT_ROOT="$DELEGATE_REPO/.claude/tmp/worker/malformed-report-survey"
if [ "$MALFORMED_REPORT_STATUS" -eq 66 ] && [ "$(jq -r '.report_status' "$MALFORMED_REPORT_ROOT/result.json" 2>/dev/null)" = "malformed" ] && [ "$(jq -r '.failure_class' "$MALFORMED_REPORT_ROOT/result.json" 2>/dev/null)" = "malformed_report" ] && grep -Fxq 'not-json' "$MALFORMED_REPORT_ROOT/opencode.jsonl"; then
  ok "delegate-worker: 壊れたJSONでもraw成果物とfailure classを保存"
else
  ng "delegate-worker: malformed reportの保存または分類が不正"; cat delegate-malformed-report.out
fi
XDG_PATH_LOG="$DELEGATE_REPO/opencode-xdg-paths.log"
printf '#!/bin/bash\nfor path in "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$TMPDIR"; do [ -d "$path" ] || exit 51; done\nprintf '\''%%s\\n'\'' "$XDG_DATA_HOME" >> "%s"\n/bin/sleep 0.1\ntext='\''Outcome: fulfilled\n## Claims\n### C1\nClaim: isolated\nEvidence:\n- `spec.md:1-1`\nInterpretation: fixture\nLimitations: none\n## Remaining\nnone'\''\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' "$XDG_PATH_LOG" > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" parallel-xdg-a "$SURVEY_REQUEST" > delegate-parallel-a.out 2>&1 &
PARALLEL_A_PID=$!
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" parallel-xdg-b "$SURVEY_REQUEST" > delegate-parallel-b.out 2>&1 &
PARALLEL_B_PID=$!
wait "$PARALLEL_A_PID"; PARALLEL_A_STATUS=$?
wait "$PARALLEL_B_PID"; PARALLEL_B_STATUS=$?
XDG_PATH_COUNT=$(sort -u "$XDG_PATH_LOG" 2>/dev/null | wc -l | tr -d ' ')
if [ "$PARALLEL_A_STATUS" -eq 0 ] && [ "$PARALLEL_B_STATUS" -eq 0 ] && [ "$XDG_PATH_COUNT" = "2" ] && ! grep -Fq "$HOME/.local/share/opencode" "$XDG_PATH_LOG"; then
  ok "delegate-worker: 並列taskはOpenCode data領域を共有しない"
else
  ng "delegate-worker: 並列taskのOpenCode状態分離が不正"; cat delegate-parallel-a.out; cat delegate-parallel-b.out; cat "$XDG_PATH_LOG"
fi
rm -f "$XDG_PATH_LOG"
printf '#!/bin/bash\ntext='\''Outcome: fulfilled\n## Claims\n### C1\nClaim: 3段階以上の制御フローネストなし\nEvidence:\n- `src/subject.ts:1-1`\nInterpretation: 対象file全体\nLimitations: none\n## Remaining\nnone'\''\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
mkdir -p src
printf 'export const subject = true\n' > src/subject.ts
git add src/subject.ts
git commit -qm "test: nesting対象"
printf '#!/bin/bash\ntext='\''Outcome: fulfilled\n## Claims\n### C1\nClaim: 3段階以上の制御フローネストなし\nEvidence:\n- `src/subject.ts:1-1`\nInterpretation: 対象file全体\nLimitations: none\n## Remaining\nnone'\''\njq -cn --arg text "$text" '\''{type:"text",text:$text}'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
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
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" implement > delegate-implement-mode.out 2>&1; then
  ng "delegate-worker: implement modeを許可"
elif grep -Fq 'mode must be research, survey, nesting, prepare, smoke, or show' delegate-implement-mode.out; then
  ok "delegate-worker: implement modeを外部実行前に拒否"
else
  ng "delegate-worker: implement modeの拒否理由が不正"; cat delegate-implement-mode.out
fi
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" errand > delegate-errand-mode.out 2>&1; then
  ng "delegate-worker: errand modeを許可"
elif grep -Fq 'mode must be research, survey, nesting, prepare, smoke, or show' delegate-errand-mode.out; then
  ok "delegate-worker: errand modeを外部実行前に拒否"
else
  ng "delegate-worker: errand modeの拒否理由が不正"; cat delegate-errand-mode.out
fi
INTERRUPT_PID_FILE="$DELEGATE_REPO/interrupted-opencode.pid"
printf '#!/bin/bash\n/bin/sleep 0.01\n' > "$DELEGATE_BIN/sleep"
printf '#!/bin/bash\nprintf '\''%%s\\n'\'' "$$" > "%s"\nexec /bin/sleep 30\n' "$INTERRUPT_PID_FILE" > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/sleep" "$DELEGATE_BIN/opencode"
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" interrupted-survey "$SURVEY_REQUEST" > delegate-interrupted.out 2>&1 &
INTERRUPTED_RUNNER_PID=$!
INTERRUPT_WAIT_COUNT=0
while [ ! -f "$INTERRUPT_PID_FILE" ] && kill -0 "$INTERRUPTED_RUNNER_PID" 2>/dev/null && [ "$INTERRUPT_WAIT_COUNT" -lt 100 ]; do
  /bin/sleep 0.02
  INTERRUPT_WAIT_COUNT=$((INTERRUPT_WAIT_COUNT + 1))
done
INTERRUPTED_STATE="$DELEGATE_REPO/.claude/tmp/worker/.interrupted-survey.task/state.json"
PATH="$DELEGATE_BIN:$PATH" bash "$DELEGATE_SCRIPT" show interrupted-survey > delegate-show-running.out 2>&1
RUNNING_SHOW_STATUS=$?
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" interrupted-survey "$SURVEY_REQUEST" > delegate-duplicate.out 2>&1
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
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" timeout-idle-survey "$SURVEY_REQUEST" > delegate-timeout-idle.out 2>&1
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
PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" timeout-hard-survey "$SURVEY_REQUEST" > delegate-timeout-hard.out 2>&1
HARD_TIMEOUT_STATUS=$?
HARD_TIMEOUT_ROOT="$DELEGATE_REPO/.claude/tmp/worker/timeout-hard-survey"
HARD_TIMEOUT_PID=$(sed -n '1p' "$TIMEOUT_PID_FILE")
if [ "$HARD_TIMEOUT_STATUS" -eq 124 ] && [ "$(jq -r '.timeout_kind' "$HARD_TIMEOUT_ROOT/result.json" 2>/dev/null)" = "hard" ] && [ "$(jq -r '.report_status' "$HARD_TIMEOUT_ROOT/result.json" 2>/dev/null)" = "partial" ] && grep -Fxq 'partial' "$HARD_TIMEOUT_ROOT/report.md" && ! kill -0 "$HARD_TIMEOUT_PID" 2>/dev/null; then
  ok "delegate-worker: 総時間timeoutでも途中文章を診断用に保持"
else
  ng "delegate-worker: 総時間timeoutまたは部分出力の扱いが不正"; cat delegate-timeout-hard.out; cat "$HARD_TIMEOUT_ROOT/result.json"
fi
rm -f "$DELEGATE_BIN/date" "$DELEGATE_BIN/sleep" "$TIMEOUT_CLOCK" "$TIMEOUT_PID_FILE"
printf '#!/bin/bash\nprintf '\''changed ignored rule\\n'\'' > .codex/rules/ignored.rules\nprintf '\''{"type":"text","text":"done"}\\n'\''\n' > "$DELEGATE_BIN/opencode"
chmod +x "$DELEGATE_BIN/opencode"
if PATH="$DELEGATE_BIN:$PATH" OPENROUTER_API_KEY=test bash "$DELEGATE_SCRIPT" survey "${DELEGATE_TIMEOUT_ARGS[@]}" rejected-context-mutation "$SURVEY_REQUEST" > delegate-rejected-context.out 2>&1; then
  ng "delegate-worker: 読み取りsnapshotの変更を許可した"
elif grep -Fq 'delegated model changed an ignored context file: .codex/rules/ignored.rules' delegate-rejected-context.out && [ "$(jq -r '.failure_reason' "$DELEGATE_REPO/.claude/tmp/worker/.rejected-context-mutation.task/state.json" 2>/dev/null)" = 'delegated model changed an ignored context file: .codex/rules/ignored.rules' ] && [ ! -e "$DELEGATE_REPO/.claude/tmp/worker/rejected-context-mutation" ]; then
  ok "delegate-worker: snapshot変更を拒否して復旧可能なfailure reasonを残す"
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
grep -q '^default_subagent_model = "gpt-5.6-luna"$' .codex/config.toml && grep -q '^default_subagent_reasoning_effort = "max"$' .codex/config.toml && ok "bootstrap codex はsubagent既定をLuna maxへ固定" || ng "bootstrap codex のsubagent既定model・effortが不正"
git config user.email tester@example.com
git config user.name tester
mkdir -p src
printf 'export const codexImplementation = true\n' > src/codex-implementation.ts
printf 'export const codexUntouched = true\n' > src/codex-untouched.ts
git add src/codex-implementation.ts src/codex-untouched.ts
git commit -qm "test: Codex implementation scope fixture"
CODEX_CAPTURE_SCOPE=".agents/skills/polish/capture-scope.sh"
CODEX_IMPLEMENTATION_VALIDATOR=".agents/skills/tdd/validate-implementation-request.sh"
CODEX_TASK_DIR=".codex/tmp/worker/codex-implementation-survey"
mkdir -p "$CODEX_TASK_DIR"
printf 'Outcome: fulfilled\n' > "$CODEX_TASK_DIR/report.md"
printf '# Verified evidence\n' > "$CODEX_TASK_DIR/evidence.md"
jq -n \
  --arg report_blob "$(git hash-object "$CODEX_TASK_DIR/report.md")" \
  --arg evidence_blob "$(git hash-object "$CODEX_TASK_DIR/evidence.md")" \
  '{mode:"survey",task_id:"codex-implementation-survey",status:0,output_contract_status:"valid",outcome:"fulfilled",evidence_status:"verified",changed_paths:[],report_file:"report.md",evidence_file:"evidence.md",report_blob:$report_blob,evidence_blob:$evidence_blob}' \
  > "$CODEX_TASK_DIR/result.json"
mkdir -p tests/codex
printf 'test fixture\n' > tests/codex/implementation-flow.test.ts
git add tests/codex/implementation-flow.test.ts
git commit -qm "test: Codex implementation request fixture"
CODEX_IMPLEMENTATION_REQUEST=$(jq -cn '{version:3,action:"implement",scope:"codex-implementation",spec:null,implementation_instruction:"対象機能の全要件を初回実装する",worker_tasks:[{task_id:"codex-implementation-survey",result:".codex/tmp/worker/codex-implementation-survey/result.json",report:".codex/tmp/worker/codex-implementation-survey/report.md",evidence:".codex/tmp/worker/codex-implementation-survey/evidence.md"}],test_scenarios:[{id:"S1",contract:"対象値を期待値へ変更する"}],test_paths:["tests/codex/implementation-flow.test.ts"],red:{command:"npm test",status:1,reason:"期待値差で失敗"},test_exemption:null,allowed_paths:["src/codex-implementation.ts"]}')
CODEX_IMPLEMENTATION_HOOK=".codex/hooks/shell/protect-implementation-scope.sh"
if bash "$CODEX_CAPTURE_SCOPE" codex-implementation -- src/codex-implementation.ts > codex-implementation-capture.out 2>&1 && \
   bash "$CODEX_IMPLEMENTATION_VALIDATOR" "$CODEX_IMPLEMENTATION_REQUEST" > codex-implementation-request.out 2>&1 && \
   jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"CPARENT1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .agents/skills/polish/capture-scope.sh activate codex-implementation"}}' | bash "$CODEX_IMPLEMENTATION_HOOK" >/dev/null && \
   bash "$CODEX_CAPTURE_SCOPE" activate codex-implementation > codex-implementation-activate.out 2>&1; then
  ok "codex implementation-scope: activate"
else
  ng "codex implementation-scope: activate失敗"; cat codex-implementation-capture.out codex-implementation-activate.out
fi
CODEX_ALLOW_PATCH=$(jq -n --arg cwd "$PWD" --arg command $'*** Begin Patch\n*** Update File: src/codex-implementation.ts\n+x\n*** End Patch' '{hook_event_name:"PreToolUse",session_id:"CIMPL1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:$command}}' | bash "$CODEX_IMPLEMENTATION_HOOK")
CODEX_DENY_PARENT_PATCH=$(jq -n --arg cwd "$PWD" --arg command $'*** Begin Patch\n*** Update File: src/codex-implementation.ts\n+x\n*** End Patch' '{hook_event_name:"PreToolUse",session_id:"CPARENT1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:$command}}' | bash "$CODEX_IMPLEMENTATION_HOOK")
CODEX_DENY_PATCH=$(jq -n --arg cwd "$PWD" --arg command $'*** Begin Patch\n*** Update File: src/codex-untouched.ts\n+x\n*** End Patch' '{hook_event_name:"PreToolUse",session_id:"CIMPL1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:$command}}' | bash "$CODEX_IMPLEMENTATION_HOOK")
CODEX_ALLOW_IMPLEMENTER_READ=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"CIMPL1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .agents/skills/tdd/implementer-read.sh src/codex-implementation.ts"}}' | bash "$CODEX_IMPLEMENTATION_HOOK")
CODEX_ALLOW_PARENT_READ=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"CPARENT1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .agents/skills/tdd/implementer-read.sh .codex/tmp/worker/codex-implementation-survey/evidence.md"}}' | bash "$CODEX_IMPLEMENTATION_HOOK")
CODEX_DENY_BASH=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"CIMPL1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"git status --short"}}' | bash "$CODEX_IMPLEMENTATION_HOOK")
CODEX_DENY_SUBAGENT_DEACTIVATE=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"CIMPL1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .agents/skills/polish/capture-scope.sh deactivate codex-implementation"}}' | bash "$CODEX_IMPLEMENTATION_HOOK")
CODEX_ALLOW_PARENT_DEACTIVATE=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"CPARENT1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .agents/skills/polish/capture-scope.sh deactivate codex-implementation"}}' | bash "$CODEX_IMPLEMENTATION_HOOK")
CODEX_ALLOW_PARENT_HANDOFF=$(jq -n --arg cwd "$PWD" '{hook_event_name:"PreToolUse",session_id:"CPARENT1",cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash .agents/skills/polish/capture-scope.sh handoff-to-parent codex-implementation"}}' | bash "$CODEX_IMPLEMENTATION_HOOK")
CODEX_READ_OUTPUT=$(bash .agents/skills/tdd/implementer-read.sh src/codex-implementation.ts)
if [ -z "$CODEX_ALLOW_PATCH" ] && [ -z "$CODEX_ALLOW_IMPLEMENTER_READ" ] && [ -z "$CODEX_ALLOW_PARENT_READ" ] && printf '%s' "$CODEX_READ_OUTPUT" | grep -Fq 'codexImplementation' && [ "$(echo "$CODEX_DENY_PARENT_PATCH" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && [ "$(echo "$CODEX_DENY_PATCH" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && [ "$(echo "$CODEX_DENY_BASH" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && [ "$(echo "$CODEX_DENY_SUBAGENT_DEACTIVATE" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && [ -z "$CODEX_ALLOW_PARENT_DEACTIVATE" ] && [ -z "$CODEX_ALLOW_PARENT_HANDOFF" ]; then
  ok "codex implementation-scope: subagentは許可fileを読み書きし親は読み取りだけ可能"
else
  ng "codex implementation-scope: subagent境界が不正"
fi
if bash "$CODEX_CAPTURE_SCOPE" handoff-to-parent codex-implementation > codex-implementation-handoff.out 2>&1; then
  CODEX_ALLOW_PARENT_FALLBACK_PATCH=$(jq -n --arg cwd "$PWD" --arg command $'*** Begin Patch\n*** Update File: src/codex-implementation.ts\n+x\n*** End Patch' '{hook_event_name:"PreToolUse",session_id:"CPARENT1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:$command}}' | bash "$CODEX_IMPLEMENTATION_HOOK")
  CODEX_DENY_IMPLEMENTER_FALLBACK_PATCH=$(jq -n --arg cwd "$PWD" --arg command $'*** Begin Patch\n*** Update File: src/codex-implementation.ts\n+x\n*** End Patch' '{hook_event_name:"PreToolUse",session_id:"CIMPL1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:$command}}' | bash "$CODEX_IMPLEMENTATION_HOOK")
  mkdir -p .codex/tmp
  : > .codex/tmp/session.tdd.CPARENT1
  CODEX_ALLOW_FALLBACK_TEST=$(jq -n --arg cwd "$PWD" --arg command $'*** Begin Patch\n*** Update File: src/codex-implementation.ts\n+x\n*** End Patch' '{hook_event_name:"PreToolUse",session_id:"CPARENT1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:$command}}' | bash .codex/hooks/shell/require-test.sh)
  rm -f .codex/tmp/session.tdd.CPARENT1
  if [ -z "$CODEX_ALLOW_PARENT_FALLBACK_PATCH" ] && [ -z "$CODEX_ALLOW_FALLBACK_TEST" ] && [ "$(echo "$CODEX_DENY_IMPLEMENTER_FALLBACK_PATCH" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ]; then
    ok "codex implementation-scope: handoff後もtest承認を維持して親だけ書き込み可"
  else
    ng "codex implementation-scope: parent fallback境界が不正"
  fi
else
  ng "codex implementation-scope: handoff失敗"; cat codex-implementation-handoff.out
fi
if bash "$CODEX_CAPTURE_SCOPE" deactivate codex-implementation > codex-implementation-deactivate.out 2>&1 && ! bash .agents/skills/tdd/implementer-read.sh src/codex-implementation.ts >/dev/null 2>&1; then ok "codex implementation-scope: deactivateでreceiptを掃除"; else ng "codex implementation-scope: deactivate失敗"; cat codex-implementation-deactivate.out; fi
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
grep -Fq 'normalize_default_delegate_model' .codex/hooks/shell/readonly-search.sh && grep -Fq 'DELEGATE_MODEL=openrouter/minimax/minimax-m3' .codex/hooks/shell/readonly-search.sh && ok "codex: 既定workerモデルのwrapper化をhookで除去" || ng "codex: 既定workerモデルのwrapper化防止が不足"
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
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("protect-implementation-scope.sh"))] | length' .codex/hooks.json)" = "$EXPECTED_DUAL_HOOK_BINDINGS" ] && ok "実装scope hookを apply_patch/Bash の両方へ配線" || ng "実装scope hookの配線漏れ"
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
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/worker/delegate.sh research --hard-timeout-minutes 10 --idle-timeout-seconds 120 --poll-seconds 5 --timeout-reason scope=spec,difficulty=medium,basis=contract-review task-id .codex/prompt/branch-task-prompt.md 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: delegate-worker の固定経路を allow" || ng "rules: delegate-worker 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/worker/delegate.sh smoke 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "prompt" ] && ok "rules: 課金smokeだけを prompt" || ng "rules: worker smoke判定失敗 out=[$OUT]"
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
jq -e '.permissions.allow | index("Bash(zat:*)")' "$SL" >/dev/null 2>&1 && grep -Fq 'worker | コードベースの読み取り専用調査と根拠収集' "$WORKER_CONTRACT" && grep -Fq '`research`、`survey`、`nesting`以外の仕事を渡さない' "$WORKER_CONTRACT" && grep -Fq 'EDIT_RULES='\''{"*":"deny"}'\''' "$WORKER_RUNNER" && ok "outline: workerを読み取り調査とzatへ限定" || ng "outline: workerの読み取り専用境界が不足"
jq -e '.sandbox.excludedCommands | (index("./base/scripts/run-unit.sh") != null and index("./base/scripts/run-unit.sh *") != null)' "$SJ" >/dev/null 2>&1 && jq -e '.permissions.allow | (index("Bash(./base/scripts/run-unit.sh)") != null and index("Bash(./base/scripts/run-unit.sh:*)") != null)' "$SL" >/dev/null 2>&1 && ok "Claude: 承認済みunit test runnerをlocalでallow" || ng "Claude: unit test runnerの自動実行設定が不足"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("protect-locks.sh"))] | length' "$SJ")" = "$EXPECTED_DUAL_HOOK_BINDINGS" ] && ok "Claude lockfile保護hookをBash/Editへ配線" || ng "Claude lockfile保護hookの配線漏れ"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("protect-implementation-scope.sh"))] | length' "$SJ")" = "$EXPECTED_DUAL_HOOK_BINDINGS" ] && ok "Claude実装scope hookをBash/Editへ配線" || ng "Claude実装scope hookの配線漏れ"
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
for SC in bootstrap/init-agent.sh tdd/mark-prompt-done.sh polish/quality-gate.sh polish/capture-scope.sh worker/delegate.sh e2e/apply-e2e-plan.sh; do
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
