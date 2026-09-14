#!/bin/bash
# 固定スクリプト内のGitが別repository・外部hook・署名・自動保守へ逸れないようにする。
# Appleのgit/python shimもTMPDIRへ書くため、外部commandより先にBash built-inだけで検査する。
git_safe_temp() {
  local temporary current marker metadata value common
  temporary=$(cd -- "${TMPDIR:-/tmp}" && builtin pwd -P) || return 1
  case "/$temporary/" in
    */.[gG][iI][tT]/*) printf '%s\n' 'ERROR: TMPDIR points into .git' >&2; return 1 ;;
  esac
  current=$(builtin pwd -P) || return 1
  while [ -n "$current" ]; do
    marker="$current/.git"
    if [ -d "$marker" ]; then
      metadata=$(cd -- "$marker" && builtin pwd -P) || return 1
    elif [ -f "$marker" ]; then
      IFS= read -r value < "$marker" || [ -n "$value" ] || return 1
      case "$value" in 'gitdir: '*) value=${value#'gitdir: '} ;; *) return 1 ;; esac
      case "$value" in /*) ;; *) value="$current/$value" ;; esac
      metadata=$(cd -- "$value" && builtin pwd -P) || return 1
    else
      [ "$current" != / ] || break
      current=${current%/*}
      continue
    fi
    case "$temporary/" in "$metadata/"*) printf '%s\n' 'ERROR: TMPDIR points into Git metadata' >&2; return 1 ;; esac
    if [ -f "$metadata/commondir" ]; then
      IFS= read -r value < "$metadata/commondir" || [ -n "$value" ] || return 1
      case "$value" in /*) ;; *) value="$metadata/$value" ;; esac
      common=$(cd -- "$value" && builtin pwd -P) || return 1
      case "$temporary/" in "$common/"*) printf '%s\n' 'ERROR: TMPDIR points into shared Git metadata' >&2; return 1 ;; esac
    fi
    break
  done
}
git_safe_temp || return 1
unset BASH_ENV ENV
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_CONFIG_PARAMETERS GIT_EXTERNAL_DIFF GIT_TRACE GIT_TRACE_SETUP GIT_TRACE_PERFORMANCE GIT_TRACE_PACKET
unset GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF GIT_TRACE_PACK_ACCESS GIT_TRACE_PACKFILE
export GIT_OPTIONAL_LOCKS=0 GIT_PAGER= GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=7
export GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
export GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_KEY_2=core.untrackedCache GIT_CONFIG_VALUE_2=false
export GIT_CONFIG_KEY_3=commit.gpgSign GIT_CONFIG_VALUE_3=false
export GIT_CONFIG_KEY_4=status.submoduleSummary GIT_CONFIG_VALUE_4=false
export GIT_CONFIG_KEY_5=gc.auto GIT_CONFIG_VALUE_5=0
export GIT_CONFIG_KEY_6=maintenance.auto GIT_CONFIG_VALUE_6=false
