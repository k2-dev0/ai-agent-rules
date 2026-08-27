#!/bin/bash
# implementation scopeのreceipt path・lease判定をhookとskillで共有する。

implementation_scope_init() {
  IMPLEMENTATION_REPOSITORY=$1
  IMPLEMENTATION_REPOSITORY_KEY=$(printf '%s' "$IMPLEMENTATION_REPOSITORY" | cksum | awk '{ print $1 }')
  IMPLEMENTATION_RECEIPT_DIR="${TMPDIR:-/tmp}/polish-quality-gate/$IMPLEMENTATION_REPOSITORY_KEY"
  IMPLEMENTATION_ACTIVE_DIR="$IMPLEMENTATION_RECEIPT_DIR/implementation.active"
  IMPLEMENTATION_ACTIVE_SCOPE="$IMPLEMENTATION_ACTIVE_DIR/scope"
  IMPLEMENTATION_ACTIVE_MODE="$IMPLEMENTATION_ACTIVE_DIR/mode"
  IMPLEMENTATION_ACTIVE_REQUEST="$IMPLEMENTATION_ACTIVE_DIR/request.json"
  IMPLEMENTATION_ACTIVE_LEASE="$IMPLEMENTATION_ACTIVE_DIR/lease"
  IMPLEMENTATION_OWNER_FILE="$IMPLEMENTATION_RECEIPT_DIR/implementation.owner"
  IMPLEMENTATION_RECOVERY_OWNER_FILE="$IMPLEMENTATION_RECEIPT_DIR/implementation.recovery-owner"
}

implementation_scope_stale_seconds() {
  case "${POLISH_SCOPE_STALE_SECONDS:-3600}" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "${POLISH_SCOPE_STALE_SECONDS:-3600}" ;;
  esac
}

implementation_scope_file_mtime() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
}

implementation_scope_lease_age() {
  local now
  local timestamp

  now=$(date +%s) || return 1
  if [ -f "$IMPLEMENTATION_ACTIVE_LEASE" ]; then
    timestamp=$(sed -n '1p' "$IMPLEMENTATION_ACTIVE_LEASE") || return 1
    case "$timestamp" in ''|*[!0-9]*) return 1 ;; esac
  else
    [ -f "$IMPLEMENTATION_ACTIVE_SCOPE" ] || return 1
    timestamp=$(implementation_scope_file_mtime "$IMPLEMENTATION_ACTIVE_SCOPE") || return 1
  fi
  if [ "$timestamp" -gt "$now" ]; then
    printf '0\n'
  else
    printf '%s\n' "$((now - timestamp))"
  fi
}

implementation_scope_is_stale() {
  local age
  local stale_seconds

  age=$(implementation_scope_lease_age) || return 1
  stale_seconds=$(implementation_scope_stale_seconds) || return 1
  [ "$age" -ge "$stale_seconds" ]
}

implementation_scope_touch_lease() {
  local temporary_lease

  [ -d "$IMPLEMENTATION_ACTIVE_DIR" ] || return 1
  temporary_lease="$IMPLEMENTATION_ACTIVE_LEASE.tmp.$$"
  if ! date +%s > "$temporary_lease"; then
    rm -f "$temporary_lease"
    return 1
  fi
  if ! mv "$temporary_lease" "$IMPLEMENTATION_ACTIVE_LEASE"; then
    rm -f "$temporary_lease"
    return 1
  fi
}
