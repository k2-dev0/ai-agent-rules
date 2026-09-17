"""Validated native-agent input, independent of encrypted message transport.

Only hooks write state. The sandboxed prepare command must be rewritten by its
PreToolUse hook; without that hook it fails. A task name correlates a request,
never supplies a role. SubagentStart binds the real native role and child id.
"""
import json
import os
from pathlib import Path
import re
import runpy
import secrets
import shlex
import stat
import subprocess
import sys

ROLES = {"code-reviewer"}
HERE = Path(__file__).resolve().parent


def decode(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique)


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def validate(brief, role, root):
    if not isinstance(brief, dict):
        raise ValueError("agent input must be a JSON object")
    if role not in ROLES:
        raise ValueError("unsupported native role")
    keys = {"repository", "review_base", "review_head", "requirements"}
    if set(brief) != keys:
        raise ValueError("agent input must contain only " + ", ".join(sorted(keys)))
    if brief["repository"] != str(root):
        raise ValueError("repository is incorrect")
    if not all(nonempty(v) for v in brief.values()):
        raise ValueError("agent input fields must be non-empty strings")
    if not all(re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", brief[k]) for k in ("review_base", "review_head")):
        raise ValueError("review_base and review_head must be full commit SHAs")
    return brief


def repository(cwd):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_OPTIONAL_LOCKS="0")
    result = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                            env=env, text=True, capture_output=True, check=True)
    return Path(result.stdout.strip())


class State:
    def __init__(self, root, session):
        if not re.fullmatch(r"[A-Za-z0-9._-]+", session):
            raise ValueError("invalid agent session")
        self.root = root
        self.relative = Path(".codex/tmp") / ("agent-input." + session + ".json")
        self.guard = runpy.run_path(str(HERE / "git-policy.py"))
        self.protected = self.guard["metadata_paths"](root)
        self.guard["check_path"](str(self.relative), root, self.protected)

    def read(self):
        descriptor = os.open(str(self.root), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for part in self.relative.parts[:-1]:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
                os.close(descriptor)
                descriptor = child
            file = os.open(self.relative.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=descriptor)
            with os.fdopen(file) as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise ValueError("agent state is linked or not a regular file")
                return decode(stream.read())
        finally:
            os.close(descriptor)

    def save(self, data):
        safe = runpy.run_path(str(HERE / "safe-files.py"))
        safe["replace_file"](self.root, self.relative, json.dumps(data, ensure_ascii=False).encode(),
                             self.guard["check_path"], self.protected, create_parent=True)


def matching(state, inputs, phases):
    data = state.read()
    if data.get("phase") not in phases or inputs.get("agent_type") != data.get("role") or inputs.get("task_name") != data.get("task_name"):
        raise ValueError("no matching prepared native request; run agent-input.py prepare first")
    return data


def brief_from_event(event, root):
    inputs = event["tool_input"]
    role = inputs.get("agent_type")
    raw = inputs.get("prompt", inputs.get("message"))
    if str(inputs.get("task_name", "")).startswith("request_"):
        data = matching(State(root, event.get("session_id", "")), inputs, {"prepared"})
        try:
            plain = decode(raw)
        except (ValueError, TypeError):
            plain = data["brief"]
        if plain != data["brief"]:
            raise ValueError("message differs from the prepared request")
        return validate(data["brief"], role, root)
    try:
        brief = decode(raw)
    except (ValueError, TypeError):
        state = State(root, event.get("session_id", ""))
        brief = matching(state, inputs, {"prepared"})["brief"]
    return validate(brief, role, root)


def preparation(event, root):
    raw = event.get("tool_input", {}).get("command", "")
    # Ignore ordinary commands, including readers of this source file.
    try:
        argv = shlex.split(raw)
    except ValueError:
        return None
    paths = {".codex/hooks/shell/agent-input.py", str(root / ".codex/hooks/shell/agent-input.py")}
    if len(argv) < 3 or argv[0] != "python3" or argv[1] not in paths or argv[2] != "prepare":
        return None
    guard = runpy.run_path(str(HERE / "git-policy.py"))
    guard["single_command"](raw)
    if len(argv) != 5 or argv[3] not in ROLES:
        raise ValueError("usage: python3 .codex/hooks/shell/agent-input.py prepare <role> '<JSON>'")
    role = argv[3]
    brief = validate(decode(argv[4]), role, root)
    return role, brief


def prepare_hook(event, root):
    request = preparation(event, root)
    if request is None:
        return
    role, brief = request
    state = State(root, event.get("session_id", ""))
    try:
        previous = state.read()
    except FileNotFoundError:
        previous = {}
    if previous.get("phase") == "bound":
        raise ValueError("wait for the active native agent before preparing another request")
    token = secrets.token_hex(16)
    data = {"phase": "prepared", "role": role, "task_name": "request_" + token, "brief": brief}
    state.save(data)
    command = shlex.join(["python3", str(root / ".codex/hooks/shell/agent-input.py"), "emit", event["session_id"], token])
    print(command)


def main(args):
    operation = args[0] if args else ""
    if operation == "prepare":
        raise ValueError("preparation hook did not run; check project trust and hooks before continuing")
    if operation == "emit" and len(args) == 3:
        root = repository(os.getcwd())
        data = State(root, args[1]).read()
        if data.get("phase") != "prepared" or data.get("task_name") != "request_" + args[2]:
            raise ValueError("prepared request is unavailable or already consumed")
        print(json.dumps({"agent_type": data["role"], "task_name": data["task_name"], "fork_turns": "none", "message": json.dumps(data["brief"], ensure_ascii=False)}, ensure_ascii=False))
        return
    event = decode(sys.stdin.read())
    root = repository(event.get("cwd") or os.getcwd())
    if operation == "guard-command":
        # This exact fixed entry only prepares data. Do not interpret words in
        # its validated JSON argument as shell operations in the tripwire hooks.
        # A nonzero result makes hook_command retain its original processing,
        # including outside.sh extraction. Failure never disables a guard.
        request = preparation(event, root)
        if request is None:
            raise ValueError('not a validated preparation entry')
        print(shlex.join(['python3', str(root / '.codex/hooks/shell/agent-input.py'), 'prepare']))
        return
    if operation == "brief":
        print(json.dumps(brief_from_event(event, root), ensure_ascii=False))
        return
    if operation == "reserve" and len(args) == 2:
        inputs = event["tool_input"]
        role = inputs["agent_type"]
        brief = decode(args[1])
        state = State(root, event.get("session_id", ""))
        try:
            previous = state.read()
        except FileNotFoundError:
            previous = {}
        if previous.get("phase") == "bound":
            raise ValueError("a native agent is still active")
        # Opaque transport can only select an existing, unused prepared request.
        try:
            decode(inputs.get("message", inputs.get("prompt")))
        except (ValueError, TypeError):
            matching(state, inputs, {"prepared"})
        state.save({"phase": "reserved", "role": role, "task_name": inputs.get("task_name"), "brief": brief})
        return
    if operation == "bind":
        state = State(root, event.get("session_id", ""))
        data = state.read()
        if data.get("phase") != "reserved" or event.get("agent_type") != data.get("role") or not nonempty(event.get("agent_id")):
            raise ValueError("native child does not match the validated request")
        data.update(phase="bound", child_id=event["agent_id"])
        state.save(data)
        print(json.dumps(data["brief"], ensure_ascii=False))
        return
    if operation == "hook":
        if event.get("hook_event_name") == "PreToolUse":
            prepare_hook(event, root)
        elif event.get("hook_event_name") == "SubagentStop" and event.get("agent_type") in ROLES:
            state = State(root, event.get("session_id", ""))
            try:
                data = state.read()
            except FileNotFoundError:
                return
            if data.get("phase") != "bound" or data.get("child_id") != event.get("agent_id") or data.get("role") != event.get("agent_type"):
                return
            data["phase"] = "complete"
            state.save(data)
        return
    raise ValueError("unknown agent-input operation")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        raise SystemExit(2)
