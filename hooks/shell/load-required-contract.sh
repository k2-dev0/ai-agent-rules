#!/bin/bash
# PreToolUse hook: 判断前に必須の要点を、最初の保護操作を止めて注入する。
# task-idやmodeにかかわらず、同一session・同一内容ではreceiptを検証して棄権し、後続操作を通す。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"

MODE="${1:-auto}"
TOOL=$(hook_tool_name)
ROOT=$(hook_cwd)
[ -n "$ROOT" ] || ROOT=$PWD
SESSION_ID=$(hook_session_id)

case "$HOOK_AGENT" in
  claude) STATE_DIR="$ROOT/.claude/tmp" ;;
  codex) STATE_DIR="$ROOT/.codex/tmp" ;;
esac

find_contract() {
  RELATIVE_PATH=$1
  for SKILL_ROOT in "$ROOT/.agents/skills" "$ROOT/.claude/skills" "$ROOT/skills"; do
    CANDIDATE="$SKILL_ROOT/$RELATIVE_PATH"
    if [ -f "$CANDIDATE" ]; then
      echo "$CANDIDATE"
      return 0
    fi
  done
  return 1
}

load_contract_once() {
  KEY=$1
  RELATIVE_PATH=$2
  CONTRACT=$(find_contract "$RELATIVE_PATH") || \
    hook_deny "必須契約 $RELATIVE_PATH が見つかりません。配置を修復してから再実行してください。"

  echo "$SESSION_ID" | grep -Eq '^[A-Za-z0-9._-]+$' || \
    hook_deny "session_idを確定できないため、必須契約 $RELATIVE_PATH の読込receiptを作れません。"

  STAMP=$(cksum "$CONTRACT" | awk '{print $1 ":" $2}')
  RECEIPT="$STATE_DIR/required-reading.$KEY.$SESSION_ID"
  if [ -f "$RECEIPT" ] && [ "$(cat "$RECEIPT")" = "$STAMP" ]; then
    return 0
  fi

  case "$RELATIVE_PATH" in
    worker/DELEGATION.md)
      REASON=$(cat <<'EOF'
worker委任の要点:
- workerは根拠収集と許可path内の初回実装候補だけを担当する。要件・設計・採否・修正・test・Gitは上位モデルの責務。
- 委任は`delegate.sh`だけを使い、同じ仕事を並行委任しない。surveyは1 task = C1一件の検証済みJSONにする。
- implement / errandには成功済みevidenceを渡し、許可pathを越えさせない。結果は`worker-result`の`next_action`に従う。
- 調査済みの根拠を読み直さず、直接調査は契約の例外時だけ。smokeはユーザーの明示許可がある時だけ。

CLIの完全な引数、証拠形式、timeout、再試行条件は`worker/DELEGATION.md`が正本です。必要な節だけ参照してください。このtoolはまだ実行していません。内容を反映して同じ工程を再試行してください。
EOF
)
      ;;
    *)
      CONTENT=$(cat "$CONTRACT") || \
        hook_deny "必須契約 $RELATIVE_PATH を読み込めません。"
      REASON=$(printf '必須契約 %s を以下へ全文注入しました。このtoolはまだ実行していません。内容を反映して同じ工程を再試行してください。\n\n%s' "$RELATIVE_PATH" "$CONTENT")
      ;;
  esac
  DECISION=$(hook_deny_json "$REASON") || \
    hook_deny "必須契約 $RELATIVE_PATH をhook応答へ変換できません。"

  mkdir -p "$STATE_DIR" || \
    hook_deny "必須契約 $RELATIVE_PATH の読込receiptを保存できません。"
  printf '%s\n' "$STAMP" > "$RECEIPT" || \
    hook_deny "必須契約 $RELATIVE_PATH の読込receiptを保存できません。"
  printf '%s\n' "$DECISION"
  exit 0
}

# workerの引数を確定する前に共通委任契約を必ずcontextへ入れる。
if [ "$TOOL" = "Bash" ]; then
  case "$(hook_command)" in
    bash\ *skills/worker/delegate.sh*)
      load_contract_once "worker-delegation" "worker/DELEGATION.md"
      exit 0
      ;;
  esac
fi

# Claudeはcowlickのfrontmatterからmodeを渡す。Codexはmeeting/cowlickのsession markerで
# 適用範囲を限定し、最初のdraft編集前に設計形式を注入する。
REQUIRE_COWLICK_FORMAT=false
if [ "$MODE" = "cowlick-design" ]; then
  REQUIRE_COWLICK_FORMAT=true
elif [ "$HOOK_AGENT" = "codex" ] && { hook_skill_session_active "meeting" || hook_skill_session_active "cowlick"; }; then
  REQUIRE_COWLICK_FORMAT=true
fi

if [ "$REQUIRE_COWLICK_FORMAT" = true ]; then
  case "$TOOL" in
    Edit|Write|MultiEdit|apply_patch)
      load_contract_once "cowlick-design-format" "cowlick/DESIGN_FORMAT.md"
      ;;
  esac
fi

exit 0
