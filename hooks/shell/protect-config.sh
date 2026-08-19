#!/bin/bash
# PreToolUse(Bash|Edit|Write|NotebookEdit|apply_patch) hook: エージェント設定と skill を
# 実行中のエージェント自身による改変から守る。
# `.[agent_name]/prompt/` は設計書の正本であり、ユーザーとエージェントが直接更新する。
# それ以外の設定・skillは、sandbox 無効化時にも同じ境界を維持するため共通で検査する。
# bootstrap 等の設定用スクリプト実行は、コマンド文字列から内部の書き込み先を特定できないため
# 本 hook の対象外。設定変更はレビュー済みスクリプトを sandbox 外で明示実行する。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
TOOL=$(hook_tool_name)

CONFIG_MSG=".claude / .codex / .agents 配下の設定・skill をエージェント自身が変更することは禁止です。prompt/ の設計書だけは直接更新できます。"
CONFIG_PATH_RE='(^|/)(\.claude|\.codex|\.agents)(/|$)'
PROMPT_PATH_RE='(^|/)(\.claude|\.codex)/prompt(/|$)'

case "$TOOL" in
  Edit|Write|NotebookEdit|apply_patch)
    while IFS= read -r FILE; do
      [ -z "$FILE" ] && continue
      echo "$FILE" | grep -qE "$PROMPT_PATH_RE" && continue
      echo "$FILE" | grep -qE "$CONFIG_PATH_RE" && hook_deny "$CONFIG_MSG"
    done < <(hook_file_paths)
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

CMD=$(hook_command)
[ -z "$CMD" ] && exit 0

# 読み取りや設定内スクリプトの実行は許可し、設定パスへの書き込み形だけを止める。
CONTROL_RE='(\.claude|\.codex|\.agents)'
echo "$CMD" | grep -qE "$CONTROL_RE" || exit 0

# 削除・移動・生成・権限変更。
echo "$CMD" | grep -qE '(^|[;&|[:space:]])(rm|rmdir|unlink|shred|srm|mv|dd|truncate|tee|ln|mkdir|touch|chmod|chown|chgrp)([[:space:]]|$)' && hook_deny "$CONFIG_MSG"
# find / rsync 等の削除フラグ。
echo "$CMD" | grep -qE '(^|[[:space:]])--?delete(-[a-z-]+)?([[:space:]]|$)' && hook_deny "$CONFIG_MSG"
# リダイレクトによる生成・切り詰め。
echo "$CMD" | grep -qE ">>?[[:space:]]*[^[:space:]]*$CONTROL_RE/" && hook_deny "$CONFIG_MSG"
# コピー・インストール先が設定ディレクトリ配下。
echo "$CMD" | grep -qE "(^|[;&|[:space:]])(cp|rsync|install)[[:space:]][^;&|]*[[:space:]][^[:space:]]*$CONTROL_RE(/[^[:space:]]*)?[[:space:]]*($|[;&|])" && hook_deny "$CONFIG_MSG"
# ダウンロード出力先が設定ディレクトリ配下。
echo "$CMD" | grep -qE "(^|[[:space:]])-{1,2}(o|output(-document)?)([[:space:]]+|=)[^[:space:]]*$CONTROL_RE/" && hook_deny "$CONFIG_MSG"
# in-place 編集と Git 経由の復元・削除。
echo "$CMD" | grep -qE '(^|[;&|[:space:]])sed[[:space:]][^;&|]*-i' && hook_deny "$CONFIG_MSG"
echo "$CMD" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+(clean|checkout|restore)([[:space:]]|$)' && hook_deny "$CONFIG_MSG"

exit 0
