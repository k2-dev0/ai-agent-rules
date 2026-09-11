#!/bin/bash
# skill実行ファイルの直接表示・検索・traceを拒否する。
# 別スクリプトの内部処理は解析しない。ファイル名一覧・文書・通常実行には許可を追加しない。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
case "$(hook_event_name)" in ""|PreToolUse) ;; *) exit 0 ;; esac
TOOL=$(hook_tool_name)
READ_MSG="skillのスクリプト内容の読み取り・検索・トレース実行は禁止です。内容を読まず、SKILL.md記載のコマンドを実行してください。実行できない、または実行に問題がある場合は、読み取りや別経路で回避せず報告して停止してください。"
CONTEXT_MSG="操作時にhookが注入する文書は先読みできません。対象操作を実行し、注入された内容を使って再試行してください。"
READ_CWD=$(echo "$HOOK_INPUT" | jq -r '.tool_input.workdir // .cwd // "."')

# 内容は読まず、相対path・親directory・symlinkだけを解決する。
source_path() {
  local path=$1 parent target count=0
  case "$path" in file://*) path=${path#file://} ;; esac
  case "$path" in "~/"*) path="$HOME/${path:2}" ;; esac
  case "$path" in /*) ;; *) path="$READ_CWD/$path" ;; esac
  while [ "$count" -lt 16 ]; do
    parent=$(cd -P -- "$(dirname -- "$path")" 2>/dev/null && pwd) || break
    path="$parent/$(basename -- "$path")"
    [ -L "$path" ] || break
    target=$(readlink "$path") || break
    case "$target" in /*) path=$target ;; *) path="$parent/$target" ;; esac
    count=$((count + 1))
  done
  printf '%s\n' "$path"
}

is_injected_context() {
  local raw=$1 path
  case "$raw" in *:*/skills/*) raw=${raw#*:} ;; esac
  path=$(source_path "$raw")
  [ -f "$path" ] || return 1
  case "$path" in
    */skills/SUBAGENT_RULES.md|*/skills/INDEPENDENT_REVIEW.md|*/skills/DIFFICULTY_CONTRACT.md|*/skills/CODE_REVIEW_CONTRACT.md|*/skills/ponytail/REVIEW_CONTRACT.md|*/skills/unwind/NESTING_CONTRACT.md) return 0 ;;
  esac
  return 1
}

is_skill_source() {
  local path logical
  path=$(source_path "$1")
  case "$1" in /*) logical=$1 ;; *) logical="$READ_CWD/$1" ;; esac
  case "$path" in */skills/*) ;; *)
    case "$logical" in */../*) return 1 ;; */skills/*) ;; *) return 1 ;; esac
  esac
  case "$path" in
    *.md|*.txt|*.json|*.yaml|*.yml|*.toml) return 1 ;;
    *.sh|*.bash|*.zsh|*.fish|*.py|*.js|*.mjs|*.cjs|*.ts|*.mts|*.cts|*.rb|*.pl|*.php|*.ps1) return 0 ;;
  esac
  [ -f "$path" ] && [ -x "$path" ]
}

is_skill_scope() {
  local path logical
  path=$(source_path "$1")
  case "$1" in /*) logical=$1 ;; *) logical="$READ_CWD/$1" ;; esac
  case "$logical" in
    */../*) ;;
    */skills|*/skills/|*/skills/*) [ -d "$path" ] && return 0 ;;
  esac
  case "$path" in */skills|*/skills/|*/skills/*)
    [ -d "$path" ] && return 0
    # ファイルを指定しないglobでスクリプトをまとめて読む操作も対象。
    case "$path" in *.md|*.txt) return 1 ;; *\**|*\?*) return 0 ;; esac
  esac
  return 1
}

case "$TOOL" in
  Glob|*list_directory|*list_dir|*find_file) exit 0 ;;
  Read|*read_file|*read_text_file|*read_multiple_files|*get_file_contents|*read_resource|Grep|*search_for_pattern|*find_symbol|*get_symbols_overview)
    FOUND=false
    DOC_GLOB=$(echo "$HOOK_INPUT" | jq -r '.tool_input.glob // .tool_input.paths_include_glob // empty')
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      FOUND=true
      is_injected_context "$path" && hook_deny "$CONTEXT_MSG"
      is_skill_source "$path" && hook_deny "$READ_MSG"
      case "$DOC_GLOB" in *.md|*.txt) continue ;; esac
      is_skill_scope "$path" && hook_deny "$READ_MSG"
    done < <(echo "$HOOK_INPUT" | jq -r '.tool_input | [.file_path, .path, .relative_path, .uri, .root, .paths[]?] | .[] | select(type == "string")')
    if [ "$FOUND" = false ] && is_skill_scope "$READ_CWD"; then hook_deny "$READ_MSG"; fi
    exit 0
    ;;
  Bash|exec_command|*exec_command) ;;
  *) exit 0 ;;
esac

CMD=$(echo "$HOOK_INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty')
[ -n "$CMD" ] || exit 0
# quoteを解くだけで、変数展開・command substitution・evalは行わない。
TOKENS=$(printf '%s\n' "$CMD" | xargs -n 1 printf '%s\n') || exit 0
ARGS=()
while IFS= read -r token; do ARGS+=("$token"); done <<< "$TOKENS"
for token in "${ARGS[@]}"; do
  is_injected_context "$token" && hook_deny "$CONTEXT_MSG"
done
INDEX=0
while [ "${ARGS[$INDEX]:-}" = command ] || [ "${ARGS[$INDEX]:-}" = builtin ]; do INDEX=$((INDEX + 1)); done
TRACE_ENV=false
if [ "${ARGS[$INDEX]:-}" = env ]; then INDEX=$((INDEX + 1)); fi
while [[ "${ARGS[$INDEX]:-}" == *=* ]]; do
  case "${ARGS[$INDEX]}" in SHELLOPTS=*xtrace*|SHELLOPTS=*verbose*) TRACE_ENV=true ;; esac
  INDEX=$((INDEX + 1))
done
BIN=${ARGS[$INDEX]##*/}
if [ "$TRACE_ENV" = true ] && is_skill_source "${ARGS[$INDEX]}"; then hook_deny "$READ_MSG"; fi

# ファイル名の列挙はソースを返さない。複合commandは既存readonly-searchが拒否する。
case "$BIN" in
  ls) exit 0 ;;
  find)
    for token in "${ARGS[@]}"; do
      case "$token" in -exec|-execdir|-ok|-okdir)
        for path in "${ARGS[@]}"; do
          if is_skill_source "$path" || is_skill_scope "$path"; then hook_deny "$READ_MSG"; fi
        done
        ;;
      esac
    done
    exit 0
    ;;
  rg)
    for token in "${ARGS[@]}"; do
      case "$token" in --files) exit 0 ;; esac
    done
    ;;
esac

# このhookが扱うのは直接表示・検索・interpreter起動だけ。コピーや別scriptの中身は追跡しない。
case "$BIN" in
  cat|head|tail|sed|awk|grep|rg|nl|less|more|bat|strings|xxd|od|bash|sh|zsh|fish|python|python3|node|ruby|perl|php|pwsh) ;;
  git)
    case "${ARGS[$((INDEX+1))]:-}" in show|diff|log|grep) ;; *) exit 0 ;; esac
    ;;
  *) exit 0 ;;
esac

SOURCE_INDEX=-1
for ((i=INDEX; i<${#ARGS[@]}; i++)); do
  if is_skill_source "${ARGS[$i]}"; then SOURCE_INDEX=$i; break; fi
done
if [ "$SOURCE_INDEX" -ge 0 ]; then
  [ "$TRACE_ENV" = true ] && hook_deny "$READ_MSG"
  # 直接実行、またはinterpreterのscript引数だけを認める。既存の実行許可は別hookに委ねる。
  [ "$SOURCE_INDEX" -eq "$INDEX" ] && exit 0
  case "$BIN" in
    bash|sh|zsh|fish|python|python3|node|ruby|perl|php|pwsh)
      for ((i=INDEX+1; i<SOURCE_INDEX; i++)); do
        case "$BIN:${ARGS[$i]}" in
          bash:-*x*|bash:-*v*|sh:-*x*|sh:-*v*|zsh:-*x*|zsh:-*v*|bash:xtrace|bash:verbose|sh:xtrace|sh:verbose|zsh:xtrace|zsh:verbose) hook_deny "$READ_MSG" ;;
        esac
      done
      # 別のscriptに対象pathを引数として渡す間接読み取りは追跡対象外。
      for ((i=INDEX+1; i<SOURCE_INDEX; i++)); do
        case "${ARGS[$i]}" in -*) ;; *) exit 0 ;; esac
      done
      for ((i=INDEX+1; i<SOURCE_INDEX; i++)); do
        case "$BIN:${ARGS[$i]}" in
          *:--|bash:-e|bash:-u|bash:-eu|bash:--noprofile|bash:--norc|sh:-e|sh:-u|sh:-eu|python:-u|python:-B|python3:-u|python3:-B|node:--no-warnings) ;;
          *) hook_deny "$READ_MSG" ;;
        esac
      done
      exit 0
      ;;
  esac
  hook_deny "$READ_MSG"
fi

# 明示的なskill directoryへの内容検索、そこでの省略path検索を拒否する。
case "$BIN" in
  cat|head|tail|sed|awk|grep|rg|nl|less|more|bat|strings|xxd|od)
    EXPLICIT_FILE=false
    PATTERN_SEEN=true
    case "$BIN" in rg|grep) PATTERN_SEEN=false ;; esac
    OPTION_VALUE=
    for token in "${ARGS[@]:INDEX+1}"; do
      if [ -n "$OPTION_VALUE" ]; then
        [ "$OPTION_VALUE" = pattern ] && PATTERN_SEEN=true
        OPTION_VALUE=
        continue
      fi
      case "$BIN:$token" in
        rg:-e|rg:--regexp|grep:-e|grep:--regexp) OPTION_VALUE=pattern; continue ;;
        rg:-g|rg:--glob|rg:--iglob|rg:-t|rg:--type|grep:--include|grep:--exclude) OPTION_VALUE=option; continue ;;
      esac
      case "$token" in -*) continue ;; esac
      if [ "$PATTERN_SEEN" = false ]; then PATTERN_SEEN=true; continue; fi
      is_skill_scope "$token" && hook_deny "$READ_MSG"
      [ -f "$(source_path "$token")" ] && EXPLICIT_FILE=true
    done
    if [ "$EXPLICIT_FILE" = false ] && is_skill_scope "$READ_CWD"; then hook_deny "$READ_MSG"; fi
    ;;
esac
exit 0
