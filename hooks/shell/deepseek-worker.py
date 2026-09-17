"""Reserve the worktree across asynchronous MCP turns; trust matched tool results only."""
import fcntl
import json
import os
from pathlib import Path
import re
import runpy
import stat
import subprocess
import sys

HERE = Path(__file__).resolve().parent
WORKER = re.compile(r"^mcp__deepseek[-_]worker__(start_task|continue_task|wait_task|abort_task)$")
EXCLUSIVE = re.compile(r"^(Bash|exec_command|apply_patch|Edit|Write|MultiEdit|NotebookEdit|Agent)$|(^|[._])spawn_agent$|^collaborationspawn_agent$")
TERMINAL = {"completed", "needs_decision", "failed", "aborted", "interrupted"}
STOPPED_ERRORS = {"configuration_error", "privacy_configuration_error", "authentication_error",
                  "transport_error", "harness_start_error", "harness_protocol_error",
                  "model_error", "task_contract_error", "internal_error"}


def regular(fd):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError("worker state is linked or not a regular file")


def response(value):
    if isinstance(value, str):
        value = json.loads(value)
    if not isinstance(value, dict) or value.get("isError"):
        raise ValueError("worker response unavailable; execution stop is unconfirmed")
    if "structuredContent" in value:
        value = value["structuredContent"]
    elif "content" in value:
        parts = [p["text"] for p in value["content"] if p.get("type") == "text"]
        if len(parts) != 1:
            raise ValueError("worker response must contain one JSON result")
        value = json.loads(parts[0])
    if not isinstance(value, dict) or not isinstance(value.get("task_id"), str) or not value["task_id"].strip():
        raise ValueError("worker task identity is missing")
    if value.get("status") not in TERMINAL | {"running"}:
        raise ValueError("worker status is unknown")
    error = value.get("error")
    if isinstance(error, dict) and error.get("class") == "abort_error":
        raise ValueError("worker cleanup failed; execution stop is unconfirmed")
    if value["status"] == "failed" and (not isinstance(error, dict) or error.get("class") not in STOPPED_ERRORS):
        raise ValueError("worker failure does not confirm execution stopped")
    return value


def transition(data, event, action):
    owner = event.get("session_id")
    if not isinstance(owner, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", owner):
        raise ValueError("worker owner session is missing")
    inputs = event.get("tool_input", {})
    if event["hook_event_name"] == "PreToolUse":
        if not isinstance(inputs, dict):
            raise ValueError("worker input must be an object")
        required = "brief" if action == "start_task" else "task_id"
        if not isinstance(inputs.get(required), str) or not inputs[required].strip():
            raise ValueError("worker input is missing " + required)
        if action == "continue_task" and (not isinstance(inputs.get("message"), str) or not inputs["message"].strip()):
            raise ValueError("worker continuation message is missing")
        if action in ("start_task", "continue_task"):
            if data.get("busy"):
                raise ValueError("DeepSeek is active; wait for its completion before starting or continuing work")
            call_id = event.get("tool_use_id")
            if not isinstance(call_id, str) or not call_id:
                raise ValueError("worker tool call identity is missing")
            return {"busy": True, "owner": owner, "call_id": call_id,
                    "task_id": inputs.get("task_id") if action == "continue_task" else None, "observations": {}}
        if data.get("busy") and (data.get("owner") != owner or
                                (data.get("task_id") and inputs.get("task_id") != data["task_id"])):
            raise ValueError("wait/abort must target the active worker of this Codex task")
        if data.get("busy"):
            call_id = event.get("tool_use_id")
            if not isinstance(call_id, str) or not call_id:
                raise ValueError("worker observation identity is missing")
            return {**data, "observations": {**data.get("observations", {}), call_id: action}}
        return data
    if not data.get("busy"):
        return data
    if data.get("owner") != owner:
        raise ValueError("worker result owner does not match")
    if action in ("start_task", "continue_task"):
        if data.get("call_id") != event.get("tool_use_id"):
            raise ValueError("worker result call does not match")
    else:
        if not data.get("task_id") or inputs.get("task_id") != data["task_id"]:
            raise ValueError("worker result cannot release an unidentified task")
        if data.get("observations", {}).get(event.get("tool_use_id")) != action:
            raise ValueError("worker observation belongs to an earlier run or was not started")
    result = response(event.get("tool_response"))
    if data.get("task_id") and result["task_id"] != data["task_id"]:
        raise ValueError("worker result task does not match")
    observations = dict(data.get("observations", {}))
    observations.pop(event.get("tool_use_id"), None)
    return {**data, "task_id": result["task_id"], "busy": result["status"] == "running", "observations": observations}


def handle(event):
    name = event.get("tool_name", "")
    match = WORKER.fullmatch(name)
    pre = event.get("hook_event_name") == "PreToolUse"
    if not match and (not pre or not EXCLUSIVE.search(name)):
        return
    helper = runpy.run_path(str(HERE / "agent-input.py"))
    root = helper["repository"](event.get("cwd") or os.getcwd())
    if pre and match and match[1] in ("start_task", "continue_task"):
        head = subprocess.run(["git", "-C", str(root), "rev-parse", "--verify", "HEAD"],
                              capture_output=True, text=True)
        if head.returncode:
            raise ValueError("create an initial commit before starting DeepSeek; review baseline is unavailable")
    safe = runpy.run_path(str(HERE / "safe-files.py"))
    guard = safe["load_path_guard"]()
    protected = guard["metadata_paths"](root)
    relative = Path(".codex/tmp/deepseek-worker.json")
    guard["check_path"](str(relative), root, protected)
    # Open each directory without following aliases, then serialize hook updates.
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in relative.parts[:-1]:
            try:
                os.mkdir(component, dir_fd=fd)
            except FileExistsError:
                pass
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        lock = os.open("deepseek-worker.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        try:
            regular(lock)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                state_fd = os.open(relative.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
                with os.fdopen(state_fd) as stream:
                    regular(stream.fileno())
                    data = json.load(stream)
                if not isinstance(data, dict) or type(data.get("busy")) is not bool:
                    raise ValueError("worker state is invalid")
            except FileNotFoundError:
                data = {"busy": False}
            if not match:
                if data["busy"]:
                    raise ValueError("DeepSeek is active; parent shell/edit/commit/reviewer must wait for completion")
                return
            updated = transition(data, event, match[1])
            if updated != data:
                safe["replace_file"](root, relative, json.dumps(updated).encode(), guard["check_path"], protected)
        finally:
            os.close(lock)
    finally:
        os.close(fd)


if __name__ == "__main__":
    event = {}
    try:
        event = json.load(sys.stdin)
        handle(event)
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(json.dumps({"error": str(error)}))
