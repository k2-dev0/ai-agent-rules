#!/bin/bash
# PreToolUse(Bash|Edit|Write|NotebookEdit|apply_patch) hook: 配置場所に依存せず、
# レビュー対象ファイルは読み取りを許可し、Codex ではユーザー承認済みの apply_patch だけ通す。
REVIEW_FILE_PATH_RE='(^|/)(package\.json|Dockerfile[^/]*|docker-compose[^/]*|[^/]+\.tf)$|(^|/)(\.github/workflows|migrations)(/|$)'
REVIEW_FILE_COMMAND_RE="package\\.json|Dockerfile|docker-compose|\\.tf([[:space:]\\\"']|$)|\\.github/workflows|migrations/"
REVIEW_APPROVAL_USAGE="bash .codex/hooks/shell/protect-review.sh approve <対象パス>"

review_repo_root() { git rev-parse --show-toplevel 2>/dev/null; }

review_relative_path() {
  local ROOT=$1
  local INPUT_PATH=$2
  local RELATIVE_PATH
  case "$INPUT_PATH" in
    "$ROOT"/*) RELATIVE_PATH=${INPUT_PATH#"$ROOT"/} ;;
    /*) return 1 ;;
    ./*) RELATIVE_PATH=${INPUT_PATH#./} ;;
    *) RELATIVE_PATH=$INPUT_PATH ;;
  esac
  case "$RELATIVE_PATH" in
    ""|/*|..|../*|*/..|*/../*|.|./*|*/.|*/./*|*//*) return 1 ;;
  esac
  printf '%s\n' "$RELATIVE_PATH"
}

review_approval_marker() {
  local ROOT=$1
  local RELATIVE_PATH=$2
  local PATH_CHECKSUM
  PATH_CHECKSUM=$(printf '%s' "$RELATIVE_PATH" | cksum | awk '{ print $1 }')
  printf '%s/.codex/tmp/review-file-approval.%s\n' "$ROOT" "$PATH_CHECKSUM"
}

review_approval_consume() {
  local ROOT=$1
  local RELATIVE_PATH=$2
  local MARKER
  MARKER=$(review_approval_marker "$ROOT" "$RELATIVE_PATH")
  [ -f "$MARKER" ] || return 1
  [ "$(sed -n '1p' "$MARKER")" = "$RELATIVE_PATH" ] || return 1
  rm -f "$MARKER"
}

if [ "${1:-}" = "approve" ]; then
  [ "$#" -eq 2 ] || { echo "usage: $REVIEW_APPROVAL_USAGE" >&2; exit 1; }
  ROOT=$(review_repo_root) || { echo "Git リポジトリ内で実行してください。" >&2; exit 1; }
  RELATIVE_PATH=$(review_relative_path "$ROOT" "$2") || { echo "リポジトリ内の相対パスを指定してください。" >&2; exit 1; }
  echo "$RELATIVE_PATH" | grep -qE "$REVIEW_FILE_PATH_RE" || { echo "承認対象外のパスです: $RELATIVE_PATH" >&2; exit 1; }
  MARKER=$(review_approval_marker "$ROOT" "$RELATIVE_PATH")
  mkdir -p "$(dirname "$MARKER")" || exit 1
  umask 077
  printf '%s\n' "$RELATIVE_PATH" > "$MARKER" || exit 1
  echo "approved once: $RELATIVE_PATH"
  exit 0
fi

exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
TOOL=$(hook_tool_name)

REVIEW_FILE_MSG="package manifest・CI・migration・container・Terraform 設定の変更にはユーザー承認が必要です。Codex では '$REVIEW_APPROVAL_USAGE' の実行承認後、apply_patch で変更してください。"

case "$TOOL" in
  Edit|Write|NotebookEdit|apply_patch)
    ROOT=$(review_repo_root) || hook_deny "$REVIEW_FILE_MSG"
    while IFS= read -r FILE; do
      [ -z "$FILE" ] && continue
      RELATIVE_PATH=$(review_relative_path "$ROOT" "$FILE") || hook_deny "$REVIEW_FILE_MSG"
      if echo "$RELATIVE_PATH" | grep -qE "$REVIEW_FILE_PATH_RE"; then
        [ "$HOOK_AGENT" = "codex" ] && review_approval_consume "$ROOT" "$RELATIVE_PATH" && continue
        hook_ask "$REVIEW_FILE_MSG"
      fi
    done < <(hook_file_paths)
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

CMD=$(hook_command)
[ -z "$CMD" ] && exit 0
echo "$CMD" | grep -qE "$REVIEW_FILE_COMMAND_RE" || {
  # ファイル名を省略して対象を書き換える代表的なコマンドも止める。
  echo "$CMD" | grep -qE '(^|[;&|[:space:]])(npm|pnpm)[[:space:]]+(install|uninstall|add|remove)([[:space:]]|$)|(^|[;&|[:space:]])yarn[[:space:]]+(add|remove|upgrade)([[:space:]]|$)|(^|[;&|[:space:]])(terraform|tofu)[[:space:]]+fmt([[:space:]]|$)' && \
    hook_deny "$REVIEW_FILE_MSG"
  exit 0
}

# 読み取りコマンドは許可し、対象パスを書き換える形だけを止める。
echo "$CMD" | grep -qE '(^|[;&|[:space:]])(rm|rmdir|unlink|shred|srm|mv|dd|truncate|tee|ln|touch|chmod|chown|chgrp)([[:space:]]|$)' && hook_deny "$REVIEW_FILE_MSG"
echo "$CMD" | grep -qE '(^|[[:space:]])--?delete(-[a-z-]+)?([[:space:]]|$)' && hook_deny "$REVIEW_FILE_MSG"
echo "$CMD" | grep -qE '>>?' && hook_deny "$REVIEW_FILE_MSG"
echo "$CMD" | grep -qE '(^|[;&|[:space:]])(cp|rsync|install)([[:space:]]|$)' && hook_deny "$REVIEW_FILE_MSG"
echo "$CMD" | grep -qE '(^|[[:space:]])-{1,2}(o|output(-document)?)([[:space:]]+|=)' && hook_deny "$REVIEW_FILE_MSG"
echo "$CMD" | grep -qE '(^|[;&|[:space:]])sed[[:space:]][^;&|]*-i' && hook_deny "$REVIEW_FILE_MSG"
echo "$CMD" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+(clean|checkout|restore)([[:space:]]|$)' && hook_deny "$REVIEW_FILE_MSG"

exit 0
