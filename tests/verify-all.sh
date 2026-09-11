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
METADATA_COMMANDS=(touch chmod chown chgrp)
CONTENT_WRITER_COMMANDS=(dd truncate tee patch rsync)
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

echo "== 1. 構文チェック =="
GROUP_FAILURES=
for f in "$REPO"/hooks/shell/*.sh "$REPO"/skills/*/*.sh "$SUITE"/*.sh; do
  bash -n "$f" 2>/dev/null || append_group_failure "syntax: $f"
done
report_group "shell構文: 対象ファイル全件" "$GROUP_FAILURES"
echo "== 1.5 実行ビット（ハーネスが直接実行する hook は +x 必須。hook-io.sh は source 専用） =="
GROUP_FAILURES=
for f in "$REPO"/hooks/shell/*.sh; do
  case "$f" in */hook-io.sh) continue ;; esac
  [ -x "$f" ] || append_group_failure "exec bit: $f"
done
IMPLEMENTATION_RULES="$REPO/skills/IMPLEMENTATION_RULES.md"
FUNCTION_RULES="$REPO/rules/typescript/function-pattern.md"
CLAUDE_SURVEYOR="$REPO/claude/agents/surveyor.md"
CODEX_SURVEYOR="$REPO/codex/agents/surveyor.toml"
report_group "実行ビット: hookと実行器全件" "$GROUP_FAILURES"
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
COWLICK_SKILL="$REPO/skills/cowlick/PROCEDURE.md"
PONYTAIL_SKILL="$REPO/skills/ponytail/PROCEDURE.md"
PONYTAIL_CONTRACT="$REPO/skills/ponytail/REVIEW_CONTRACT.md"
COWLICK_FORMAT="$REPO/skills/cowlick/DESIGN_FORMAT.md"
REQUIRED_READING_HOOK="$REPO/hooks/shell/load-required-contract.sh"
for SKILL_FILE in "$MEETING_SKILL" "$PREFLIGHT_SKILL" "$COWLICK_SKILL" "$PONYTAIL_SKILL"; do
  [ -f "$SKILL_FILE" ] && ok "design skill存在: $(basename "$(dirname "$SKILL_FILE")")" || ng "design skill不在: $SKILL_FILE"
done
grep -q '^disable-model-invocation: true$' "$MEETING_SKILL" && grep -Fq 'ユーザーが `$meeting` を明示して' "$MEETING_SKILL" && grep -Fq '`$meeting` の明示呼び出しでだけ起動する' "$MEETING_SKILL" && grep -Fq '通常の自然言語による軽微な修正・追加依頼では起動しない' "$MEETING_SKILL" && grep -Fq '  - Skill(preflight)' "$MEETING_SKILL" && grep -Fq '../cowlick/PROCEDURE.md' "$MEETING_SKILL" && grep -Fq '../ponytail/PROCEDURE.md' "$MEETING_SKILL" && grep -Fq '  - AskUserQuestion' "$MEETING_SKILL" && grep -Fq '  - Bash' "$MEETING_SKILL" && ok "meetingを明示起動だけに限定する" || ng "meetingの起動境界・skill境界が不正"
grep -q 'preflight → cowlick → ponytail' "$MEETING_SKILL" && ! grep -q 'cowlick apply\|最終承認を得る' "$MEETING_SKILL" && ok "meetingは承認・反映phaseなしで設計する" || ng "meetingの基本順序または承認gateが不正"
for INTERNAL_SKILL in "$PREFLIGHT_SKILL"; do
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
grep -Fq '../cowlick/PROCEDURE.md' "$PONYTAIL_SKILL" && grep -Fq '専用`design-reviewer`' "$PONYTAIL_SKILL" && ok "ponytailは独立監査とcowlick手順を接続" || ng "ponytailの呼出先が不足"
for ENTRY_NAME in cowlick ponytail polish unwind; do
  ENTRY="$REPO/skills/$ENTRY_NAME/SKILL.md"
  grep -q '^disable-model-invocation: true$' "$ENTRY" && ! grep -q '^user-invocable: false$' "$ENTRY" && grep -Fq '(PROCEDURE.md)' "$ENTRY" && grep -q 'allow_implicit_invocation: false' "$REPO/skills/$ENTRY_NAME/agents/openai.yaml" && ok "明示入口と内部手順を分離: $ENTRY_NAME" || ng "明示入口の参照・起動policyが不正: $ENTRY_NAME"
done
grep -Fq 'preflight・cowlickの調査はメイン' "$MEETING_SKILL" && grep -Fq 'サブエージェントへ調査を委任しない' "$PREFLIGHT_SKILL" "$COWLICK_SKILL" && grep -Fq '専用`design-reviewer`' "$PONYTAIL_SKILL" && ok "設計作成と独立監査を分離" || ng "設計作成と監査の責務が不正"
grep -Fq '**明示要件**' "$PREFLIGHT_SKILL" && grep -Fq '**設計選択**' "$PREFLIGHT_SKILL" && grep -q '境界を新設しない基準案' "$PREFLIGHT_SKILL" && ok "preflightの要件由来・境界ゼロ契約" || ng "preflightの要件由来・境界ゼロ契約が不足"
grep -q "設計書ごと削除" "$COWLICK_SKILL" && grep -Fq "IMPLEMENTATION_RULES.md" "$COWLICK_SKILL" && grep -q "基準案で満たせない明示要件" "$IMPLEMENTATION_RULES" && ok "cowlickの最小draft契約" || ng "cowlickの最小draft契約が不足"
grep -Fq 'cowlick/DESIGN_FORMAT.md' "$REQUIRED_READING_HOOK" && grep -Fq 'Summary' "$COWLICK_FORMAT" && grep -Fq '## Changes' "$COWLICK_FORMAT" && grep -Fq 'error処理とDB書き込み、メール、外部API' "$COWLICK_FORMAT" && ok "cowlickの設計書形式を必要時に強制注入" || ng "cowlickの設計書形式参照が不正"
grep -Fq '実装者が挙動を再設計せずコードへ変換できる密度' "$COWLICK_FORMAT" && grep -Fq 'guardの評価順、導出値と計算式' "$COWLICK_FORMAT" && grep -Fq '`where`の全条件と日付境界' "$COWLICK_FORMAT" && grep -Fq 'client検証とserverの最新dataによる再検証' "$COWLICK_FORMAT" && grep -Fq '圧縮してよいのは重複説明と同一の外枠だけ' "$COWLICK_FORMAT" && grep -Fq '設計書形式の実装情報を保持' "$COWLICK_SKILL" && ok "cowlickの実装可能な疑似コード密度" || ng "cowlickの疑似コードが実装契約を省略可能"
grep -Fq '| 書き方 | 対象 | 例 |' "$COWLICK_FORMAT" && grep -Fq '予約語・演算子・構文・組み込み型/object' "$COWLICK_FORMAT" && grep -Fq '標準・外部library・framework API、method・property' "$COWLICK_FORMAT" && grep -Fq '新設する業務関数・引数・変数・型・結果field・error・処理' "$COWLICK_FORMAT" && grep -Fq '既存symbol・schema field・file path' "$COWLICK_FORMAT" && grep -Fq '設計書形式に従い' "$COWLICK_SKILL" && ok "cowlick疑似コードの英語構文・日本語識別子契約" || ng "cowlick疑似コードの言語規則が曖昧"
grep -Fq '配列は`[]`、objectは`{}`を宣言・参照の両方へ付ける' "$COWLICK_FORMAT" && grep -Fq '候補一覧[].length' "$COWLICK_FORMAT" && grep -Fq '候補一覧[].slice(...)' "$COWLICK_FORMAT" && grep -Fq '利用結果{}' "$COWLICK_FORMAT" && grep -Fq '分岐・loopは構文で書く' "$COWLICK_FORMAT" && grep -Fq '共通処理と対象固有の差を残す' "$COWLICK_FORMAT" && ok "cowlick疑似コードの形状・制御構文" || ng "cowlick疑似コードの形状・制御構文が不足"
grep -q '## 必須監査成果物' "$PONYTAIL_CONTRACT" && grep -Fq '`ponytail_audit`' "$PONYTAIL_CONTRACT" && grep -Fq '`minimalAlternative`' "$PONYTAIL_CONTRACT" && grep -Fq '`counterexamples`' "$PONYTAIL_CONTRACT" && grep -Fq '`unresolved`' "$PONYTAIL_CONTRACT" && grep -q '何も削らなかった場合' "$PONYTAIL_CONTRACT" && grep -q '全fieldが埋まり.*ponytail_ready' "$PONYTAIL_CONTRACT" && ok "ponytailの横断削除・ready gate契約" || ng "ponytailの横断削除・ready gate契約が不足"
grep -Fq '入口、共有責務、全caller・consumer' "$PONYTAIL_CONTRACT" && grep -Fq '報告された症状とroot causeを分ける' "$PONYTAIL_CONTRACT" && grep -Fq '実装が一つだけのinterface' "$PONYTAIL_CONTRACT" && grep -Fq '測定可能な条件' "$PONYTAIL_CONTRACT" && grep -Fq '[delete|reuse|stdlib|native|yagni|shrink]' "$PONYTAIL_CONTRACT" && grep -Fq '最小の実行可能なテスト' "$PONYTAIL_CONTRACT" && ok "ponytailの理解・root cause・簡素化負債契約" || ng "ponytailの理解または簡素化境界が不足"
grep -Fq "../cowlick/DESIGN_FORMAT.md" "$PONYTAIL_CONTRACT" && grep -Fq "圧縮してよいのは重複説明と同一の外枠だけ" "$COWLICK_FORMAT" && grep -Fq "文章一行へ畳まない" "$COWLICK_FORMAT" && ok "ponytailは実装契約を失う圧縮を禁止" || ng "ponytailが疑似コードの重要契約を圧縮可能"
grep -Fq '一つのfindingはIDを付けて一度だけ説明' "$PONYTAIL_CONTRACT" && grep -Fq '同じ要件・原因・判断・置換先を持つ要素は一行へまとめる' "$PONYTAIL_CONTRACT" && grep -Fq '同じtopologyや根拠を別fieldで言い換えない' "$PONYTAIL_CONTRACT" && ok "ponytailの監査正本は重複せず簡潔" || ng "ponytailの監査成果物が重複可能"
! grep -Fq "REVIEW_CONTRACT.md" "$PONYTAIL_SKILL" && grep -Fq "全監査結果または非該当理由" "$PONYTAIL_SKILL" && grep -Fq "ponytail/REVIEW_CONTRACT.md" "$REPO/hooks/shell/load-operation-context.sh" && ! grep -Fq "必須field" "$MEETING_SKILL" && ok "監査契約は子だけへ注入" || ng "監査成果物検証の責務が不正"
grep -Fq "対象path・hash・HEADを現在の対象と照合" "$MEETING_SKILL" && grep -Fq '一致した`ponytail_ready`だけで完了' "$MEETING_SKILL" && ok "meetingは現在の対象との一致とstatusを確認" || ng "meetingの結果照合が不足"
grep -Fq '内部工程の選択・再実行は自分で行い' "$MEETING_SKILL" && grep -Fq '../cowlick/PROCEDURE.md' "$PONYTAIL_SKILL" && grep -Fq '新revision・hashで新規レビュー' "$PONYTAIL_SKILL" && ok "ponytailの指摘修正はメインで再レビューは新規の子" || ng "ponytailの指摘対応が不正"
grep -Fq '呼出元へ返して停止' "$COWLICK_SKILL" && grep -Fq '`.[agent_name]/prompt/`の' "$COWLICK_SKILL" && ! grep -q '^## apply\|draft-prompt\|最終承認' "$COWLICK_SKILL" && ! grep -q 'draft-prompt\|正式反映を行わない' "$PONYTAIL_SKILL" && ok "設計書の更新はcowlickへ集約" || ng "cowlick/ponytailのprompt直接更新境界が不正"
GROUP_FAILURES=
for LEGACY_DESIGN_SKILL in design-preflight design-pipeline compose-prompt; do
  [ ! -d "$REPO/skills/$LEGACY_DESIGN_SKILL" ] || append_group_failure "旧directory: skills/$LEGACY_DESIGN_SKILL"
  if command grep -rn "$LEGACY_DESIGN_SKILL" "$REPO/README.md" "$REPO/skills" "$REPO/codex" "$REPO/claude" >/dev/null 2>&1; then
    append_group_failure "旧reference: $LEGACY_DESIGN_SKILL"
  fi
done
report_group "旧design skillのdirectory・参照なし" "$GROUP_FAILURES"

echo "== skill context圧縮と参照整合性 =="
if python3 "$SUITE/test_context_delivery.py" > "$S/context-delivery.out" 2>&1; then
  ok "代表ケースの注入先・量・回数・先読み拒否を検証"
  cat "$S/context-delivery.out"
else
  ng "代表ケースのcontext deliveryが不正"
  cat "$S/context-delivery.out"
fi
if python3 "$SUITE/test_pre_model_switch.py" > "$S/pre-model-switch.out" 2>&1; then
  ok "Baton用PreModelSwitchの注入・再試行・no-opを検証"
else
  ng "Baton用PreModelSwitchが不正"
  cat "$S/pre-model-switch.out"
fi
if [ -n "${BATON_ROOT:-}" ]; then
  if node "$SUITE/verify-baton-pre-model-switch.mjs" "$BATON_ROOT" > "$S/baton-pre-model-switch.out" 2>&1; then
    ok "Batonの実loader・runnerと配布hookを接続"
  else
    ng "Batonと配布hookの統合が不正"
    cat "$S/baton-pre-model-switch.out"
  fi
fi
E2E_SKILL="$REPO/skills/e2e/SKILL.md"
E2E_ARTIFACT_IGNORE="$REPO/e2e/artifacts/.gitignore"
if grep -Fq '`screencast_start`' "$E2E_SKILL" &&
   grep -Fq '`screencast_stop`' "$E2E_SKILL" &&
   grep -Fq '成功・失敗の両方を残す' "$E2E_SKILL" &&
   grep -Fq '成果物は削除しない' "$E2E_SKILL" &&
   [ -f "$E2E_ARTIFACT_IGNORE" ] && grep -Fxq '*' "$E2E_ARTIFACT_IGNORE" && grep -Fxq '!.gitignore' "$E2E_ARTIFACT_IGNORE"; then
  ok "e2eは動画・全screenshotをGit管理外の成果物として残す"
else
  ng "e2eの録画・screenshot保存契約が不足"
fi
GROUP_FAILURES=
[ -f "$COWLICK_FORMAT" ] || append_group_failure "cowlick設計形式なし"
[ -f "$REPO/skills/tdd/SKILL.md" ] || append_group_failure "tdd実装フローなし"
[ -f "$REPO/skills/FIX_FLOW.md" ] || append_group_failure "検証・修正の共通契約なし"
report_group "progressive disclosure参照が全件存在" "$GROUP_FAILURES"
if bash "$SUITE/verify-context-mcp.sh" > "$S/context-mcp.out" 2>&1; then
  ok "dictionary skillとMCP配布設定を統合"
else
  ng "dictionary skillまたはMCP配布設定が不正"
  cat "$S/context-mcp.out"
fi

if python3 "$SUITE/test_independent_review.py" > "$S/independent-review.out" 2>&1; then
  ok "両配置の独立レビューlifecycleを検証"
else
  ng "独立レビューlifecycleが不正"
  cat "$S/independent-review.out"
fi

echo "== メイン実装と直列の独立レビュー =="
TDD_SKILL="$REPO/skills/tdd/SKILL.md"
TDD_FROM_DOC="$REPO/skills/tdd/FROM_DOC.md"
FIX_FLOW="$REPO/skills/FIX_FLOW.md"
MODEL_SELECTION="$REPO/skills/MODEL_SELECTION.md"
[ ! -e "$REPO/claude/agents/implementer.md" ] && [ ! -e "$REPO/codex/agents/implementer.toml" ] && [ ! -e "$REPO/skills/IMPLEMENTER_LAUNCH.md" ] && [ ! -e "$REPO/skills/IMPLEMENTER_CONTRACT.md" ] && ok "実装委任資産を配布しない" || ng "実装委任資産が残存"
! grep -R -Eq 'DIFFICULTY_CONTRACT|CODE_REVIEW_CONTRACT|REVIEW_CONTRACT|NESTING_CONTRACT' "$REPO/codex/agents" "$REPO/claude/agents" && ok "子の定義へ契約pathを常駐させない" || ng "子の定義に契約の先読み参照が残存"
grep -Fxq 'max_threads = 1' "$REPO/codex/config.toml" && ok "Codexの子の同時実行を1体に制限" || ng "Codexの子の同時実行上限が不正"
grep -Fq 'INDEPENDENT_REVIEW.md' "$REPO/hooks/shell/load-operation-context.sh" && grep -Fq '専用reviewerで独立レビュー' "$TDD_SKILL" && ok "tddの完了前に独立レビューを接続" || ng "独立レビューの入口が不足"
[ ! -e "$CLAUDE_SURVEYOR" ] && [ ! -e "$CODEX_SURVEYOR" ] && ok "native surveyor定義を削除" || ng "native surveyor定義が残存"
grep -Fq '`claude/agents/` | `<repo>/.claude/agents/`' "$REPO/README.md" && grep -Fq '`codex/agents/` | `<repo>/.codex/agents/`' "$REPO/README.md" && ok "README: 両agent定義の配布先を明記" || ng "README: agent定義の配布先が不足"
[ -f "$TDD_SKILL" ] && ! grep -q '^disable-model-invocation: true$' "$TDD_SKILL" && grep -q 'allow_implicit_invocation: true' "$REPO/skills/tdd/agents/openai.yaml" && ok "tddは自動選択と明示起動を許可" || ng "tddの自動選択設定が不正"
[ ! -d "$REPO/skills/errand" ] && [ ! -e "$REPO/skills/SCENARIO_FLOW.md" ] && [ ! -e "$REPO/rules/typescript/tdd-pattern.md" ] && ! grep -Eq 'SCENARIO_FLOW.md|tdd-pattern.md|\$errand' "$TDD_SKILL" "$REPO/skills/IMPLEMENTATION_RULES.md" && ok "廃止した実装skill・共通フロー・test規約を配布しない" || ng "廃止資産または参照が残存"
grep '^description:' "$TDD_SKILL" | grep -Fq 'runtime挙動を実装・修正する依頼' && grep '^description:' "$TDD_SKILL" | grep -Fq '文書・設定・書式だけの変更、挙動を変えない整理では起動しない' && grep -Fq '依頼の識別子・path・番号・固有名詞は変えない' "$TDD_SKILL" && ok "tddは選択境界と依頼の識別子を保持" || ng "tddの選択・依頼境界が不正"
grep -Fq '`prompt/`を読まない' "$TDD_SKILL" && grep -Fq '`$tdd --from-doc`はユーザーが明示した場合だけ使い、通常起動から切り替えない' "$TDD_SKILL" && grep -Fq '[設計書モード](FROM_DOC.md)' "$TDD_SKILL" && grep -Fq '`$tdd --from-doc`だけが読む' "$TDD_FROM_DOC" && grep -Fq '参照先がない、または未完了項目がなければ変更せず報告' "$TDD_FROM_DOC" && ok "tddは通常依頼と明示的な設計書modeを分離" || ng "tddの入力・完了処理の分岐が不正"
grep -Fq "調査・実装・修正・検証はメインが行う" "$TDD_SKILL" && grep -Fq "メインが指摘範囲を直接修正する" "$FIX_FLOW" && ! grep -Eq '初回実装を先に代行せず|2回連続|下位モデルに再実装させる' "$TDD_SKILL" "$FIX_FLOW" && ok "tddフローは初回実装・修正をメインで続行" || ng "直列委任の強制または失敗回数による代行制限が残存"
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

echo "== tdd の通常実装・設計書実装と最終品質ゲート =="
POLISH_SKILL="$REPO/skills/polish/PROCEDURE.md"
UNWIND_SKILL="$REPO/skills/unwind/PROCEDURE.md"
TDD_SKILL="$REPO/skills/tdd/SKILL.md"
TDD_FROM_DOC="$REPO/skills/tdd/FROM_DOC.md"
QUALITY_GATE_SCRIPT="$REPO/skills/polish/quality-gate.sh"
CAPTURE_SCOPE_SCRIPT="$REPO/skills/polish/capture-scope.sh"
MARK_PROMPT_DONE_SCRIPT="$REPO/skills/tdd/mark-prompt-done.sh"
if python3 "$REPO/tests/validate-skills.py" "$REPO"/skills/*/SKILL.md; then ok "全skillの配布形式を検証"; else ng "skillの配布形式が不正"; fi
if python3 "$REPO/tests/test_validate_skills.py"; then ok "skill検査器の正常系・異常系"; else ng "skill検査器の回帰"; fi
grep -Fq '../unwind/PROCEDURE.md' "$POLISH_SKILL" && grep -q '必ず実行する' "$POLISH_SKILL" && ok "polish はunwindを必須化" || ng "polish のunwind連携が無い"
grep -q '新しい関数・メソッド・helperへ切り出して直後に呼ぶ' "$UNWIND_SKILL" && grep -q 'IIFE、callback、lambda、local functionへ押し込む' "$UNWIND_SKILL" && ok "unwind は見せかけの関数抽出を禁止" || ng "unwind の関数抽出禁止が無い"
grep -Fq '独立レビューとして検出候補の抽出だけ' "$UNWIND_SKILL" && grep -Fq '専用`nesting-reviewer`' "$UNWIND_SKILL" && grep -Fq '入力された本体コードのpathだけ' "$UNWIND_SKILL" && grep -Fq '機能の目的、要件、設計、変更範囲の調査は依頼しない' "$UNWIND_SKILL" && grep -Fq '../unwind/PROCEDURE.md' "$POLISH_SKILL" && grep -Fq '候補の採否、修正・却下判断、検証はメイン' "$UNWIND_SKILL" && ok "unwind は独立検出とメインの修正を分離" || ng "unwind の限定QA・判断責務分離が無い"
[ -x "$QUALITY_GATE_SCRIPT" ] && bash -n "$QUALITY_GATE_SCRIPT" && grep -Fq 'quality-gate.sh <機能名> -- <実変更path>...' "$POLISH_SKILL" && ! grep -Eq 'record|verify|HEAD.*receipt' "$QUALITY_GATE_SCRIPT" && ok "polish の単回path検査器が有効" || ng "polish の単回path検査器が不正"
[ -x "$CAPTURE_SCOPE_SCRIPT" ] && bash -n "$CAPTURE_SCOPE_SCRIPT" && grep -Fq 'capture-scope.sh <scope名> --auto' "$REPO/skills/polish/BASELINE.md" && grep -Fq '../polish/BASELINE.md' "$TDD_SKILL" && grep -Fq 'capture-scope.sh list-changed <機能名>' "$TDD_FROM_DOC" && ! grep -Eq 'capture-scope.sh (status|activate|recover-to-parent|handoff-to-parent|deactivate)' "$TDD_SKILL" "$TDD_FROM_DOC" && ok "tddは自動baselineと実変更pathだけを使う" || ng "tddにactive implementation scopeが残存"
! grep -Fq 'validate-implementation-request.sh' "$TDD_SKILL" && ! grep -Fq 'implementer-read.sh' "$TDD_SKILL" && ! grep -Fq 'allowed_paths' "$TDD_SKILL" && ok "tddはartifact validator・quoted reader・exact許可pathに依存しない" || ng "tddに過剰な実装制御が残存"
grep -Fq 'quality-gate.sh <機能名> -- <実変更path>...' "$POLISH_SKILL" && grep -Fq '完了receiptの記録や後続での再検証は行わない' "$POLISH_SKILL" && grep -Fq '独自のESLint rule、`no-magic-numbers`、import規則を追加しない' "$POLISH_SKILL" && ! grep -Eq 'eslint|no-magic-numbers|no-restricted-syntax' "$QUALITY_GATE_SCRIPT" && ok "polish は実変更path一致とtracked・cleanだけを単回検査" || ng "polish の実変更path検査が不正"
grep -Fq '**verified**' "$POLISH_SKILL" && grep -Fq '**direct**' "$POLISH_SKILL" && grep -Fq 'receipt欠落は停止し、directへ降格しない' "$POLISH_SKILL" && grep -Fq '品質検査をPrettier / ESLintだけへ縮小しない' "$POLISH_SKILL" && grep -Fq 'quality-gate.sh <機能名> --direct-check -- <明示path>...' "$POLISH_SKILL" && grep -Fq 'quality-gate.sh <機能名> --direct -- <明示path>...' "$POLISH_SKILL" && grep -Fq 'scope-unverified' "$POLISH_SKILL" "$REPO/README.md" && grep -Fq -- '--direct-check' "$QUALITY_GATE_SCRIPT" && grep -Fq -- '--direct' "$QUALITY_GATE_SCRIPT" && ok "polish はverifiedとdirectの保証差を明示" || ng "polish のverified/direct mode契約が不正"
! grep -Fq 'quality-gate.sh' "$MARK_PROMPT_DONE_SCRIPT" && grep -Fq '完了markを付けるか確認する' "$TDD_FROM_DOC" && grep -Fq 'ユーザーが付けると回答した場合だけ' "$TDD_FROM_DOC" && ok "tdd はユーザー判断だけでindexを更新" || ng "tdd が完了マークを自動判定"
[ -f "$FIX_FLOW" ] && grep -Fq '../FIX_FLOW.md' "$TDD_SKILL" && grep -Fq 'FIX_FLOW.md' "$POLISH_SKILL" "$UNWIND_SKILL" && ok "tdd・polish・unwindは検証・修正契約を共有" || ng "検証・修正フロー参照が不正"
grep -Fq '../MODEL_SELECTION.md' "$TDD_SKILL" && grep -Fq 'MODEL_SELECTION.md' "$FIX_FLOW" && ! grep -Eq 'require-implementer|専用定義|IMPLEMENTER_CONTRACT.md' "$TDD_SKILL" && ok "tddはメインモデル選択に従い直接実装する" || ng "tddに実装専用agentの必須条件が残存"
grep -Fq '## 調査' "$TDD_SKILL" && grep -Fq '`path:line`' "$TDD_SKILL" && grep -Fq '必須事実が足りなければ追加調査' "$TDD_SKILL" && ! grep -Fq 'SUBAGENT_RULES.md' "$TDD_SKILL" && ! grep -Fq 'IMPLEMENTATION_RULES.md' "$REPO/skills/preflight/SKILL.md" && grep -Fq 'シナリオと実装方針を決める前に[共通基準]' "$TDD_SKILL" && ok "調査後・設計前に共通基準を読む" || ng "共通基準の読込時点が不正"
grep -Fq '## シナリオ選択' "$TDD_SKILL" && grep -Fq '採用・不採用・修正をユーザーへ確認' "$TDD_SKILL" && grep -Fq '全件採用を既定にしない' "$TDD_SKILL" && grep -Fq 'シナリオの不採用を実装要件の削減理由にしない' "$TDD_SKILL" && grep -Fq '選択確定まで編集せず' "$TDD_SKILL" && grep -Fq '新しいtestが必要なだけでは止めず' "$TDD_SKILL" && ! grep -Eq 'agent_type|subagent_type|fork_context|fork_turns|agent_nickname|preflight-implementer.sh' "$TDD_SKILL" && ok "tddフローはtest選択権・実装範囲・メイン実装を維持" || ng "tddフローのtest選択権・実装境界が不正"
grep -Fq 'API・DB処理はPrisma mockでなくtest DBを使う' "$TDD_SKILL" && grep -Fq '実装不足または期待値との差により失敗' "$TDD_SKILL" && grep -Fq 'syntax・import・型の失敗はシナリオを変えず先に直す' "$TDD_SKILL" && ok "tddはDB境界と有効なRedを維持" || ng "tddのtest方式またはRed判定が不正"
grep -Fq "IMPLEMENTATION_RULES.md" "$FIX_FLOW" && grep -Fq "制御フローとdata変換を上から追える" "$IMPLEMENTATION_RULES" && grep -Fq "関数ジャンプ" "$IMPLEMENTATION_RULES" && grep -Fq "YAGNI" "$IMPLEMENTATION_RULES" && grep -Fq "filter().map()" "$FUNCTION_RULES" && grep -Fq "reduce()" "$FUNCTION_RULES" && ok "上位モデルは共有基準で保守性と可読性をレビュー" || ng "上位モデルの共有判断基準が不足"
! grep -Eq '自己確認|最終レビュー|再レビュー' "$FIX_FLOW" "$TDD_SKILL" && grep -Fq 'メインによる全差分の自己レビューは工程に含めない' "$REPO/skills/INDEPENDENT_REVIEW.md" && ok "メインの全差分自己レビューを工程から除外" || ng "自己レビュー工程が残存"
grep -Fq '降格ができない' "$REPO/skills/MODEL_SWITCH.md" && grep -Fq '現在のモデルで続行する' "$REPO/skills/MODEL_SWITCH.md" && grep -Fq '必要な昇格ができない' "$REPO/skills/MODEL_SWITCH.md" && grep -Fq 'その判断に依存する変更を止め' "$REPO/skills/MODEL_SWITCH.md" && grep -Fq 'ユーザーの明示指定を満たせない' "$REPO/skills/MODEL_SWITCH.md" && ok "モデル切り替え不能時は降格・昇格・明示指定を区別" || ng "切り替え不能時の分岐が不足"
grep -Fq '`medium`、`low`の順で各指摘の先頭に通し番号' "$REPO/skills/INDEPENDENT_REVIEW.md" && grep -Fq '修正する番号を指定してください' "$REPO/skills/INDEPENDENT_REVIEW.md" && grep -Fq '同じfile内の関数・section・testへの指摘が再発した場合' "$FIX_FLOW" && grep -Fq 'LunaからSol、SolからAstraへ昇格し、Astra / highでは維持する' "$FIX_FLOW" && ok "レビューseverityと再発時のモデル昇格を分離" || ng "レビューseverityの処理が不正"
grep -Fq '変更file・直接依存先以外の未変更文書' "$REPO/skills/CODE_REVIEW_CONTRACT.md" && grep -Fq '採点・モデル選択・切替手順はrequirementsへ含めない' "$REPO/skills/INDEPENDENT_REVIEW.md" && grep -Fq '文書変更のreviewerは変更fileと直接依存先だけを読む' "$REPO/README.md" && grep -Fq 'CODE_REVIEW_CONTRACT.md' "$REPO/hooks/shell/load-operation-context.sh" && ok "レビューの参照範囲を子へ限定注入" || ng "レビューの参照範囲が過剰"
grep -Fq '変更範囲・整合性条件・検証方法を含む実装方針を確定' "$MODEL_SELECTION" && grep -Fq 'テストを含む最初の編集前' "$MODEL_SELECTION" && grep -Fq '同じ方針の修正・再開では再利用' "$MODEL_SELECTION" && [ -s "$REPO/skills/DIFFICULTY_CONTRACT.md" ] && ok "方針確定後・最初の編集前に独立難度評価" || ng "独立難度評価の順序または再利用条件が不正"
grep -Fq '`schema.prisma`、`constants.ts` / `constants.js`、`constants/`だけの変更' "$TDD_SKILL" && grep -Fq '候補提示・test追加・Red / Greenを省略' "$TDD_SKILL" && grep -Fq '他のruntime挙動も変える場合はその挙動を通常どおり扱う' "$TDD_SKILL" && ok "tddフローはschema・定数のtest除外境界を固定" || ng "tddフローのschema・定数test除外境界が不正"
grep -Fq '選択済みtest、直接の回帰test、変更packageのtypecheck' "$TDD_SKILL" && grep -Fq '`tsc -p <tsconfig> --noEmit`' "$TDD_SKILL" && grep -Fq '無関係なpackage・repository全体へ広げず' "$TDD_SKILL" && grep -Fq 'Prisma `format`・`validate`・`generate`' "$TDD_SKILL" && ok "tddフローは調査commandと最終検証の範囲を固定" || ng "tddフローの調査commandまたは最終検証が曖昧"
grep -Fq '../FIX_FLOW.md' "$TDD_SKILL" && grep -Fq "FIX_FLOW.md#診断のscope帰属" "$POLISH_SKILL" && grep -Fq "scope-related" "$FIX_FLOW" && grep -Fq "unrelated" "$FIX_FLOW" && grep -Fq "uncertain" "$FIX_FLOW" && grep -Fq "ignored / untracked test" "$FIX_FLOW" && grep -Fq "どの分類が残っていても完了マークを自動判定せず" "$FIX_FLOW" && ok "tdd・polishは対象外失敗と完了判断を分離" || ng "対象外失敗がタスク完了を自動阻止"
grep -Fq 'この出力と完全一致する相対path全件を一括入力' "$POLISH_SKILL" && grep -Fq 'directory、glob、`git diff`・`git status`から推測・拡張しない' "$POLISH_SKILL" && grep -Fq 'typecheck・build・Prisma検証には所属package/schemaだけ' "$POLISH_SKILL" && grep -Fq '確定済みの対象pathから本体コードだけを選び'  "$POLISH_SKILL" && grep -Fq '`unwind`自身では差分を再探索・再検証しない' "$UNWIND_SKILL" && grep -Fq '`list-changed`をもう一度実行しない' "$POLISH_SKILL" && ok "polishとunwindは実変更pathを再探索せず対象化" || ng "polishまたはunwindが実変更pathを再探索"
grep -Fq 'packageに`build` scriptあり' "$POLISH_SKILL" && grep -Fq 'packageで`yarn build`' "$POLISH_SKILL" && grep -Fq 'commandなしは`not run`' "$POLISH_SKILL" && grep -Fq '入力の検証結果にある同じpackageのbuildを再実行する' "$UNWIND_SKILL" && grep -Fq '新しいbuild commandを発明しない' "$UNWIND_SKILL" && ok "polishは所属packageをbuildしunwind修正後に同じbuildを再検証" || ng "polishまたはunwindのbuild検証契約が不正"
grep -Fq '../polish/PROCEDURE.md' "$TDD_FROM_DOC" && grep -Fq '実変更pathをまとめて[polish]' "$TDD_FROM_DOC" && grep -Fq 'polish後に専用reviewerで独立レビュー' "$TDD_FROM_DOC" && grep -Fq '通常起動は検証とcommit後に専用reviewerで独立レビュー' "$TDD_SKILL" && grep -Fq 'bash [skills_root]/tdd/mark-prompt-done.sh <機能名>' "$TDD_FROM_DOC" && ok "tdd はpolish後の最終差分をreviewしてindexを更新" || ng "tdd のpolish・review・index更新順が不正"
grep -Fq 'capture-scope.sh <scope名> --auto' "$REPO/skills/polish/BASELINE.md" && grep -Fq '[baseline](../polish/BASELINE.md)' "$TDD_SKILL" && ok "tdd はRed後の基準commitから実変更pathを自動列挙" || ng "tdd の自動baselineが不正"
grep -Fq 'fileごとに分割しない' "$TDD_FROM_DOC" && grep -Fq 'formatterがformat差分を自動修正' "$POLISH_SKILL" && grep -Fq '`FIX_FLOW.md`に従って修正' "$POLISH_SKILL" && grep -Fq '全品質ゲートを再実行' "$POLISH_SKILL" && ok "tdd はpolishを全path一括で原因別に反復" || ng "tdd のpolish実行単位または反復条件が不正"

echo "== 2. claude 配置シミュレーション =="
mkdir -p "$S/claude-sim/.claude"
cp "$REPO/AGENTS.md" "$S/claude-sim/"
cp -R "$REPO/hooks" "$S/claude-sim/.claude/hooks"
cp -R "$REPO/skills" "$S/claude-sim/.claude/skills"
cp -R "$REPO/rules" "$S/claude-sim/.claude/rules"
cp -R "$REPO/claude/agents" "$S/claude-sim/.claude/agents"
cp -R "$REPO/e2e" "$S/claude-sim/.claude/e2e"
cd "$S/claude-sim"
git init -q
touch .claude/e2e/artifacts/test.webm
git check-ignore -q .claude/e2e/artifacts/test.webm && ok "ClaudeのE2E成果物をGit管理外にする" || ng "ClaudeのE2E成果物がGit管理対象"
git config user.email tester@example.com
git config user.name tester
git commit --allow-empty -qm "test: 品質ゲートfixtureを初期化"
touch SOURCE_REPOSITORY.md
if bash .claude/skills/bootstrap/bootstrap.sh claude > init-source.log 2>&1; then
  ng "bootstrap は配布元での実行を拒否"
else
  ok "bootstrap は配布元での実行を拒否"
fi
[ -d .claude/skills/bootstrap ] && ok "bootstrap は失敗時に残る" || ng "bootstrap が失敗時に消えた"
rm SOURCE_REPOSITORY.md
mkdir -p "$S/bootstrap-failing-bin"
printf '%s\n' '#!/bin/bash' 'exit 2' > "$S/bootstrap-failing-bin/grep"
chmod +x "$S/bootstrap-failing-bin/grep"
if PATH="$S/bootstrap-failing-bin:$PATH" bash .claude/skills/bootstrap/bootstrap.sh claude > init-search-failure.log 2>&1; then
  ng "bootstrap は探索失敗を拒否"
else
  ok "bootstrap は探索失敗を拒否"
fi
[ -d .claude/skills/bootstrap ] && ok "bootstrap は探索失敗後も再試行可能" || ng "bootstrap が探索失敗後に消えた"
if bash .claude/skills/bootstrap/bootstrap.sh claude > init-claude.log 2>&1; then ok "bootstrap claude 実行"; else ng "bootstrap claude 実行"; cat init-claude.log; fi
[ ! -e .claude/skills/bootstrap ] && ok "bootstrap claude は成功後に自己削除" || ng "bootstrap claude が成功後に残った"
[ -f .claude/skills/tdd/SKILL.md ] && ok "bootstrap claude は他skillを保持" || ng "bootstrap claude が他skillを削除"
if [ -f .claude/skills/MODEL_SELECTION.md ] && [ -f .claude/skills/MODEL_SWITCH.md ] && grep -Fq '.claude/skills/MODEL_SELECTION.md' AGENTS.md && grep -Fq '選定値が現在値と異なる場合は' .claude/skills/MODEL_SELECTION.md; then
  ok "モデル選択・切り替え: Claude配置と参照条件"
else
  ng "モデル選択・切り替え: Claude配置または参照条件が不正"
fi
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
touch .codex/e2e/artifacts/test.webm
git check-ignore -q .codex/e2e/artifacts/test.webm && ok "CodexのE2E成果物をGit管理外にする" || ng "CodexのE2E成果物がGit管理対象"
if bash .agents/skills/bootstrap/bootstrap.sh codex > init-codex.log 2>&1; then ok "bootstrap codex 実行"; else ng "bootstrap codex 実行"; cat init-codex.log; fi
[ ! -e .agents/skills/bootstrap ] && ok "bootstrap codex は成功後に自己削除" || ng "bootstrap codex が成功後に残った"
[ -f .agents/skills/tdd/SKILL.md ] && ok "bootstrap codex は他skillを保持" || ng "bootstrap codex が他skillを削除"
if [ -f .agents/skills/MODEL_SELECTION.md ] && [ -f .agents/skills/MODEL_SWITCH.md ] && grep -Fq '.agents/skills/MODEL_SELECTION.md' AGENTS.md && grep -Fq '選定値が現在値と異なる場合は' .agents/skills/MODEL_SELECTION.md; then
  ok "モデル選択・切り替え: Codex配置と参照条件"
else
  ng "モデル選択・切り替え: Codex配置または参照条件が不正"
fi
if grep -q '^default_subagent_model = "gpt-5.6-luna"$' .codex/config.toml && grep -q '^default_subagent_reasoning_effort = "max"$' .codex/config.toml; then
  ok "bootstrap codex は子の既定値をLuna/maxへ固定"
else
  ng "bootstrap codex の子モデル既定値が不正"
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
AWS_READONLY_PERMISSION_OUT=$(jq -cn --arg cwd "$PWD" --arg command 'aws sts get-caller-identity --profile daresuma-readonly --region ap-northeast-1 --output json' '{hook_event_name:"PermissionRequest",session_id:"CAWSREAD1",cwd:$cwd,tool_name:"Bash",tool_input:{command:$command,description:"daresuma readonly aws"}}' | bash .codex/hooks/shell/readonly-search.sh)
[ "$(printf '%s' "$AWS_READONLY_PERMISSION_OUT" | jq -r '.hookSpecificOutput.decision.behavior' 2>/dev/null)" = "allow" ] && ok "codex: daresuma-readonlyのAWS commandを承認表示なしで許可" || ng "codex: daresuma-readonlyのAWS command承認省略失敗 out=[$AWS_READONLY_PERMISSION_OUT]"
AWS_OTHER_PROFILE_PERMISSION_OUT=$(jq -cn --arg cwd "$PWD" --arg command 'aws sts get-caller-identity --profile default' '{hook_event_name:"PermissionRequest",session_id:"CAWSREAD2",cwd:$cwd,tool_name:"Bash",tool_input:{command:$command,description:"other aws profile"}}' | bash .codex/hooks/shell/readonly-search.sh)
[ -z "$AWS_OTHER_PROFILE_PERMISSION_OUT" ] && ok "codex: daresuma-readonly以外のAWS承認へ介入しない" || ng "codex: 別AWS profileを誤って自動許可 out=[$AWS_OTHER_PROFILE_PERMISSION_OUT]"
AWS_MIXED_PROFILE_PERMISSION_OUT=$(jq -cn --arg cwd "$PWD" --arg command 'aws sts get-caller-identity --profile daresuma-readonly --profile default' '{hook_event_name:"PermissionRequest",session_id:"CAWSREAD3",cwd:$cwd,tool_name:"Bash",tool_input:{command:$command,description:"mixed aws profiles"}}' | bash .codex/hooks/shell/readonly-search.sh)
[ -z "$AWS_MIXED_PROFILE_PERMISSION_OUT" ] && ok "codex: daresuma-readonlyと別profileの混在を自動許可しない" || ng "codex: 混在AWS profileを誤って自動許可 out=[$AWS_MIXED_PROFILE_PERMISSION_OUT]"
UNSAFE_PERMISSION_OUT=$(jq -cn --arg cwd "$PWD" '{hook_event_name:"PermissionRequest",session_id:"CREAD2",cwd:$cwd,tool_name:"Bash",tool_input:{command:"rg foo src | sort",description:"opaque shell"}}' | bash .codex/hooks/shell/readonly-search.sh)
[ -z "$UNSAFE_PERMISSION_OUT" ] && ok "codex: 複合shellの承認判断へ介入しない" || ng "codex: 複合shellを誤って自動許可 out=[$UNSAFE_PERMISSION_OUT]"
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
if jq -e '
  .mcpServers["chrome-devtools"].type == "stdio" and
  .mcpServers["chrome-devtools"].command == "npx" and
  (.mcpServers["chrome-devtools"].args | index("chrome-devtools-mcp@1.6.0")) and
  (.mcpServers["chrome-devtools"].args | index("--experimentalScreencast=true")) and
  (.mcpServers["chrome-devtools"].args | index("--allowed-url-pattern=*://localhost:*/*")) and
  (.mcpServers["chrome-devtools"].args | index("--allowed-url-pattern=*://127.0.0.1:*/*")) and
  (.mcpServers["chrome-devtools"].args | index("--allowed-url-pattern=*://[\\:\\:1]:*/*"))
' "$CM" >/dev/null 2>&1; then
  ok "chrome-devtools: Claudeで固定版・localhost限定・screencast有効"
else
  ng "chrome-devtools: Claude MCP起動設定が不正"
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
  mcp_server_approves_by_default "$MCP_SERVER" .codex/config.toml || append_group_failure "既定値がapproveではない"
  awk '
    $0 == "[mcp_servers.chrome-devtools.tools.upload_file]" { tool=1; next }
    /^\[/ { tool=0 }
    tool && $0 == "approval_mode = \"prompt\"" { found=1 }
    END { exit !found }
  ' .codex/config.toml || append_group_failure "upload_fileの承認がない"
  CONFIGURED_COUNT=$(grep -c '^\[mcp_servers.chrome-devtools.tools.' .codex/config.toml)
  [ "$CONFIGURED_COUNT" = "1" ] || append_group_failure "不要なtool個別設定が残存"
  grep -Fq -- '--experimentalScreencast=true' .codex/config.toml || append_group_failure "screencastが無効"
  for LOCAL_PATTERN in '--allowed-url-pattern=*://localhost:*/*' '--allowed-url-pattern=*://127.0.0.1:*/*' '--allowed-url-pattern=*://[\\:\\:1]:*/*'; do
    grep -Fq -- "$LOCAL_PATTERN" .codex/config.toml || append_group_failure "localhost制限なし: $LOCAL_PATTERN"
  done
  report_group "$MCP_SERVER: localhost限定・screencast有効・uploadだけ承認" "$GROUP_FAILURES"
done
[ -f .codex/prompt/.prompt.md ] && [ -f .codex/e2e/.e2e.md ] && [ -f .codex/e2e/artifacts/.gitignore ] && ok "codex seed 配置" || ng "codex seed 配置漏れ"
jq -e . .codex/hooks.json >/dev/null 2>&1 && ok "hooks.json 構文" || ng "hooks.json 構文"
jq -e '[.hooks[][] | .hooks[] | has("timeout")] | all' .codex/hooks.json >/dev/null 2>&1 && ok "hook timeout 全件設定" || ng "hook timeout 設定漏れ"
[ "$(jq '[.hooks.PreModelSwitch[] | .hooks[].command | select(contains("pre-model-switch.sh"))] | length' .codex/hooks.json)" = "1" ] && ok "Baton PreModelSwitchをCodex配置へ配線" || ng "Baton PreModelSwitchの配線が不正"
GROUP_FAILURES=
for SCRIPT in protect-config.sh protect-locks.sh protect-review.sh; do
  BINDING_COUNT=$(jq --arg script "$SCRIPT" '[.hooks.PreToolUse[] | .hooks[].command | select(contains($script))] | length' .codex/hooks.json)
  [ "$BINDING_COUNT" = "$EXPECTED_DUAL_HOOK_BINDINGS" ] || append_group_failure "$SCRIPT: $BINDING_COUNT bindings"
done
report_group "保護hookを apply_patch/Bash の両方へ配線" "$GROUP_FAILURES"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("load-required-contract.sh"))] | length' .codex/hooks.json)" = "1" ] && ok "必須契約hookを編集toolへ配線" || ng "必須契約hookの配線漏れ"
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
  for METADATA_COMMAND in "${METADATA_COMMANDS[@]}"; do
    OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- "$METADATA_COMMAND" target 2>/dev/null)
    [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] || append_group_failure "$METADATA_COMMAND: $OUT"
  done
  report_group "rules: 新規作成・metadata変更をallow" "$GROUP_FAILURES"
  GROUP_FAILURES=
  for WRITER_COMMAND in "${CONTENT_WRITER_COMMANDS[@]}"; do
    OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- "$WRITER_COMMAND" target 2>/dev/null)
    [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "forbidden" ] || append_group_failure "$WRITER_COMMAND: $OUT"
  done
  report_group "rules: shellの内容変更をforbidden" "$GROUP_FAILURES"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- cp -n -- source target 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision')" = allow ] && ok "rules: 上書きしないcpをallow" || ng "rules: cp -n判定失敗"
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
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/bootstrap/bootstrap.sh codex 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: bootstrap の固定経路を allow" || ng "rules: bootstrap 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/e2e/apply-e2e-plan.sh "$S/e2e-plan.md" 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: e2e plan の固定経路を allow" || ng "rules: e2e plan 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/tdd/mark-prompt-done.sh user-api 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: mark-prompt-done の固定経路を allow" || ng "rules: mark-prompt-done 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/polish/quality-gate.sh user-api -- src/example.ts 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: quality-gate の固定経路を allow" || ng "rules: quality-gate 判定失敗 out=[$OUT]"
  OUT=$(CODEX_HOME="$S/codex-home" codex execpolicy check --rules .codex/rules/default.rules -- bash .agents/skills/polish/capture-scope.sh user-api -- src/example.ts 2>/dev/null)
  [ "$(echo "$OUT" | jq -r '.decision' 2>/dev/null)" = "allow" ] && ok "rules: polish scope記録の固定経路を allow" || ng "rules: polish scope記録判定失敗 out=[$OUT]"
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
UP=$(jq -n --arg cwd "$PWD" '{hook_event_name:"UserPromptSubmit",session_id:"SESS1",cwd:$cwd,prompt:"$cowlick",model:"m",permission_mode:"default",transcript_path:null,turn_id:"t"}')
echo "$UP" | bash $H/session.sh
[ -f .codex/tmp/session.cowlick.SESS1 ] && ok "session: \$cowlick 起動で marker 記録" || ng "session: marker 記録失敗"
UPE=$(jq -n --arg cwd "$PWD" '{hook_event_name:"UserPromptSubmit",session_id:"TDD_DOC1",cwd:$cwd,prompt:"$tdd --from-doc",model:"m",permission_mode:"default",transcript_path:null,turn_id:"t"}')
echo "$UPE" | bash $H/session.sh
[ ! -f .codex/tmp/session.tdd.TDD_DOC1 ] && ok "session: tdd --from-docは委任用markerを作らない" || ng "session: tdd --from-docの委任用markerが残存"
UP2=$(jq -n --arg cwd "$PWD" '{hook_event_name:"UserPromptSubmit",session_id:"SESS9",cwd:$cwd,prompt:"cowlick について教えて",model:"m",permission_mode:"default",transcript_path:null,turn_id:"t"}')
echo "$UP2" | bash $H/session.sh
[ ! -f .codex/tmp/session.cowlick.SESS9 ] && ok "session: \$ 無しの言及では発火しない" || ng "session: 誤発火"
UPE2=$(jq -n --arg cwd "$PWD" '{hook_event_name:"UserPromptSubmit",session_id:"ERR9",cwd:$cwd,prompt:"$tdd 修正して",model:"m",permission_mode:"default",transcript_path:null,turn_id:"t"}')
echo "$UPE2" | bash $H/session.sh
[ ! -f .codex/tmp/session.tdd.ERR9 ] && ok "session: tddは委任用markerを作らない" || ng "session: tddの委任用markerが残存"
UPM=$(jq -n --arg cwd "$PWD" '{hook_event_name:"UserPromptSubmit",session_id:"MEET1",cwd:$cwd,prompt:"$meeting 新機能を設計して",model:"m",permission_mode:"default",transcript_path:null,turn_id:"t"}')
echo "$UPM" | bash $H/session.sh
COWLICK_PATCH=$(jq -n --arg cwd "$PWD" '{session_id:"DIRECTDESIGN",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: .codex/prompt/branch-sample-prompt.md\n+x\n*** End Patch"}}')
COWLICK_LOAD=$(echo "$COWLICK_PATCH" | bash $H/load-required-contract.sh)
if [ "$(echo "$COWLICK_LOAD" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] && echo "$COWLICK_LOAD" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -Fq '## Changes'; then
  ok "required-reading: Codexのskill起動なしの初回prompt編集で設計形式を注入"
else
  ng "required-reading: Codexのskill起動なしで設計形式を注入できない"
fi
[ -z "$(echo "$COWLICK_PATCH" | bash $H/load-required-contract.sh)" ] && ok "required-reading: Codex設計形式receipt後は棄権" || ng "required-reading: Codex設計形式receiptを再利用できない"
SE=$(jq -n --arg cwd "$PWD" '{hook_event_name:"SessionEnd",session_id:"SESS1",cwd:$cwd}')
echo "$SE" | bash $H/session.sh
[ ! -f .codex/tmp/session.cowlick.SESS1 ] && ok "session: SessionEnd で自セッションの marker を掃除" || ng "session: 掃除漏れ"
SEMEET=$(jq -n --arg cwd "$PWD" '{hook_event_name:"SessionEnd",session_id:"MEET1",cwd:$cwd}')
echo "$SEMEET" | bash $H/session.sh
[ ! -f .codex/tmp/session.meeting.MEET1 ] && ok "session: SessionEnd でmeeting markerを掃除" || ng "session: meeting marker掃除漏れ"
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

if git -C "$REPO" grep -nE '^[[:space:]]*(>[[:space:]]*)*([-*+]|[0-9]+[.)])[[:space:]]+.*。' -- '*.md' > "$S/list-periods.out"; then
  ng "Markdownの箇条書きに句点が残存"
  cat "$S/list-periods.out"
elif [ "$?" -eq 1 ]; then
  ok "Markdownの箇条書きは句点なし"
else
  ng "Markdownの箇条書き検査に失敗"
fi
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
for METADATA_COMMAND in "${METADATA_COMMANDS[@]}"; do
  PERMISSION="Bash($METADATA_COMMAND:*)"
  jq -e --arg permission "$PERMISSION" '(.permissions.allow | index($permission)) and (.permissions.ask | index($permission) | not)' "$SL" >/dev/null 2>&1 || append_group_failure "$PERMISSION"
done
report_group "Claude: 新規作成・metadata変更をallow" "$GROUP_FAILURES"
GROUP_FAILURES=
for WRITER_COMMAND in "${CONTENT_WRITER_COMMANDS[@]}"; do
  PERMISSION="Bash($WRITER_COMMAND:*)"
  jq -e --arg permission "$PERMISSION" '(.permissions.deny | index($permission)) and (.permissions.ask | index($permission) | not)' "$SL" >/dev/null 2>&1 || append_group_failure "$PERMISSION"
done
report_group "Claude: shellの内容変更をdeny" "$GROUP_FAILURES"
jq -e '.permissions.allow | index("Bash(cp -n --:*)")' "$SL" >/dev/null && ok "Claude: 上書きしないcpをallow" || ng "Claude: cp -nが未許可"
jq -e '.permissions.allow | index("Bash(mkdir:*)")' "$SL" >/dev/null 2>&1 && jq -e '.permissions.ask | index("Bash(mkdir:*)") | not' "$SL" >/dev/null 2>&1 && ok "Claude: sandbox内mkdirをallow" || ng "Claude: mkdirが承認対象"
jq -e '
  (.permissions.allow | index("mcp__chrome-devtools__screencast_start")) and
  (.permissions.allow | index("mcp__chrome-devtools__screencast_stop")) and
  (.enabledMcpjsonServers | index("chrome-devtools"))
' "$SL" >/dev/null 2>&1 && ok "Claude: chrome-devtoolsのscreencastを有効化" || ng "Claude: chrome-devtoolsのscreencast設定が不足"
jq -e '.sandbox.excludedCommands | (index("./base/scripts/run-unit.sh") != null and index("./base/scripts/run-unit.sh *") != null)' "$SJ" >/dev/null 2>&1 && jq -e '.permissions.allow | (index("Bash(./base/scripts/run-unit.sh)") != null and index("Bash(./base/scripts/run-unit.sh:*)") != null)' "$SL" >/dev/null 2>&1 && ok "Claude: 承認済みunit test runnerをlocalでallow" || ng "Claude: unit test runnerの自動実行設定が不足"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("protect-locks.sh"))] | length' "$SJ")" = "$EXPECTED_DUAL_HOOK_BINDINGS" ] && ok "Claude lockfile保護hookをBash/Editへ配線" || ng "Claude lockfile保護hookの配線漏れ"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("protect-implementation-scope.sh"))] | length' "$SJ")" = "0" ] && ok "Claudeはexact実装scope hookを配線しない" || ng "Claudeにexact実装scope hookが残存"
[ "$(jq '[.hooks.PreToolUse[] | .hooks[].command | select(contains("load-required-contract.sh"))] | length' "$SJ")" = "1" ] && ! grep -q '^hooks:' "$REPO/skills/cowlick/SKILL.md" && ! grep -Fq 'worker/DELEGATION.md' "$REPO/hooks/shell/load-required-contract.sh" && ok "Claude必須契約hookを編集時の読み込みへ配線" || ng "Claude必須契約hookの配線漏れ"
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
for SC in bootstrap/bootstrap.sh tdd/mark-prompt-done.sh polish/quality-gate.sh polish/capture-scope.sh e2e/apply-e2e-plan.sh; do
  CMD="bash .claude/skills/$SC"
  jq -e --arg c "$CMD"          '.sandbox.excludedCommands | index($c)' "$SJ" >/dev/null 2>&1 || { ng "excludedCommands に引数なし形が無い: $SC"; MISS=1; }
  jq -e --arg c "$CMD *"        '.sandbox.excludedCommands | index($c)' "$SJ" >/dev/null 2>&1 || { ng "excludedCommands に引数あり形が無い: $SC"; MISS=1; }
  jq -e --arg c "Bash($CMD)"    '.permissions.allow | index($c)' "$SL" >/dev/null 2>&1 || { ng "allow に引数なし形が無い: $SC"; MISS=1; }
  jq -e --arg c "Bash($CMD:*)"  '.permissions.allow | index($c)' "$SL" >/dev/null 2>&1 || { ng "allow に引数あり形が無い: $SC"; MISS=1; }
done
[ "$MISS" = "0" ] && ok "固定スクリプトは引数あり・なし両形で登録済み"

if bash "$SUITE/verify-skill-source.sh" > "$S/skill-source.out" 2>&1; then
  ok "skillの直接読み取り・一括検索・traceを拒否し通常実行を維持"
else
  ng "skill source guardに失敗"
  cat "$S/skill-source.out"
fi

if bash "$SUITE/verify-regressions.sh" > "$S/regressions.out" 2>&1; then
  ok "配布参照・hook配線・親symlink・並行変更・子の起動と待機の動作回帰"
else
  ng "全体走査で追加した動作回帰に失敗"
  cat "$S/regressions.out"
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
