#!/bin/bash
# Baton PreModelSwitch: 有効な切替要求を一度止め、切替手順を元のモデルへ返す。
exec 1>/dev/null

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || fail "PreModelSwitch: jqが見つかりません。"
MAX_CONTEXT_BYTES=49152
INPUT=$(cat)
INPUT=$(printf '%s' "$INPUT" | jq -cse '
  if length == 1 then .[0] else error("one JSON value required") end |
  select(type == "object" and .event == "PreModelSwitch" and
  (.threadId | type == "string" and test("\\S")) and
  (.turnId | type == "string" and test("\\S")) and
  (.cwd | type == "string" and test("\\S")) and
  (.from | type == "object") and (.from.model | type == "string" and test("\\S")) and
  (.from.effort | type == "string" and test("\\S")) and
  (.to | type == "object") and (.to.model | type == "string" and test("\\S")) and
  (.to.config | type == "object") and
  (.to.config.effort | type == "string" and test("\\S")))
' 2>/dev/null) || fail "PreModelSwitch: 入力形式が不正です。"

# model・effortが同じで追加設定のない要求には文書を注入しない。
if printf '%s' "$INPUT" | jq -e '
  .from.model == .to.model and .from.effort == .to.config.effort and
  (.to.config | keys == ["effort"])
' >/dev/null; then
  exit 0
fi

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd')
ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) ||
  fail "PreModelSwitch: repository rootを確認できません。"
DOCUMENT="$ROOT/.agents/skills/MODEL_SWITCH.md"
[ -f "$DOCUMENT" ] && [ -r "$DOCUMENT" ] ||
  fail "PreModelSwitch: MODEL_SWITCH.mdが見つかりません。"
CONTENT=$(cat "$DOCUMENT") || fail "PreModelSwitch: MODEL_SWITCH.mdを読み込めません。"
DOCUMENT_BYTES=$(printf '%s' "$CONTENT" | wc -c | tr -d ' ')
[ "$DOCUMENT_BYTES" -le "$MAX_CONTEXT_BYTES" ] ||
  fail "PreModelSwitch: MODEL_SWITCH.mdが注入上限を超えています。"

THREAD_HASH=$(printf '%s' "$INPUT" | jq -r '.threadId' | shasum -a 256 | awk '{print $1}')
DOCUMENT_HASH=$(printf '%s' "$CONTENT" | shasum -a 256 | awk '{print $1}')
[ "${#THREAD_HASH}" = 64 ] && [ "${#DOCUMENT_HASH}" = 64 ] ||
  fail "PreModelSwitch: 注入記録のhashを計算できません。"

STATE_DIR="$ROOT/.codex/tmp"
[ ! -L "$STATE_DIR" ] || fail "PreModelSwitch: state directoryがsymlinkです。"
mkdir -p "$STATE_DIR" || fail "PreModelSwitch: state directoryを作成できません。"
RECEIPT="$STATE_DIR/pre-model-switch.$THREAD_HASH.$DOCUMENT_HASH"
[ ! -L "$RECEIPT" ] || fail "PreModelSwitch: receiptがsymlinkです。"
[ ! -f "$RECEIPT" ] || exit 0

printf 'PRE_MODEL_SWITCH_CONTEXT: 切替手順を注入しました。モデル・設定は変更していません。同じswitch_model要求を一度だけ再試行してください。\n\n' >&2
printf '%s\n' "$CONTENT" >&2 || fail "PreModelSwitch: MODEL_SWITCH.mdを返せません。"
TEMP=$(mktemp "$STATE_DIR/pre-model-switch-write.XXXXXX") ||
  fail "PreModelSwitch: receiptを作成できません。"
printf '%s\n' "$DOCUMENT_HASH" > "$TEMP" && mv "$TEMP" "$RECEIPT" ||
  fail "PreModelSwitch: receiptを保存できません。"
exit 2
