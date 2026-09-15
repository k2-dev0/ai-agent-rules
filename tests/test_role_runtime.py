"""Opt-in native Codex role integration with a local simulated Responses API.

Run outside the enclosing sandbox (loopback HTTP). No external model is called.
The real tool schema, spawn handler and thread metadata are tested, not an LLM's
judgment. Project config and a temporary per-process Codex home are used; the
user's settings and history are not modified. --probe-permissions is a separate
strict diagnostic, not part of the role-identity success criteria.
"""
import http.server
import json
import os
from pathlib import Path
import queue
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
ROLES = {
    "difficulty-evaluator": ("gpt-6-astra", "medium"),
    "code-reviewer": ("gpt-5.6-sol", "high"),
    "deep-reviewer": ("gpt-6-astra", "xhigh"),
    "design-reviewer": ("gpt-6-astra", "xhigh"),
    "nesting-reviewer": ("gpt-5.6-luna", "max"),
}

def toml(value):
    if isinstance(value, dict):
        return '{' + ','.join(json.dumps(k)+'='+toml(v) for k,v in value.items()) + '}'
    if isinstance(value, list):
        return '['+','.join(toml(v) for v in value)+']'
    return json.dumps(value)


def find_spawn_schema(value):
    if isinstance(value, dict):
        if value.get("type") == "function" and value.get("name") == "spawn_agent":
            return value
        for nested in value.values():
            found = find_spawn_schema(nested)
            if found:
                return found
    elif isinstance(value, list):
        for nested in value:
            found = find_spawn_schema(nested)
            if found:
                return found


class RoleRuntime(unittest.TestCase):
    def run_fixture(self, role, probe_permissions=False):
        self.assertIsNotNone(shutil.which("codex"))
        with tempfile.TemporaryDirectory(prefix="role-runtime-") as directory:
            base = Path(directory).resolve()
            root = base / 'project with spaces'
            root.mkdir()
            fixture_home = base / 'codex-runtime'
            fixture_home.mkdir()
            # Use Codex's supported per-process home setting, without changing
            # the caller's environment or configuration. Durable fixture threads
            # are required for SubagentStart/Stop transcript-backed hooks.
            environment = dict(os.environ, CODEX_HOME=str(fixture_home))
            catalog = Path(os.environ.get('CODEX_HOME', str(Path.home()/'.codex'))) / 'models_cache.json'
            if catalog.is_file():
                shutil.copyfile(catalog, fixture_home/'models_cache.json')
            shutil.copytree(REPO / "codex/agents", root / ".codex/agents")
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / '.codex/config.toml').write_text((REPO / 'codex/config.toml').read_text().split('[mcp_servers.', 1)[0])
            requests = []
            parent_requests = 0
            child_requests_count = 0
            class Handler(http.server.BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass

                def do_GET(self):
                    # Keep the installed runtime's cached model capabilities;
                    # this fixture supplies no substitute capability catalog.
                    self.send_response(404)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(b'{"error":{"message":"fixture has no model catalog"}}')

                def do_POST(self):
                    nonlocal parent_requests, child_requests_count
                    body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    requests.append(body)
                    telemetry = json.loads(body.get("client_metadata", {}).get("x-codex-turn-metadata", "{}"))
                    is_parent = not telemetry.get("parent_thread_id")
                    if is_parent:
                        parent_requests += 1
                    else:
                        child_requests_count += 1
                    number = len(requests)
                    if is_parent and parent_requests == 1 and probe_permissions:
                        item = dict(type="function_call", id="parent-write", call_id="parent-write", namespace="functions", name="exec_command", arguments=json.dumps(dict(cmd="touch " + shlex.quote(str(root / "parent-write")), workdir=str(root))))
                    elif is_parent and parent_requests == (2 if probe_permissions else 1):
                        args = dict(task_name="role_probe", agent_type=role, fork_turns="none",
                                    message=json.dumps(dict(repository=str(root), implementation_policy="Fixture transport only.")))
                        item = dict(type="function_call", id="spawn", call_id="spawn", namespace="collaboration", name="spawn_agent", arguments=json.dumps(args))
                    elif is_parent and parent_requests == (3 if probe_permissions else 2):
                        item = dict(type="function_call", id="wait", call_id="wait", namespace="collaboration", name="wait_agent", arguments='{"timeout_ms":10000}')
                    elif not is_parent and child_requests_count == 1 and probe_permissions:
                        item = dict(type="function_call", id="child-write", call_id="child-write", namespace="functions", name="exec_command", arguments=json.dumps(dict(cmd="touch " + shlex.quote(str(root / "child-write")), workdir=str(root))))
                    else:
                        item = dict(type="message", id="msg" + str(number), role="assistant", content=[dict(type="output_text", text="Fixture transport complete.", annotations=[])])
                    response = dict(id="response" + str(number), object="response", status="completed", output=[item], usage=dict(input_tokens=1, output_tokens=1, total_tokens=2))
                    events = [dict(type="response.created", response={**response, "status":"in_progress", "output":[]}),
                              dict(type="response.output_item.added", output_index=0, item=item),
                              dict(type="response.output_item.done", output_index=0, item=item),
                              dict(type="response.completed", response=response)]
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    for event in events:
                        self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())

            with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
                threading.Thread(target=server.serve_forever, daemon=True).start()
                settings = {
                    "model_provider":"fixture", "model":"gpt-5.6-sol", "model_reasoning_effort":"high",
                    "approval_policy":"never", "sqlite_home":str(root / "sqlite"), "web_search":"disabled",
                    "features.apps":False, "features.plugins":False, "features.hooks":False,
                    "features.multi_agent":True, "features.code_mode":False,
                    "features.enable_request_compression":False, "mcp_servers":{}, "hooks":{},
                    "agents.enabled":True,
                    "projects":{str(root):{"trust_level":"trusted"}},
                    "model_providers.fixture.name":"fixture",
                    "model_providers.fixture.base_url":f"http://127.0.0.1:{server.server_port}/v1",
                    "model_providers.fixture.wire_api":"responses",
                    "model_providers.fixture.requires_openai_auth":False,
                    "model_providers.fixture.request_max_retries":0,
                    "model_providers.fixture.stream_max_retries":0,
                }
                (fixture_home / 'config.toml').write_text('\n'.join(key+'='+toml(value) for key,value in settings.items())+'\n')
                messages = queue.Queue()
                with (root / "stderr.log").open("w") as stderr:
                    process = subprocess.Popen(["codex", "app-server", "--strict-config"], cwd=root, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True)
                    def receive():
                        for line in process.stdout:
                            messages.put(json.loads(line))
                        messages.put({"process_exited": True})
                    threading.Thread(target=receive, daemon=True).start()
                    next_id = 0
                    notifications = []
                    def rpc(method, params):
                        nonlocal next_id
                        next_id += 1
                        request_id = next_id
                        process.stdin.write(json.dumps(dict(id=request_id, method=method, params=params)) + "\n")
                        process.stdin.flush()
                        deadline = time.monotonic() + 40
                        while True:
                            message = messages.get(timeout=max(0.1, deadline-time.monotonic()))
                            if message.get("process_exited"):
                                raise AssertionError((root / "stderr.log").read_text())
                            if message.get("id") == request_id:
                                self.assertNotIn("error", message, message)
                                return message["result"]
                            notifications.append(message)
                    try:
                        rpc("initialize", dict(clientInfo=dict(name="role-runtime-test", version="1"), capabilities=dict(experimentalApi=True)))
                        process.stdin.write('{"method":"initialized"}\n')
                        process.stdin.flush()
                        started = rpc("thread/start", dict(cwd=str(root), ephemeral=False))
                        parent = started["thread"]["id"]
                        rpc("turn/start", dict(threadId=parent, input=[dict(type="text", text="Run only the isolated transport fixture.", text_elements=[])]))
                        deadline = time.monotonic() + 40
                        while not any(n.get("method") == "turn/completed" and n.get("params", {}).get("threadId") == parent for n in notifications):
                            notifications.append(messages.get(timeout=max(0.1, deadline-time.monotonic())))
                        self.assertTrue(requests)
                        schema = find_spawn_schema(requests[0])
                        def names(value):
                            if isinstance(value, dict):
                                return ([value['name']] if isinstance(value.get('name'), str) else []) + [n for v in value.values() for n in names(v)]
                            if isinstance(value, list):
                                return [n for v in value for n in names(v)]
                            return []
                        self.assertIsNotNone(schema, dict(model=requests[0]['model'], keys=list(requests[0]), names=names(requests[0])))
                        self.assertIn("agent_type", schema["parameters"]["properties"])
                        advertised = schema["parameters"]["properties"]["agent_type"]["description"]
                        for name in ROLES:
                            self.assertIn(name + ":", advertised)
                        child_requests = [r for r in requests if json.loads(r.get("client_metadata", {}).get("x-codex-turn-metadata", "{}")).get("parent_thread_id")]
                        self.assertTrue(child_requests, [x for r in requests for x in r["input"] if x.get("type") == "function_call_output"])
                        child_request = child_requests[0]
                        metadata = json.loads(child_request["client_metadata"]["x-codex-turn-metadata"])
                        child = rpc("thread/read", dict(threadId=metadata["thread_id"], includeTurns=False))["thread"]
                        self.assertEqual(child["agentRole"], role)
                        self.assertEqual(child["source"]["subAgent"]["thread_spawn"]["agent_role"], role)
                        self.assertEqual((child_request["model"], child_request["reasoning"]["effort"]), ROLES[role])
                        result = dict(role=child["agentRole"], model=child_request["model"], effort=child_request["reasoning"]["effort"])
                        if probe_permissions:
                            self.assertTrue((root / "parent-write").exists(), "parent fixture must be writable")
                            self.assertFalse((root / "child-write").exists(), "runtime ignored the role read-only setting")
                            child_outputs = [str(x.get('output','')) for r in child_requests for x in r['input'] if x.get('type') == 'function_call_output' and x.get('call_id') == 'child-write']
                            self.assertTrue(any(re.search(r'(?i)not permitted|permission denied|read.only|reject|denied', output) for output in child_outputs), child_outputs)
                            result['child_write_denied'] = True
                        return result
                    finally:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
                        process.stdin.close()
                        process.stdout.close()
                        server.shutdown()

    def test_every_distributed_role_is_registered(self):
        text = (REPO/'codex/config.toml').read_text()
        entries = dict(re.findall(r'(?m)^\[agents\.([^\]]+)\]\s*\nconfig_file\s*=\s*"([^"]+)"', text))
        self.assertEqual(set(entries), set(ROLES))
        for role, relative in entries.items():
            self.assertEqual((REPO/'codex'/relative).resolve(), (REPO/'codex/agents'/f'{role}.toml').resolve())
            self.assertTrue((REPO/'codex'/relative).is_file())

    def test_registered_roles_apply_native_metadata_and_configuration(self):
        for role in ROLES:
            with self.subTest(role=role):
                print(json.dumps(self.run_fixture(role), ensure_ascii=False), flush=True)

    def test_preflight_reference_is_before_scenario_approval(self):
        # Instruction-routing validation, not evidence that an LLM complied.
        tdd = (REPO/'skills/tdd/SKILL.md').read_text()
        reference = '../SUBAGENT_RULES.md#開始時の可用性確認'
        self.assertLess(tdd.index(reference), tdd.index('## シナリオ選択'))
        self.assertTrue((REPO/'skills/SUBAGENT_RULES.md').is_file())

if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ['--probe-permissions']:
        # This extra diagnostic intentionally fails when the runtime inherits
        # workspace-write despite a role's read-only declaration. It is NOT
        # counted as successful role registration or silently skipped.
        RoleRuntime().run_fixture('difficulty-evaluator', probe_permissions=True)
    else:
        unittest.main()
