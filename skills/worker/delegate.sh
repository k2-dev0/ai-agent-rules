#!/bin/bash
# OpenCode + OpenRouter の下位モデルへ、変更済み本体コードのネスト候補抽出だけを委任する。
set -u

readonly SOFT_BUDGET_USD="38"
readonly HARD_BUDGET_USD="40"
readonly DEFAULT_MODEL="openrouter/minimax/minimax-m3"
readonly MODEL="${DELEGATE_MODEL:-$DEFAULT_MODEL}"
readonly MODEL_ID="${MODEL#openrouter/}"
readonly MODEL_VARIANT="${DELEGATE_MODEL_VARIANT:-}"
readonly TIMEOUT_MINUTE_SECONDS="60"
readonly TIMEOUT_TERM_GRACE_SECONDS="10"
readonly SMOKE_HARD_TIMEOUT_MINUTES="1"
readonly SMOKE_IDLE_TIMEOUT_SECONDS="30"
readonly SMOKE_POLL_SECONDS="5"
readonly MIN_HARD_TIMEOUT_MINUTES="2"
readonly MAX_HARD_TIMEOUT_MINUTES="60"
readonly MIN_IDLE_TIMEOUT_SECONDS="30"
readonly MAX_IDLE_TIMEOUT_SECONDS="900"
readonly MIN_POLL_SECONDS="2"
readonly MAX_POLL_SECONDS="60"
readonly MIN_POLLS_PER_IDLE_WINDOW="3"
readonly MIN_IDLE_WINDOWS_PER_HARD_TIMEOUT="2"
readonly MIN_TIMEOUT_REASON_CHARACTERS="24"
readonly SMOKE_PROMPT="hello"
readonly MISSING_REPORT_STATUS="65"
readonly OPENROUTER_KEY_ENDPOINT="https://openrouter.ai/api/v1/key"
readonly TASK_ID_PATTERN='^[a-z0-9][a-z0-9-]{0,62}$'

MODE="${1:-}"
TASK_ID=""
HARD_TIMEOUT_MINUTES=""
HARD_TIMEOUT_SECONDS=""
IDLE_TIMEOUT_SECONDS=""
TIMEOUT_POLL_SECONDS=""
TIMEOUT_REASON=""
TIMEOUT_POLICY_SOURCE=""
NESTING_PATHS=()
REPO_ROOT=""
RESULT_PARENT=""
RESULT_DIR=""
RESULT_STAGING=""
TASK_RUNTIME=""
TASK_STATE=""
TEMP_ROOT=""
WORKTREE=""
WORKTREE_READONLY=0
SOURCE_COMMIT=""
SOURCE_HEAD=""
SOURCE_WORKTREE_STATUS_JSON='[]'
OPENCODE_PID=""
TIMEOUT_MONITOR_PID=""
TIMEOUT_MARKER=""
TASK_STARTED=0
TASK_FINISHED=0
FAILURE_REASON=""

fail() {
  FAILURE_REASON=$1
  printf 'delegate: %s\n' "$1" >&2
  exit 1
}

is_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

validate_model() {
  case "$MODEL" in
    openrouter/*/*) ;;
    *) fail "DELEGATE_MODEL must use the openrouter/<provider>/<model> format" ;;
  esac
  if [ -n "$MODEL_VARIANT" ] && [[ ! "$MODEL_VARIANT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    fail "DELEGATE_MODEL_VARIANT contains unsupported characters"
  fi
}

validate_timeout_reason() {
  [ "${#TIMEOUT_REASON}" -ge "$MIN_TIMEOUT_REASON_CHARACTERS" ] || fail "timeout reason is too short"
  case "$TIMEOUT_REASON" in
    scope=*,difficulty=*,basis=*) ;;
    *) fail "timeout reason must use scope=...,difficulty=...,basis=..." ;;
  esac
}

configure_timeouts() {
  is_integer "$HARD_TIMEOUT_MINUTES" || fail "hard timeout must be an integer"
  is_integer "$IDLE_TIMEOUT_SECONDS" || fail "idle timeout must be an integer"
  is_integer "$TIMEOUT_POLL_SECONDS" || fail "poll interval must be an integer"
  [ "$HARD_TIMEOUT_MINUTES" -ge "$MIN_HARD_TIMEOUT_MINUTES" ] || fail "hard timeout is below minimum"
  [ "$HARD_TIMEOUT_MINUTES" -le "$MAX_HARD_TIMEOUT_MINUTES" ] || fail "hard timeout exceeds maximum"
  [ "$IDLE_TIMEOUT_SECONDS" -ge "$MIN_IDLE_TIMEOUT_SECONDS" ] || fail "idle timeout is below minimum"
  [ "$IDLE_TIMEOUT_SECONDS" -le "$MAX_IDLE_TIMEOUT_SECONDS" ] || fail "idle timeout exceeds maximum"
  [ "$TIMEOUT_POLL_SECONDS" -ge "$MIN_POLL_SECONDS" ] || fail "poll interval is below minimum"
  [ "$TIMEOUT_POLL_SECONDS" -le "$MAX_POLL_SECONDS" ] || fail "poll interval exceeds maximum"
  [ "$((IDLE_TIMEOUT_SECONDS / TIMEOUT_POLL_SECONDS))" -ge "$MIN_POLLS_PER_IDLE_WINDOW" ] || fail "idle timeout must contain at least 3 polls"
  HARD_TIMEOUT_SECONDS="$((HARD_TIMEOUT_MINUTES * TIMEOUT_MINUTE_SECONDS))"
  [ "$HARD_TIMEOUT_SECONDS" -ge "$((IDLE_TIMEOUT_SECONDS * MIN_IDLE_WINDOWS_PER_HARD_TIMEOUT))" ] || fail "hard timeout must contain at least 2 idle windows"
  validate_timeout_reason
  TIMEOUT_POLICY_SOURCE="explicit"
}

validate_task_id() {
  [[ "$1" =~ $TASK_ID_PATTERN ]] || fail "task id must be lowercase kebab-case"
}

resolve_repository() {
  command -v git >/dev/null 2>&1 || fail "git is required"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || fail "not inside a git repository"
  case "$REPO_ROOT" in
    /|"$HOME") fail "unsafe repository root" ;;
  esac
  if [ -d "$REPO_ROOT/.codex" ]; then
    RESULT_PARENT="$REPO_ROOT/.codex/tmp/worker"
  elif [ -d "$REPO_ROOT/.claude" ]; then
    RESULT_PARENT="$REPO_ROOT/.claude/tmp/worker"
  else
    fail "cannot identify .codex or .claude worker result root"
  fi
}

validate_repo_path() {
  local path=$1
  local cursor=$REPO_ROOT
  local segment

  case "$path" in
    ''|/*|./*|../*|*/../*|*/..|*//*|*$'\n'*|*$'\r'*|*$'\t'*) fail "path must be normalized and repository-relative: $path" ;;
  esac
  IFS='/' read -r -a segments <<< "$path"
  for segment in "${segments[@]}"; do
    cursor="$cursor/$segment"
    [ ! -L "$cursor" ] || fail "symlink paths cannot be delegated: $path"
  done
}

validate_nesting_path() {
  local path=$1

  validate_repo_path "$path"
  case "$path" in
    *.test.*|*.spec.*|*_test.*|*_spec.*|test_*.*|spec_*.*|test/*|tests/*|__tests__/*|*/test/*|*/tests/*|*/__tests__/*|*.snap|*fixture*|*mock*|*stub*|*fake*)
      fail "test assets cannot be inspected for nesting: $path" ;;
  esac
  case "$path" in
    *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.mts|*.cts|*.py|*.rb|*.go|*.rs|*.java|*.kt|*.kts|*.c|*.h|*.cc|*.cpp|*.cs|*.php|*.swift|*.scala|*.sh) ;;
    *) fail "nesting path must be production code: $path" ;;
  esac
  git -C "$REPO_ROOT" ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1 || fail "nesting path must be tracked: $path"
  [ -f "$REPO_ROOT/$path" ] || fail "nesting path must be a file: $path"
  [ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- ":(literal)$path")" ] || fail "nesting path must be committed and clean: $path"
}

extract_report() {
  jq -rs '
    def text_event:
      select(type == "object" and .type == "text")
      | (.part.text // .text // empty)
      | select(type == "string" and test("[^[:space:]]"));
    [.[] | text_event] | last // empty
  ' "$1" 2>/dev/null
}

process_group_alive() {
  [ -n "$1" ] && kill -0 -- "-$1" 2>/dev/null
}

terminate_process_group() {
  local pid=$1
  local waited=0

  [ -n "$pid" ] || return 0
  if process_group_alive "$pid"; then
    kill -TERM -- "-$pid" 2>/dev/null || true
  elif kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
  else
    return 0
  fi
  while [ "$waited" -lt "$TIMEOUT_TERM_GRACE_SECONDS" ]; do
    process_group_alive "$pid" || kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
    waited=$((waited + 1))
  done
  if process_group_alive "$pid"; then
    kill -KILL -- "-$pid" 2>/dev/null || true
  elif kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

stop_running_children() {
  if [ -n "$TIMEOUT_MONITOR_PID" ]; then
    kill "$TIMEOUT_MONITOR_PID" 2>/dev/null || true
    wait "$TIMEOUT_MONITOR_PID" 2>/dev/null || true
    TIMEOUT_MONITOR_PID=""
  fi
  if [ -n "$OPENCODE_PID" ]; then
    terminate_process_group "$OPENCODE_PID"
    wait "$OPENCODE_PID" 2>/dev/null || true
    OPENCODE_PID=""
  fi
}

write_task_state() {
  local lifecycle=$1
  local temporary_state

  [ -n "$TASK_STATE" ] || return 0
  temporary_state="$TASK_STATE.tmp.$$"
  jq -n \
    --arg lifecycle_status "$lifecycle" \
    --arg task_id "$TASK_ID" \
    --arg mode "$MODE" \
    --arg repository "$REPO_ROOT" \
    --arg source_head "$SOURCE_HEAD" \
    --arg opencode_pid "$OPENCODE_PID" \
    --arg failure_reason "$FAILURE_REASON" \
    '{
      lifecycle_status:$lifecycle_status,
      task_id:$task_id,
      mode:$mode,
      repository:$repository,
      source_head:$source_head,
      opencode_pid:(if $opencode_pid == "" then null else ($opencode_pid | tonumber) end),
      failure_reason:(if $failure_reason == "" then null else $failure_reason end),
      updated_at:(now | floor)
    }' > "$temporary_state" || return 1
  mv "$temporary_state" "$TASK_STATE"
}

cleanup() {
  local status=$?

  stop_running_children
  if [ "$TASK_STARTED" -eq 1 ] && [ "$TASK_FINISHED" -eq 0 ]; then
    case "$status" in
      130|143) write_task_state "interrupted" || true ;;
      *) write_task_state "failed" || true ;;
    esac
    [ -z "$RESULT_STAGING" ] || rm -rf "$RESULT_STAGING"
  fi
  if [ "$WORKTREE_READONLY" -eq 1 ] && [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
    chmod -R u+w "$WORKTREE" 2>/dev/null || true
  fi
  [ -z "$TEMP_ROOT" ] || rm -rf "$TEMP_ROOT"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

show_task() {
  local state_path="$RESULT_PARENT/.$TASK_ID.task/state.json"
  local result_path="$RESULT_PARENT/$TASK_ID/result.json"
  local lifecycle
  local pid

  if [ -f "$result_path" ]; then
    jq -e . "$result_path" >/dev/null 2>&1 || fail "cannot extract delegated report: invalid result.json for $TASK_ID"
    jq '. + {effective_status:(if .status == 0 then "complete" else "failed" end)}' "$result_path"
    [ "$(jq -r '.status' "$result_path")" -eq 0 ]
    return
  fi
  [ -f "$state_path" ] || fail "cannot extract delegated report: task not found: $TASK_ID"
  lifecycle=$(jq -r '.lifecycle_status // "unknown"' "$state_path")
  pid=$(jq -r '.opencode_pid // empty' "$state_path")
  if [ "$lifecycle" = "running" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    jq '. + {effective_status:"running"}' "$state_path"
    return 2
  fi
  if [ "$lifecycle" = "running" ]; then
    jq '. + {effective_status:"orphaned-running"}' "$state_path"
  else
    jq --arg status "$lifecycle" '. + {effective_status:$status}' "$state_path"
  fi
  return 1
}

check_budget() {
  local curl_config="$TEMP_ROOT/curl.config"
  local key_info
  local key_reset
  local current_usage
  local key_limit

  command -v curl >/dev/null 2>&1 || fail "curl is required"
  [ -n "${OPENROUTER_API_KEY:-}" ] || fail "OPENROUTER_API_KEY is required"
  printf 'header = "Authorization: Bearer %s"\nsilent\nshow-error\nfail\n' "$OPENROUTER_API_KEY" > "$curl_config" || fail "cannot prepare budget request"
  key_info=$(curl --config "$curl_config" "$OPENROUTER_KEY_ENDPOINT") || fail "cannot read OpenRouter key usage"
  key_limit=$(printf '%s' "$key_info" | jq -er '.data.limit') || fail "OpenRouter API key must have a hard limit"
  key_reset=$(printf '%s' "$key_info" | jq -r '.data.limit_reset // "none"') || fail "cannot read OpenRouter key reset period"
  case "$key_reset" in
    monthly) current_usage=$(printf '%s' "$key_info" | jq -er '.data.usage_monthly') || fail "OpenRouter response has no monthly usage" ;;
    none) current_usage=$(printf '%s' "$key_info" | jq -er '.data.usage') || fail "OpenRouter response has no total usage" ;;
    *) fail "API key hard limit must reset monthly or never" ;;
  esac
  jq -ne --argjson usage "$current_usage" --argjson soft "$SOFT_BUDGET_USD" '$usage < $soft' >/dev/null || fail "soft budget exceeded: $current_usage USD"
  jq -ne --argjson limit "$key_limit" --argjson hard "$HARD_BUDGET_USD" '$limit <= $hard' >/dev/null || fail "API key hard limit exceeds $HARD_BUDGET_USD USD"
}

create_opencode_config() {
  local mode=$1
  local read_rules
  local glob_rule
  local grep_rule
  local list_rule
  local lsp_rule

  EDIT_RULES='{"*":"deny"}'
  if [ "$mode" = "smoke" ]; then
    read_rules='"deny"'
    glob_rule="deny"
    grep_rule="deny"
    list_rule="deny"
    lsp_rule="deny"
  else
    read_rules='{"*":"allow","*.env":"deny","*.env.*":"deny","**/.env":"deny","**/.env.*":"deny",".git/**":"deny"}'
    glob_rule="allow"
    grep_rule="allow"
    list_rule="allow"
    lsp_rule="allow"
  fi
  jq -cn \
    --argjson permission_edit "$EDIT_RULES" \
    --argjson permission_read "$read_rules" \
    --arg glob "$glob_rule" \
    --arg grep "$grep_rule" \
    --arg list "$list_rule" \
    --arg lsp "$lsp_rule" \
    --arg model_id "$MODEL_ID" \
    '{
      "$schema":"https://opencode.ai/config.json",
      "share":"disabled",
      "default_agent":"delegate",
      "agent":{"delegate":{"description":"Extract bounded control-flow nesting candidates"}},
      "permission":{
        "*":"deny",
        "read":$permission_read,
        "glob":$glob,
        "grep":$grep,
        "list":$list,
        "lsp":$lsp,
        "edit":$permission_edit,
        "bash":"deny",
        "task":"deny",
        "external_directory":"deny",
        "webfetch":"deny",
        "websearch":"deny",
        "skill":"deny",
        "question":"deny",
        "doom_loop":"deny"
      },
      "provider":{
        "openrouter":{
          "models":{
            ($model_id):{
              "options":{
                "provider":{
                  "zdr":true,
                  "data_collection":"deny"
                }
              }
            }
          }
        }
      }
    }' > "$TEMP_ROOT/opencode.json" || fail "cannot create OpenCode config"
}

has_valid_event() {
  jq -Rse '
    split("\n")
    | map(select(length > 0) | (try fromjson catch null))
    | any(type == "object")
  ' "$1" >/dev/null 2>&1
}

monitor_opencode() {
  local pid=$1
  local output_path=$2
  local started_at=$3
  local last_activity=$started_at
  local last_bytes=0
  local now
  local bytes

  while kill -0 "$pid" 2>/dev/null; do
    sleep "$TIMEOUT_POLL_SECONDS"
    now=$(date +%s)
    bytes=$(wc -c < "$output_path" 2>/dev/null | tr -d ' ')
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    if [ "$bytes" -gt "$last_bytes" ] && has_valid_event "$output_path"; then
      last_activity=$now
      last_bytes=$bytes
    fi
    if [ "$((now - started_at))" -ge "$HARD_TIMEOUT_SECONDS" ]; then
      printf 'hard\n' > "$TIMEOUT_MARKER"
      terminate_process_group "$pid"
      return
    fi
    if [ "$((now - last_activity))" -ge "$IDLE_TIMEOUT_SECONDS" ]; then
      printf 'idle\n' > "$TIMEOUT_MARKER"
      terminate_process_group "$pid"
      return
    fi
  done
}

run_opencode() {
  local execution_root=$1
  local prompt=$2
  local output_path=$3
  local error_path=$4
  local started_at
  local status
  local command=(opencode --pure run --agent delegate --format json --model "$MODEL")

  command -v opencode >/dev/null 2>&1 || fail "opencode is required"
  if [ -n "$MODEL_VARIANT" ]; then
    command+=(--variant "$MODEL_VARIANT")
  fi
  command+=("$prompt")
  started_at=$(date +%s)
  set -m
  (
    cd "$execution_root" || exit 72
    exec env -i \
      HOME="$HOME" \
      XDG_DATA_HOME="$TEMP_ROOT/xdg-data" \
      XDG_STATE_HOME="$TEMP_ROOT/xdg-state" \
      XDG_CACHE_HOME="$TEMP_ROOT/xdg-cache" \
      XDG_CONFIG_HOME="$TEMP_ROOT/xdg-config" \
      TMPDIR="$TEMP_ROOT/tmp" \
      PATH="$PATH" \
      LANG="${LANG:-C.UTF-8}" \
      TERM="${TERM:-dumb}" \
      OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
      OPENCODE_CONFIG="$TEMP_ROOT/opencode.json" \
      OPENCODE_DISABLE_AUTOUPDATE=true \
      "${command[@]}"
  ) > "$output_path" 2> "$error_path" &
  OPENCODE_PID=$!
  set +m
  [ "$TASK_STARTED" -eq 0 ] || write_task_state "running" || fail "cannot update task state"
  monitor_opencode "$OPENCODE_PID" "$output_path" "$started_at" &
  TIMEOUT_MONITOR_PID=$!
  wait "$OPENCODE_PID"
  status=$?
  kill "$TIMEOUT_MONITOR_PID" 2>/dev/null || true
  wait "$TIMEOUT_MONITOR_PID" 2>/dev/null || true
  TIMEOUT_MONITOR_PID=""
  if process_group_alive "$OPENCODE_PID"; then
    terminate_process_group "$OPENCODE_PID"
  fi
  OPENCODE_PID=""
  if [ -f "$TIMEOUT_MARKER" ]; then
    return 124
  fi
  return "$status"
}

create_bounded_snapshot() {
  local path
  local parent

  mkdir -p "$WORKTREE" || fail "cannot create bounded source snapshot"
  for path in "${NESTING_PATHS[@]}"; do
    case "$path" in
      */*)
        parent=${path%/*}
        mkdir -p "$WORKTREE/$parent" || fail "cannot create bounded source snapshot directory: $parent"
        ;;
    esac
    git -C "$REPO_ROOT" show "$SOURCE_COMMIT:$path" > "$WORKTREE/$path" || fail "cannot copy committed source into bounded snapshot: $path"
  done
  chmod -R a-w "$WORKTREE" || fail "cannot make bounded source snapshot read-only"
  WORKTREE_READONLY=1
}

bounded_snapshot_unchanged() {
  local expected_count=${#NESTING_PATHS[@]}
  local actual_count
  local path
  local source_hash
  local snapshot_hash

  actual_count=$(find "$WORKTREE" -type f | wc -l | tr -d ' ')
  [ "$actual_count" -eq "$expected_count" ] || return 1
  [ -z "$(find "$WORKTREE" -type l -print -quit)" ] || return 1
  for path in "${NESTING_PATHS[@]}"; do
    source_hash=$(git -C "$REPO_ROOT" rev-parse "$SOURCE_COMMIT:$path") || return 1
    snapshot_hash=$(git hash-object "$WORKTREE/$path") || return 1
    [ "$source_hash" = "$snapshot_hash" ] || return 1
  done
}

validate_model
case "$MODE" in
  research|survey)
    fail "research and survey modes were removed; lower models are limited to bounded QA"
    ;;
esac
[ "$#" -gt 0 ] && shift || true

case "$MODE" in
  nesting)
    [ "$#" -ge 10 ] || fail "nesting mode requires explicit timeouts, task id, and at least one production path"
    [ "$1" = "--hard-timeout-minutes" ] || fail "nesting mode requires --hard-timeout-minutes first"
    HARD_TIMEOUT_MINUTES=$2
    [ "$3" = "--idle-timeout-seconds" ] || fail "nesting mode requires --idle-timeout-seconds second"
    IDLE_TIMEOUT_SECONDS=$4
    [ "$5" = "--poll-seconds" ] || fail "nesting mode requires --poll-seconds third"
    TIMEOUT_POLL_SECONDS=$6
    [ "$7" = "--timeout-reason" ] || fail "nesting mode requires --timeout-reason fourth"
    TIMEOUT_REASON=$8
    shift 8
    configure_timeouts
    TASK_ID=$1
    validate_task_id "$TASK_ID"
    shift
    [ "$#" -ge 1 ] || fail "nesting mode requires at least one production path"
    NESTING_PATHS=("$@")
    ;;
  prepare)
    [ "$#" -eq 0 ] || fail "prepare mode does not accept arguments"
    printf 'delegate: delegation contract ready\n'
    exit 0
    ;;
  smoke)
    [ "$#" -eq 0 ] || fail "smoke mode does not accept arguments"
    HARD_TIMEOUT_MINUTES=$SMOKE_HARD_TIMEOUT_MINUTES
    HARD_TIMEOUT_SECONDS="$((SMOKE_HARD_TIMEOUT_MINUTES * TIMEOUT_MINUTE_SECONDS))"
    IDLE_TIMEOUT_SECONDS=$SMOKE_IDLE_TIMEOUT_SECONDS
    TIMEOUT_POLL_SECONDS=$SMOKE_POLL_SECONDS
    TIMEOUT_POLICY_SOURCE="fixed-smoke"
    ;;
  show)
    [ "$#" -eq 1 ] || fail "show mode requires task id"
    TASK_ID=$1
    validate_task_id "$TASK_ID"
    resolve_repository
    show_task
    exit $?
    ;;
  *)
    fail "mode must be nesting, prepare, smoke, or show"
    ;;
esac

resolve_repository
cd "$REPO_ROOT" || fail "cannot enter repository root"

if [ "$MODE" = "nesting" ]; then
  SEEN_PATHS="
"
  for path in "${NESTING_PATHS[@]}"; do
    validate_nesting_path "$path"
    case "$SEEN_PATHS" in
      *$'\n'"$path"$'\n'*) fail "nesting path is duplicated: $path" ;;
    esac
    SEEN_PATHS="$SEEN_PATHS$path
"
  done
  SOURCE_COMMIT=$(git rev-parse --verify 'HEAD^{commit}') || fail "cannot resolve HEAD"
  SOURCE_HEAD=$SOURCE_COMMIT
  SOURCE_WORKTREE_STATUS_JSON=$(git status --porcelain=v1 --untracked-files=all | jq -Rsc 'split("\n") | map(select(length > 0))') || fail "cannot record source worktree status"
  mkdir -p "$RESULT_PARENT" || fail "cannot create worker result root"
  RESULT_DIR="$RESULT_PARENT/$TASK_ID"
  [ ! -e "$RESULT_DIR" ] || fail "task already has a published result: $TASK_ID"
  TASK_RUNTIME="$RESULT_PARENT/.$TASK_ID.task"
  mkdir "$TASK_RUNTIME" 2>/dev/null || fail "task is already active or has unfinished state: $TASK_ID; use show before choosing a new task id"
  TASK_STATE="$TASK_RUNTIME/state.json"
  TASK_STARTED=1
  write_task_state "preparing" || fail "cannot create task state"
fi

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/bounded-nesting-worker.XXXXXX") || fail "cannot create temporary root"
mkdir -p "$TEMP_ROOT/xdg-data" "$TEMP_ROOT/xdg-state" "$TEMP_ROOT/xdg-cache" "$TEMP_ROOT/xdg-config" "$TEMP_ROOT/tmp" || fail "cannot isolate OpenCode state"
TIMEOUT_MARKER="$TEMP_ROOT/timeout.kind"
create_opencode_config "$MODE"
check_budget

if [ "$MODE" = "smoke" ]; then
  SMOKE_OUTPUT="$TEMP_ROOT/opencode.jsonl"
  SMOKE_ERROR="$TEMP_ROOT/opencode.stderr"
  : > "$SMOKE_OUTPUT"
  if run_opencode "$REPO_ROOT" "$SMOKE_PROMPT" "$SMOKE_OUTPUT" "$SMOKE_ERROR"; then
    SMOKE_STATUS=0
  else
    SMOKE_STATUS=$?
  fi
  [ "$SMOKE_STATUS" -eq 0 ] || fail "smoke execution failed with status $SMOKE_STATUS"
  SMOKE_REPORT=$(extract_report "$SMOKE_OUTPUT")
  [ "$SMOKE_REPORT" = "hello" ] || fail "smoke response must be exactly hello"
  if [ -n "$MODEL_VARIANT" ]; then
    DISPLAY_VARIANT=$MODEL_VARIANT
  else
    DISPLAY_VARIANT=default
  fi
  printf 'smoke: ok model=%s variant=%s\n' "$MODEL" "$DISPLAY_VARIANT"
  exit 0
fi

RESULT_STAGING=$(mktemp -d "$RESULT_PARENT/.$TASK_ID.incomplete.XXXXXX") || fail "cannot create staging result directory"
WORKTREE="$TEMP_ROOT/worktree"
create_bounded_snapshot

NESTING_LIST=$(printf '%s\n' "${NESTING_PATHS[@]}" | sed 's/^/- /')
PROMPT="次の本体コードだけを読み取り専用で検査してください。機能調査、要件判断、設計判断、修正案、コード変更は禁止です。if/else、loop、switch、try/catch/finallyが同じ実行経路で三段階以上重なる候補だけを抽出してください。各候補はfile:line、最大深さ、到達条件、制御構造の順を示してください。else ifは一つの選択、switchのcaseはswitchより深く数えません。候補が無ければ『3段階以上の制御フローネストなし』とだけ明記してください。指定外のファイルを探索・報告しないでください。
対象ファイル:
$NESTING_LIST"

OPENCODE_OUTPUT="$RESULT_STAGING/opencode.jsonl"
OPENCODE_ERROR="$RESULT_STAGING/opencode.stderr"
: > "$OPENCODE_OUTPUT"
STARTED_AT=$(date +%s)
if run_opencode "$WORKTREE" "$PROMPT" "$OPENCODE_OUTPUT" "$OPENCODE_ERROR"; then
  FINAL_STATUS=0
else
  FINAL_STATUS=$?
fi
FINISHED_AT=$(date +%s)
ELAPSED_SECONDS="$((FINISHED_AT - STARTED_AT))"

if ! bounded_snapshot_unchanged; then
  FINAL_STATUS=1
  FAILURE_REASON="read-only delegated model changed a protected path"
fi

REPORT=$(extract_report "$OPENCODE_OUTPUT")
if [ -z "$REPORT" ]; then
  REPORT="Delegated model did not return a final textual report."
  REPORT_STATUS="missing"
  [ "$FINAL_STATUS" -ne 0 ] || FINAL_STATUS=$MISSING_REPORT_STATUS
else
  REPORT_STATUS="complete"
fi
printf '%s\n' "$REPORT" > "$RESULT_STAGING/report.md" || fail "cannot write delegated report"
if [ -f "$TIMEOUT_MARKER" ]; then
  TIMED_OUT=true
  TIMEOUT_KIND=$(sed -n '1p' "$TIMEOUT_MARKER")
else
  TIMED_OUT=false
  TIMEOUT_KIND=""
fi
if [ "$FINAL_STATUS" -eq 0 ]; then
  OUTCOME="fulfilled"
else
  OUTCOME="failed"
fi
jq -n \
  --arg mode "$MODE" \
  --arg task_id "$TASK_ID" \
  --argjson status "$FINAL_STATUS" \
  --arg report_status "$REPORT_STATUS" \
  --arg outcome "$OUTCOME" \
  --arg source_head "$SOURCE_HEAD" \
  --arg source_snapshot "HEAD" \
  --argjson source_worktree_status "$SOURCE_WORKTREE_STATUS_JSON" \
  --argjson timed_out "$TIMED_OUT" \
  --arg timeout_kind "$TIMEOUT_KIND" \
  --argjson hard_timeout_seconds "$HARD_TIMEOUT_SECONDS" \
  --argjson idle_timeout_seconds "$IDLE_TIMEOUT_SECONDS" \
  --argjson timeout_poll_seconds "$TIMEOUT_POLL_SECONDS" \
  --arg timeout_policy_source "$TIMEOUT_POLICY_SOURCE" \
  --arg timeout_reason "$TIMEOUT_REASON" \
  --argjson termination_grace_seconds "$TIMEOUT_TERM_GRACE_SECONDS" \
  --arg model "$MODEL" \
  --arg model_variant "$MODEL_VARIANT" \
  --argjson elapsed_seconds "$ELAPSED_SECONDS" \
  --arg failure_reason "$FAILURE_REASON" \
  '{
    mode:$mode,
    task_id:$task_id,
    status:$status,
    report_status:$report_status,
    outcome:$outcome,
    report_file:"report.md",
    changed_paths:[],
    context_snapshot_paths:[],
    source_head:$source_head,
    source_snapshot:$source_snapshot,
    source_worktree_status:$source_worktree_status,
    timed_out:$timed_out,
    timeout_kind:(if $timeout_kind == "" then null else $timeout_kind end),
    hard_timeout_seconds:$hard_timeout_seconds,
    idle_timeout_seconds:$idle_timeout_seconds,
    timeout_poll_seconds:$timeout_poll_seconds,
    timeout_policy_source:$timeout_policy_source,
    timeout_reason:$timeout_reason,
    termination_grace_seconds:$termination_grace_seconds,
    model:$model,
    model_variant:(if $model_variant == "" then null else $model_variant end),
    elapsed_seconds:$elapsed_seconds,
    failure_reason:(if $failure_reason == "" then null else $failure_reason end)
  }' > "$RESULT_STAGING/result.json" || fail "cannot write result.json"

mv "$RESULT_STAGING" "$RESULT_DIR" || fail "cannot publish worker result"
RESULT_STAGING=""
if [ "$FINAL_STATUS" -eq 0 ]; then
  write_task_state "complete" || fail "cannot complete task state"
else
  write_task_state "failed" || fail "cannot fail task state"
fi
TASK_FINISHED=1

printf 'worker-result:\n'
printf '  task-id: %s\n' "$TASK_ID"
printf '  execution-status: %s\n' "$FINAL_STATUS"
printf '  report: %s\n' "$REPORT_STATUS"
printf '  outcome: %s\n' "$OUTCOME"
printf '  result: %s\n' "$RESULT_DIR"
printf 'report:\n%s\n' "$REPORT"
exit "$FINAL_STATUS"
