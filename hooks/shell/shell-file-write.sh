#!/bin/bash
# PreToolUse(Bash): metadata変更と上書きしない作成を通し、shellによる内容変更を拒否する。
# 実行前の存在確認だけでは確認後のファイル作成との競合を防げないため、コピー・移動は
# command自身のno-clobberを必須にする。任意script内部の副作用はこのhookでは解析しない。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
[ "$(hook_tool_name)" = "Bash" ] || exit 0
CMD=$(hook_command)
[ -n "$CMD" ] || exit 0
MESSAGE="shellによる既存ファイルの内容変更は禁止です。Edit / apply_patchを使ってください。新規作成はWrite・touch・cp -n -- SOURCE DEST、metadata変更はchmod等で行えます。"

# /dev/nullはファイルの内容変更ではない。末尾の単一redirectだけを検査から外す。
case "$CMD" in
  *' 2>/dev/null') CMD=${CMD%' 2>/dev/null'} ;;
  *' 2> /dev/null') CMD=${CMD%' 2> /dev/null'} ;;
  *' 1>/dev/null') CMD=${CMD%' 1>/dev/null'} ;;
  *' 1> /dev/null') CMD=${CMD%' 1> /dev/null'} ;;
  *' >/dev/null') CMD=${CMD%' >/dev/null'} ;;
  *' > /dev/null') CMD=${CMD%' > /dev/null'} ;;
esac

# evalせず、単一commandのliteral引数だけを読む。引用符内の「>」は文字列として保持する。
# 展開やshell構文を実行してから判定すると、判定自体で内容を変更できてしまう。
TOKENS=$(printf '%s\n' "$CMD" | awk '
  NR > 1 { invalid = 1; exit }
  {
    state = "plain"; word = ""; started = 0
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (state == "single") {
        if (c == "\047") state = "plain"; else word = word c
        continue
      }
      if (state == "double") {
        if (c == "\042") { state = "plain"; continue }
        if (c == "$" || c == "`") { invalid = 1; exit }
        if (c == "\\") {
          next_char = substr($0, ++i, 1)
          if (next_char !~ /[\042$`\\]/) word = word "\\"
          c = next_char
        }
        word = word c; continue
      }
      if (c ~ /[ \t]/) {
        if (started) { print word; word = ""; started = 0 }
        continue
      }
      started = 1
      if (c == "\047") { state = "single"; continue }
      if (c == "\042") { state = "double"; continue }
      if (c == "\\") {
        if (++i > length($0)) { invalid = 1; exit }
        word = word substr($0, i, 1); continue
      }
      if (c ~ /[;&|()<>$`#\r]/) { invalid = 1; exit }
      word = word c
    }
    if (state != "plain") { invalid = 1; exit }
    if (started) print word
  }
  END { if (invalid) exit 1 }
') || hook_deny "$MESSAGE shellの展開・複合構文も使わず、単一commandへ分割してください。"

ARGS=()
while IFS= read -r ARG; do ARGS+=("$ARG"); done <<< "$TOKENS"
set -- "${ARGS[@]}"
# wrapperとliteralな環境変数指定を重ねても、実際に起動するcommandを検査する。
while [ "$#" -gt 0 ]; do
  case "${1##*/}" in
    command|builtin|exec|env)
      shift
      [ "${1:-}" = -- ] && shift
      case "${1:-}" in -*) hook_deny "$MESSAGE wrapperのoptionを使う処理はscriptへ記載してください。" ;; esac
      ;;
    *)
      if [[ "$1" =~ ^[a-zA-Z_][a-zA-Z_0-9]*= ]]; then shift; else break; fi
      ;;
  esac
done
[ "$#" -gt 0 ] || exit 0
BIN=${1##*/}
shift
case "$BIN" in
  cp|gcp|mv|gmv)
    # --より後はoptionへ戻れない。-nを-f/-iで打ち消す指定も受け付けない。
    [ "$#" = 4 ] && [ "$1" = -n ] && [ "$2" = -- ] || hook_deny "$MESSAGE コピー・移動は $BIN -n -- SOURCE DEST を使ってください。"
    ;;
  ln|gln)
    [ "${1:-}" = -s ] && shift
    [ "$#" = 3 ] && [ "$1" = -- ] || hook_deny "$MESSAGE リンク作成は ln [-s] -- SOURCE DEST を使ってください（-fは禁止）。"
    ;;
  install|ginstall)
    [ "${1:-}" = -d ] || hook_deny "$MESSAGE ディレクトリ作成はmkdirを使えます。"
    ;;
  sed|gsed)
    # 読み取りで使う行抽出だけを通す。任意のsedプログラムにはw/e等の副作用がある。
    [ "${1:-}" = -n ] && shift
    [ "$#" = 2 ] || hook_deny "$MESSAGE sedの追加scriptやoptionは使えません。"
    [[ "$2" != -* ]] || hook_deny "$MESSAGE"
    [[ "${1:-}" =~ ^([0-9]+|\$)?(,([0-9]+|\$))?p$ ]] || hook_deny "$MESSAGE sedは行抽出（sed -n '1,20p' FILE）だけを使えます。"
    ;;
  awk|gawk|mawk)
    for ARG in "$@"; do
      case "$ARG" in *'>'*|*'|'*|*system*|-f*|--file*) hook_deny "$MESSAGE awkの出力先指定・外部command・外部programは使えません。" ;; esac
    done
    ;;
  bash|zsh|sh)
    [ "$#" -gt 0 ] || hook_deny "$MESSAGE 対話shellは使えません。"
    for ARG in "$@"; do
      case "$ARG" in -c|-[!-]*c*) hook_deny "$MESSAGE inline shellは使えません。" ;; esac
    done
    ;;
  dd|gdd|truncate|gtruncate|tee|gtee|patch|gpatch|rsync|ed|ex|eval) hook_deny "$MESSAGE" ;;
esac
exit 0
