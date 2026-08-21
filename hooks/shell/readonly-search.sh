#!/bin/bash
# PreToolUse / PermissionRequest(Bash) hook: shell commandを単一の読み取り実行へ制限する。
# Why: pipelineごとの安全例外は組み合わせの数だけ増える。loop・条件分岐・pipeline・
#      subshellは一律拒否し、危険optionもコマンド単体で拒否する。/dev/nullへの出力だけは
#      検証済みの読み取りコマンドに限って許可し、不要な承認と不要な診断出力を避ける。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
[ "$(hook_tool_name)" = "Bash" ] || exit 0
EVENT=$(hook_event_name)
case "$EVENT" in ""|PreToolUse|PermissionRequest) ;; *) exit 0 ;; esac
CMD=$(hook_command)
[ -z "$CMD" ] && exit 0

complete_safe_readonly_command() {
  if [ "$EVENT" = "PermissionRequest" ]; then
    hook_permission_allow
  fi
  hook_rewrite_command "$1"
}

has_safe_shell_syntax() {
  printf '%s\n' "$1" | awk '
    BEGIN { valid = 1; state = "plain"; escaped = 0; sq = sprintf("%c", 39) }
    NR != 1 { valid = 0 }
    {
      for (i = 1; i <= length($0); i++) {
        ch = substr($0, i, 1)
        if (state == "single") {
          if (ch == sq) state = "plain"
          continue
        }
        if (state == "double") {
          if (escaped) { escaped = 0; continue }
          if (ch == "\\") { escaped = 1; continue }
          if (ch == "\"") { state = "plain"; continue }
          if (ch == "$" || ch == "`") valid = 0
          continue
        }
        if (ch == sq) { state = "single"; continue }
        if (ch == "\"") { state = "double"; continue }
        if (ch == "\\" || index(";&|<>`$(){}#*?[]", ch) > 0) valid = 0
      }
    }
    END {
      if (state != "plain" || escaped) valid = 0
      exit(valid ? 0 : 1)
    }
  '
}

has_compound_shell_syntax() {
  printf '%s\n' "$1" | awk '
    BEGIN { compound = 0; state = "plain"; escaped = 0; sq = sprintf("%c", 39) }
    NR != 1 { compound = 1 }
    {
      for (i = 1; i <= length($0); i++) {
        ch = substr($0, i, 1)
        next_ch = substr($0, i + 1, 1)
        prev_ch = i > 1 ? substr($0, i - 1, 1) : ""
        if (state == "single") {
          if (ch == sq) state = "plain"
          continue
        }
        if (state == "double") {
          if (escaped) { escaped = 0; continue }
          if (ch == "\\") { escaped = 1; continue }
          if (ch == "\"") { state = "plain"; continue }
          if (ch == "`" || (ch == "$" && next_ch == "(")) compound = 1
          continue
        }
        if (escaped) { escaped = 0; continue }
        if (ch == "\\") { escaped = 1; continue }
        if (ch == sq) { state = "single"; continue }
        if (ch == "\"") { state = "double"; continue }
        if (ch == ";" || ch == "|" || ch == "`" || ch == "(" || ch == ")") compound = 1
        if (ch == "&" && prev_ch != ">") compound = 1
        if (ch == "$" && next_ch == "(") compound = 1
      }
    }
    END {
      if (state != "plain" || escaped) compound = 1
      exit(compound ? 0 : 1)
    }
  '
}

invokes_inline_shell() {
  printf '%s\n' "$1" | awk '
    {
      is_shell = $0 ~ /^[[:space:]]*((\/usr\/bin\/)?env[[:space:]]+)?(\/(usr\/)?bin\/)?(bash|zsh|sh)[[:space:]]+/
      has_command_flag = $0 ~ /[[:space:]]-[[:alnum:]]*c([[:space:]]|$)/
      if (is_shell && has_command_flag) found = 1
    }
    END { exit(found ? 0 : 1) }
  '
}

normalize_default_delegate_model() {
  local default_assignment='DELEGATE_MODEL=openrouter/minimax/minimax-m3 '
  local wrapped_prefix
  local rewritten

  # 既定値の明示は冗長であり、Codexがzsh -lcへ包むと固定runnerのallowから外れる。
  # 既定値だけを外して、レビュー済みの裸のdelegate.sh呼び出しへ戻す。別モデルは触らない。
  case "$1" in
    "$default_assignment"bash\ .agents/skills/worker/delegate.sh*|"$default_assignment"bash\ .claude/skills/worker/delegate.sh*)
      hook_rewrite_command "${1#"$default_assignment"}"
      ;;
  esac

  for wrapped_prefix in \
    '/bin/zsh -lc "DELEGATE_MODEL=openrouter/minimax/minimax-m3 ' \
    'zsh -lc "DELEGATE_MODEL=openrouter/minimax/minimax-m3 '; do
    case "$1" in
      "$wrapped_prefix"bash\ .agents/skills/worker/delegate.sh*\"|"$wrapped_prefix"bash\ .claude/skills/worker/delegate.sh*\")
        rewritten=${1#"$wrapped_prefix"}
        rewritten=${rewritten%\"}
        hook_rewrite_command "$rewritten"
        ;;
    esac
  done
}

dangerous_read_reason() {
  local command_without_quote_splits

  # shellが連結するquoteとbackslashを除いてからoptionを見る。例えば
  # find "-de""lete" や find -de\lete で検査を迂回させない。
  command_without_quote_splits=$(printf '%s\n' "$1" | tr -d "\"'" | tr -d '\\')

  if printf '%s\n' "$command_without_quote_splits" | grep -Eq '^[[:space:]]*([^[:space:]]*/)?find[[:space:]]' && \
     printf '%s\n' "$command_without_quote_splits" | grep -Eq -- '(^|[[:space:]])-(delete|exec|execdir|ok|okdir|fprint|fprint0|fprintf|fls)([[:space:]]|$)'; then
    printf '%s\n' "findの削除・任意command実行・file出力actionは禁止です。読み取り専用の-printを使い、書き込みや削除は明示的な単一commandとして承認を受けてください。"
    return 0
  fi

  if printf '%s\n' "$command_without_quote_splits" | grep -Eq '^[[:space:]]*([^[:space:]]*/)?sort[[:space:]]' && \
     printf '%s\n' "$command_without_quote_splits" | grep -Eq -- '(^|[[:space:]])(-o([^[:space:]]*)?|--output([=[:space:]]|$)|--compress-program([=[:space:]]|$))'; then
    printf '%s\n' "sortのfile出力・外部program実行optionは禁止です。sortは標準出力への読み取り専用実行に限定してください。"
    return 0
  fi

  if printf '%s\n' "$command_without_quote_splits" | grep -Eq '^[[:space:]]*([^[:space:]]*/)?rg[[:space:]]' && \
     printf '%s\n' "$command_without_quote_splits" | grep -Eq -- '(^|[[:space:]])--pre([=[:space:]]|$)'; then
    printf '%s\n' "rg --preによる外部command実行は禁止です。rg単体で読める対象を検索してください。"
    return 0
  fi

  if printf '%s\n' "$command_without_quote_splits" | grep -Eq '^[[:space:]]*git[[:space:]]+(diff|log|show)([[:space:]]|$)' && \
     printf '%s\n' "$command_without_quote_splits" | grep -Eq -- '(^|[[:space:]])--output([=[:space:]]|$)'; then
    printf '%s\n' "読み取り用git commandの--outputによるfile書き込みは禁止です。標準出力で確認してください。"
    return 0
  fi

  return 1
}

is_safe_readonly_command() {
  case "$1" in
    pwd|pwd\ *|ls|ls\ *|rg\ *|grep\ *|cat\ *|head\ *|tail\ *|wc\ *|jq\ *|find\ *|nl\ *|sort\ *|bash\ -n\ *|command\ -v\ *|git\ status*|git\ diff*|git\ log*|git\ show*|git\ ls-files*|git\ grep*) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_readonly_executable() {
  local readonly_command=$1
  local executable
  local quoted_command
  local remainder

  # Codex は argv から組み立てた command の実行file名まで 'rg' のようにquoteする。
  # 先頭tokenだけquoteを外し、permission層が /bin/zsh -lc ではなく直接実行として
  # 静的判定できる形へ戻す。引数のquoteは検索patternを保持するため触らない。
  case "$readonly_command" in
    \'*)
      quoted_command=${readonly_command#\'}
      case "$quoted_command" in *\'*) ;; *) return 1 ;; esac
      executable=${quoted_command%%\'*}
      remainder=${quoted_command#"$executable"}
      remainder=${remainder#\'}
      ;;
    \"*)
      quoted_command=${readonly_command#\"}
      case "$quoted_command" in *\"*) ;; *) return 1 ;; esac
      executable=${quoted_command%%\"*}
      remainder=${quoted_command#"$executable"}
      remainder=${remainder#\"}
      ;;
    *)
      printf '%s\n' "$readonly_command"
      return 0
      ;;
  esac

  case "$remainder" in
    ""|" "*) printf '%s%s\n' "$executable" "$remainder" ;;
    *) return 1 ;;
  esac
}

normalize_safe_dev_null() {
  local readonly_command=$1
  local base_command
  local normalized_command
  local redirect_suffix

  # /dev/null以外のredirectはpermission層へ委ねる。末尾の単一redirectだけを扱い、
  # 2>&1や複数redirectの新しい組み合わせを例外として増やさない。Codexのpermission層は
  # redirectが残るとshell wrapperへ包み直すため、安全な読み取りcommandのstderr破棄は
  # optionへ置換できる場合を除いて削る。診断表示は増えるが、終了statusと読み取り結果は変えない。
  case "$readonly_command" in
    *" 2>/dev/null")
      base_command=${readonly_command%" 2>/dev/null"}
      redirect_suffix=" 2>/dev/null"
      ;;
    *" 2> /dev/null")
      base_command=${readonly_command%" 2> /dev/null"}
      redirect_suffix=" 2>/dev/null"
      ;;
    *" 1>/dev/null")
      base_command=${readonly_command%" 1>/dev/null"}
      redirect_suffix=" >/dev/null"
      ;;
    *" 1> /dev/null")
      base_command=${readonly_command%" 1> /dev/null"}
      redirect_suffix=" >/dev/null"
      ;;
    *" >/dev/null")
      base_command=${readonly_command%" >/dev/null"}
      redirect_suffix=" >/dev/null"
      ;;
    *" > /dev/null")
      base_command=${readonly_command%" > /dev/null"}
      redirect_suffix=" >/dev/null"
      ;;
    *) return ;;
  esac

  has_safe_shell_syntax "$base_command" || return
  is_safe_readonly_command "$base_command" || return

  normalized_command=$base_command
  if [ "$redirect_suffix" = " 2>/dev/null" ]; then
    case " $base_command " in
      " rg "*)
        case " $base_command " in
          *" --no-messages "*) ;;
          *) normalized_command="rg --no-messages${base_command#rg}" ;;
        esac
        ;;
    esac
    redirect_suffix=
  fi

  complete_safe_readonly_command "$normalized_command$redirect_suffix"
}

if DANGEROUS_REASON=$(dangerous_read_reason "$CMD"); then
  [ "$EVENT" = "PermissionRequest" ] && exit 0
  hook_deny "$DANGEROUS_REASON"
fi

[ "$EVENT" = "PermissionRequest" ] || normalize_default_delegate_model "$CMD"

if has_compound_shell_syntax "$CMD" || invokes_inline_shell "$CMD"; then
  [ "$EVENT" = "PermissionRequest" ] && exit 0
  hook_deny "複数コマンドを shell loop・条件分岐・pipeline に集約してはいけません。Read/Grep/Glob または副作用を静的判定できる単一コマンドへ分割してください。複雑な処理はレビュー済み固定スクリプトへ移してください。"
fi

NORMALIZED_CMD=$(normalize_readonly_executable "$CMD") || exit 0

normalize_safe_dev_null "$NORMALIZED_CMD"

has_safe_shell_syntax "$CMD" || exit 0
if is_safe_readonly_command "$NORMALIZED_CMD"; then
  complete_safe_readonly_command "$NORMALIZED_CMD"
fi

exit 0
