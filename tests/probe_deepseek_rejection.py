"""Real stdio bridge start_task rejection + manual hook delivery connection.

Run with the bridge's Python from this repository:
  <bridge>/.venv/bin/python tests/probe_deepseek_rejection.py --bridge-root <bridge>

A disposable Worker worktree and an isolated privacy user state are used to
start a fresh real bridge stdio MCP server (PYTHONPATH points at <bridge>/src;
only ``privacy.user_state_path`` is redirected). The probe sends a non-empty
brief with a 201-character title, which the real ``StartInput`` validation
rejects before any runtime start, so no API request is made or needed. The
synthetic API key is set only inside the child environment and is never
printed; the base URL is a loopback discard address. The Pre/Post hooks are
delivered by this probe itself, so a pass proves the real MCP rejection and the
hook release contract connect; it does not prove Codex automatic hook delivery.
Bridge stderr, stdin payloads and environment values are not printed. The
server source hash is reported for diagnostics. The child process is always
terminated before this probe exits.
"""

import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
from test_deepseek_worker import Worker

TITLE_LENGTH = 201
SERVER_SOURCE = Path("src/deepseek_bridge/server.py")


def server_source_hash(bridge_root):
    source = bridge_root / SERVER_SOURCE
    return hashlib.sha256(source.read_bytes()).hexdigest()


async def scenario(bridge_root, state, fake_key):
    fixture = Worker()
    process = None
    try:
        fixture.setUp()
        launch = ("from pathlib import Path\n"
                  "from deepseek_bridge import privacy\n"
                  "privacy.user_state_path = lambda *a, **k: Path(" + repr(state) + ")\n"
                  "from deepseek_bridge import server\n"
                  "server.main()\n")
        env = {**os.environ, "DEEPSEEK_API_KEY": fake_key,
               "DEEPSEEK_BASE_URL": "http://127.0.0.1:9",
               "PYTHONPATH": str(bridge_root / "src"), "PYTHONDONTWRITEBYTECODE": "1",
               "PWD": str(fixture.root)}
        process = await asyncio.create_subprocess_exec(
            sys.executable, "-c", launch, cwd=str(fixture.root), env=env,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE)
        request = 0

        async def rpc(method, params, notify=False):
            nonlocal request
            request += 1
            message = {"jsonrpc": "2.0", "method": method, "params": params}
            if not notify:
                message["id"] = request
            process.stdin.write((json.dumps(message) + "\n").encode())
            await process.stdin.drain()
            if notify:
                return None
            while True:
                raw = await asyncio.wait_for(process.stdout.readline(), 30)
                assert raw, "bridge closed its output before the response"
                result = json.loads(raw)
                if result.get("id") == request:
                    assert "error" not in result, "MCP call failed at the protocol level"
                    return result["result"]

        await rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                 "clientInfo": {"name": "rules-rejection-probe", "version": "1"}})
        await rpc("notifications/initialized", {}, notify=True)
        listed = await rpc("tools/list", {})
        assert {tool["name"] for tool in listed["tools"]} == {
            "start_task", "wait_task", "continue_task", "abort_task"}, "bridge tool set differs"

        brief = "Reject a title one character over the StartInput limit"
        title = "x" * TITLE_LENGTH
        call_id = "rejection-1"
        assert not fixture.call("start_task", call_id=call_id, brief=brief, title=title), "Pre hook must reserve"
        pending = json.loads(fixture.state.read_text())
        assert pending == {"busy": True, "owner": "TEST", "call_id": call_id,
                           "task_id": None, "observations": {}}, "Pre reservation marker differs"
        fixture.denied(fixture.call("Bash", command="git status --short"))

        result = await rpc("tools/call", {"name": "start_task",
                                          "arguments": {"brief": brief, "title": title}})
        assert result.get("isError") is True, "real bridge did not flag the input rejection"
        assert set(result) <= {"content", "isError", "_meta"}, sorted(result)
        content = result.get("content")
        assert isinstance(content, list) and len(content) == 1, "rejection must carry one content item"
        part = content[0]
        assert isinstance(part, dict) and part.get("type") == "text", "rejection content must be text"
        payload = json.loads(part["text"])
        assert payload["class"] == "configuration_error", "rejection class differs"
        assert payload["rejection"] == "input_validation", "new rejection marker is missing"
        assert payload["execution_started"] is False, "rejection must not have started execution"
        assert isinstance(payload["message"], str) and payload["message"], "rejection message is missing"
        assert "task_id" not in json.dumps(result), "rejection must not issue a task id"
        assert json.loads(fixture.state.read_text())["busy"] is True, \
            "hook released before the result was delivered"

        assert not fixture.call("start_task", event="PostToolUse", call_id=call_id,
                                result=result, brief=brief, title=title), "Post delivery must be accepted"
        released = json.loads(fixture.state.read_text())
        assert released == {"busy": False, "owner": "TEST", "call_id": call_id,
                            "task_id": None, "observations": {}}, "release marker differs"
        assert not fixture.call("Bash", command="git status --short"), "parent Bash must be allowed again"
    finally:
        if process is not None:
            try:
                process.stdin.close()
            except (BrokenPipeError, OSError):
                pass
            try:
                await asyncio.wait_for(process.wait(), 10)
            except TimeoutError:
                process.kill()
                await process.wait()
            stderr = await process.stderr.read()
            assert fake_key.encode() not in stderr, "synthetic API key leaked to bridge stderr"
        fixture.doCleanups()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge-root", type=Path, required=True)
    args = parser.parse_args()
    root = args.bridge_root.resolve(strict=True)
    digest = server_source_hash(root)
    fake_key = "probe-rejection-" + "c" * 24
    try:
        with tempfile.TemporaryDirectory(prefix="deepseek-rejection-state-") as state:
            asyncio.run(scenario(root, state, fake_key))
    except Exception:
        print("FAIL real MCP start_task rejection / manual hook delivery connection check; "
              f"bridge {SERVER_SOURCE} sha256={digest}", file=sys.stderr)
        raise
    print("PASS real MCP start_task rejection + manual hook delivery connection verified "
          "(delivered by this probe, not automatic hook delivery)")
    print(f"diagnostics: bridge {SERVER_SOURCE} sha256={digest}")


if __name__ == "__main__":
    main()
