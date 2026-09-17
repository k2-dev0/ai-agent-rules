"""Real stdio bridge + DSH + distributed hooks, against a local simulated API.

Run outside the enclosing sandbox with the bridge's Python:
  <bridge>/.venv/bin/python tests/probe_deepseek_bridge.py --bridge-root <bridge>
No real API key is read. Only disposable worktrees and local state are used.
"""
import argparse
import asyncio
import importlib
import json
import os
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
from test_deepseek_worker import Worker


async def scenario(bridge_root, endpoint, fail_cleanup=False):
    fixture = Worker()
    fixture.setUp()
    process = None
    with tempfile.TemporaryDirectory(prefix="bridge-integration-state-") as state:
        # Redirect storage, not the SDK, runtime, transport, or task lifecycle.
        launch = ("from pathlib import Path\nfrom deepseek_bridge import privacy, server, runtime\n"
                  + "privacy.user_state_path = lambda *a, **k: Path(" + repr(state) + ")\n")
        if fail_cleanup:
            # Prove that an ambiguous cleanup result never unlocks the parent.
            # Reap the real process before fault injection to leave no orphan.
            launch += ("original = runtime.Runtime.close\nfailed = False\n"
                       "def close(self):\n global failed\n original(self)\n"
                       " if not failed:\n  failed = True\n  raise RuntimeError('injected cleanup failure')\n"
                       "runtime.Runtime.close = close\n")
        launch += "server.main()\n"
        env = {**os.environ, "DEEPSEEK_API_KEY": "wire-only-canary-" + "a" * 24,
               "DEEPSEEK_BASE_URL": endpoint["url"],
               "PYTHONPATH": str(bridge_root / "src"), "PYTHONDONTWRITEBYTECODE": "1"}
        try:
            process = await asyncio.create_subprocess_exec(
                "bash", str(fixture.hooks / "deepseek-launch.sh"), sys.executable, "-c", launch,
                cwd=fixture.root, env=env, stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
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
                    assert raw, "bridge closed its output"
                    result = json.loads(raw)
                    if result.get("id") == request:
                        assert "error" not in result, result
                        return result["result"]

            async def tool(name, expect_block=False, **inputs):
                call_id = "integration-" + str(request + 1)
                before = fixture.call(name, call_id=call_id, **inputs)
                assert not before, before
                result = await rpc("tools/call", {"name": name, "arguments": inputs})
                after = fixture.call(name, event="PostToolUse", call_id=call_id, result=result, **inputs)
                if expect_block:
                    assert after and after[0].get("continue") is False, after
                else:
                    assert not after, after
                return result["structuredContent"]

            await rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                     "clientInfo": {"name": "rules-integration", "version": "1"}})
            await rpc("notifications/initialized", {}, notify=True)
            listed = await rpc("tools/list", {})
            assert {t["name"] for t in listed["tools"]} == {
                "start_task", "wait_task", "continue_task", "abort_task"}
            if fail_cleanup:
                endpoint["mode"] = 401
                task = await tool("start_task", brief="Exercise the cleanup failure boundary")
                result = await tool("wait_task", expect_block=True, task_id=task["task_id"], timeout_ms=15000)
                assert result["status"] == "failed" and result["error"]["class"] == "abort_error"
                assert json.loads(fixture.state.read_text())["busy"]
                fixture.denied(fixture.call("Bash", command="git add code.txt"))
                return

            endpoint["mode"] = "tool"
            # The real DSH shell edits a file, runs its test, and encounters the
            # real OS denial when attempting to write protected Git metadata.
            body = ("from pathlib import Path; import unittest; "
                    "Path('sample.py').write_text('VALUE = 42\\n'); "
                    "Path('test_sample.py').write_text('import unittest\\nfrom sample import VALUE\\n"
                    "class Test(unittest.TestCase):\\n def test_value(self): self.assertEqual(VALUE,42)\\n')")
            import shlex
            endpoint["command"] = (shlex.quote(sys.executable) + " -c " + shlex.quote(body)
                                   + "; " + shlex.quote(sys.executable) + " -m unittest -v test_sample"
                                   + "; printf forbidden > .git/worker-write-sentinel")
            task = await tool("start_task", brief="Run the bounded integration fixture")
            fixture.denied(fixture.call("apply_patch", command="patch"))
            result = await tool("wait_task", task_id=task["task_id"], timeout_ms=20000)
            assert result["status"] == "completed", result
            assert (fixture.root / "sample.py").read_text() == "VALUE = 42\n"
            assert not (fixture.root / ".git/worker-write-sentinel").exists()
            observed = json.dumps(endpoint["requests"][-1]["messages"])
            assert "Ran 1 test" in observed and "OK" in observed
            assert "Operation not permitted" in observed or "Permission denied" in observed
            assert json.loads(fixture.review.read_text())["base"] == fixture.base
            endpoint["mode"] = "ok"
            continued = await tool("continue_task", task_id=task["task_id"], message="Confirm the existing result")
            assert continued["session_id"] == task["session_id"]
            assert (await tool("wait_task", task_id=task["task_id"], timeout_ms=15000))["status"] == "completed"
            endpoint["mode"] = 401
            task = await tool("start_task", brief="Exercise authentication failure")
            result = await tool("wait_task", task_id=task["task_id"], timeout_ms=15000)
            assert result["error"]["class"] == "authentication_error"
            assert not json.loads(fixture.state.read_text())["busy"]
            endpoint["mode"] = "slowtool"
            endpoint["command"] = "printf '%s\\n' $$ > shell.pid; sleep 120"
            task = await tool("start_task", brief="Exercise real shell cancellation")
            marker = fixture.root / "shell.pid"
            for _ in range(200):
                if marker.exists():
                    break
                await asyncio.sleep(0.05)
            assert marker.exists(), "real shell did not start"
            pid = int(marker.read_text())
            assert (await tool("abort_task", task_id=task["task_id"]))["status"] == "aborted"
            assert not json.loads(fixture.state.read_text())["busy"]
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError("aborted shell is still alive")
            assert all("dsh_session_log" not in p and "dsh_plugin_packages" not in p
                       for p in endpoint["requests"])
        finally:
            if process is not None:
                process.stdin.close()
                try:
                    await asyncio.wait_for(process.wait(), 10)
                except TimeoutError:
                    process.kill()
                    await process.wait()
                stderr = await process.stderr.read()
                assert env["DEEPSEEK_API_KEY"].encode() not in stderr
            fixture.doCleanups()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge-root", type=Path, required=True)
    args = parser.parse_args()
    root = args.bridge_root.resolve(strict=True)
    sys.path.insert(0, str(root / "src"))
    sys.path.insert(0, str(root / "tests"))
    # Use the bridge's tested SSE fixture; only the external model is simulated.
    wire = importlib.import_module("test_privacy_wire")
    fixture = wire.endpoint.__wrapped__()
    endpoint = next(fixture)
    try:
        asyncio.run(scenario(root, endpoint))
        print("PASS real MCP/DSH + protected edit/test + continuation/error/abort")
        asyncio.run(scenario(root, endpoint, fail_cleanup=True))
        print("PASS cleanup failure retains parent writer restriction")
    finally:
        try:
            next(fixture)
        except StopIteration:
            pass


if __name__ == "__main__":
    main()
