"""Opt-in native Codex role integration with a local simulated Responses API.

Run outside the enclosing sandbox (loopback HTTP). No external model is called.
The real CLI, project hook chain, tool schema and spawn handler are tested;
app-server reads the resulting native metadata. Responses are simulated, not
an LLM's judgment. A temporary per-process Codex home isolates settings/history.
--probe-permissions is a separate strict diagnostic, not a passing exemption.
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
import hashlib
from probe_agent_workflow import prepare
from workflow_evidence import prepared_arguments

REPO = Path(__file__).resolve().parents[1]
ROLES = {
    "code-reviewer": ("gpt-6-astra", "xhigh"),
    "design-reviewer": ("gpt-6-astra", "xhigh"),
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
    def run_fixture(self, role, probe_permissions=False, probe_switch=False, trusted=True, fail_emit=False, unstage=False):
        self.assertIsNotNone(shutil.which("codex"))
        with tempfile.TemporaryDirectory(prefix="role-runtime-") as directory:
            base = Path(directory).resolve()
            root = prepare(base, 'project with spaces')
            if fail_emit:
                helper = root / '.codex/hooks/shell/agent-input.py'
                helper.write_text(helper.read_text().replace('if operation == "emit" and len(args) == 3:', 'if operation == "emit" and len(args) == 3:\n        raise ValueError("injected emit failure")'))
            fixture_home = base / 'codex-runtime'
            fixture_home.mkdir()
            # Use Codex's supported per-process home setting, without changing
            # the caller's environment or configuration. Durable fixture threads
            # are required for SubagentStart/Stop transcript-backed hooks.
            environment = dict(os.environ, CODEX_HOME=str(fixture_home))
            catalog = Path(os.environ.get('CODEX_HOME', str(Path.home()/'.codex'))) / 'models_cache.json'
            if catalog.is_file():
                shutil.copyfile(catalog, fixture_home/'models_cache.json')
            head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
            if unstage:
                source = root / 'value.py'
                source.write_text(source.read_text() + '# staged fixture\n')
                subprocess.run(['git','add','--','value.py'],cwd=root,check=True,capture_output=True)
                source.write_text(source.read_text() + '# unstaged work\n')
                expected_worktree = source.read_bytes()
            prepared_role = role == 'code-reviewer'
            brief = dict(repository=str(root), review_base=head, review_head=head, requirements='Review double for its specified behavior.')
            requests = []
            preparation_errors = []
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
                    if unstage:
                        if is_parent and parent_requests == 1:
                            item = dict(type='function_call', id='unstage', call_id='unstage', namespace='functions', name='exec_command', arguments=json.dumps(dict(cmd=unstage if isinstance(unstage, str) else 'git restore --staged .',workdir=str(root))))
                        else:
                            item = dict(type='message', id='unstage-done', role='assistant', content=[dict(type='output_text',text='Fixture transport complete.',annotations=[])])
                    elif is_parent and parent_requests == 1 and probe_permissions:
                        item = dict(type="function_call", id="parent-write", call_id="parent-write", namespace="functions", name="exec_command", arguments=json.dumps(dict(cmd="touch " + shlex.quote(str(root / "parent-write")), workdir=str(root))))
                    elif is_parent and prepared_role and parent_requests == (2 if probe_permissions else 1):
                        command = shlex.join(['python3', '.codex/hooks/shell/agent-input.py', 'prepare', role, json.dumps(brief)])
                        item = dict(type='function_call', id='prepare', call_id='prepare', namespace='functions', name='exec_command', arguments=json.dumps(dict(cmd=command, workdir=str(root))))
                    elif is_parent and parent_requests == (1 + int(probe_permissions) + int(prepared_role)):
                        args = dict(task_name="role_probe", agent_type=role, fork_turns="none",
                                    message=json.dumps(brief))
                        if prepared_role:
                            try:
                                args = prepared_arguments(body, role, brief)
                                args['message'] = 'opaque-native-transport-fixture'
                            except (ValueError, TypeError) as error:
                                preparation_errors.append(str(error))
                        if preparation_errors:
                            item = dict(type='message', id='prepare-failed', role='assistant', content=[dict(type='output_text',text='Fixture preparation failed.',annotations=[])])
                        else:
                            item = dict(type="function_call", id="spawn", call_id="spawn", namespace="collaboration", name="spawn_agent", arguments=json.dumps(args))
                    elif is_parent and parent_requests == (2 + int(probe_permissions) + int(prepared_role)):
                        item = dict(type="function_call", id="wait", call_id="wait", namespace="collaboration", name="wait_agent", arguments='{"timeout_ms":10000}')
                    elif is_parent and probe_switch and role == 'code-reviewer' and parent_requests == (3 + int(probe_permissions) + int(prepared_role)):
                        item = dict(type='function_call', id='switch', call_id='switch', namespace='functions', name='switch_model', arguments=json.dumps(dict(model='gpt-6-astra', config=dict(effort='xhigh'))))
                    elif not is_parent and child_requests_count == 1 and probe_permissions:
                        item = dict(type="function_call", id="child-write", call_id="child-write", namespace="functions", name="exec_command", arguments=json.dumps(dict(cmd="touch " + shlex.quote(str(root / "child-write")), workdir=str(root))))
                    else:
                        result = 'Fixture transport complete.'
                        if not is_parent and role == 'code-reviewer':
                            proofs = list((root / '.codex/tmp').glob('independent-review.*.json'))
                            if proofs:
                                data = json.loads(proofs[0].read_text())
                                result = json.dumps(dict(status='reviewed', review_base=head, review_head=head, request_id=data['pending']['request_id'], unchecked=[], findings=[]))
                            else:
                                result = '{"status":"incomplete"}'
                        item = dict(type="message", id="msg" + str(number), role="assistant", content=[dict(type="output_text", text=result, annotations=[])])
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
                    "features.apps":False, "features.plugins":False, "features.hooks":True,
                    "features.multi_agent":True, "features.code_mode":False,
                    "features.enable_request_compression":False, "mcp_servers":{},
                    "agents.enabled":True,
                    "projects":{str(root):{"trust_level":"trusted" if trusted else "untrusted"}},
                    "model_providers.fixture.name":"fixture",
                    "model_providers.fixture.base_url":f"http://127.0.0.1:{server.server_port}/v1",
                    "model_providers.fixture.wire_api":"responses",
                    "model_providers.fixture.requires_openai_auth":False,
                    "model_providers.fixture.request_max_retries":0,
                    "model_providers.fixture.stream_max_retries":0,
                }
                (fixture_home / 'config.toml').write_text('\n'.join(key+'='+toml(value) for key,value in settings.items())+'\n')
                # Drive the real CLI: its hook-trust option is supported, whereas
                # passing that option to app-server silently leaves hooks untrusted.
                # The app-server below is used only for public metadata reads.
                with (root / 'cli-stderr.log').open('w') as cli_stderr:
                    execution = subprocess.run(['codex', 'exec', '--json', '--strict-config', '--dangerously-bypass-hook-trust', 'Run only the isolated transport fixture.'],
                                               cwd=root, env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=cli_stderr, text=True, timeout=90)
                self.assertEqual(execution.returncode, 0, execution.stdout + (root / 'cli-stderr.log').read_text())
                if unstage:
                    outputs = [x.get('output','') for request in requests for x in request.get('input',[]) if x.get('type') == 'function_call_output' and x.get('call_id') == 'unstage']
                    self.assertTrue(any(re.search(r'^Process exited with code 0$', str(value), re.MULTILINE) for value in outputs), outputs)
                    self.assertEqual(subprocess.check_output(['git','diff','--cached','--name-only'],cwd=root,text=True).strip(), '')
                    self.assertEqual((root/'value.py').read_bytes(), expected_worktree)
                    self.assertEqual(subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(), head)
                    return dict(unstaged=True, worktree_preserved=True, head_preserved=True)
                if fail_emit:
                    self.assertTrue(preparation_errors)
                    self.assertFalse(any(json.loads(r.get('client_metadata',{}).get('x-codex-turn-metadata','{}')).get('parent_thread_id') for r in requests))
                    state = json.loads(next((root / '.codex/tmp').glob('agent-input.*.json')).read_text())
                    self.assertEqual(state['phase'], 'prepared', 'a prepared state alone must not authorize a successful test')
                    return dict(emit_failed=True, child_started=False)
                if trusted:
                    self.assertFalse(preparation_errors, [preparation_errors, [x for request in requests for x in request.get('input', []) if x.get('type') == 'function_call_output' and x.get('call_id') == 'prepare']])
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
                        self.assertTrue(requests)
                        schema = find_spawn_schema(requests[0])
                        def names(value):
                            if isinstance(value, dict):
                                return ([value['name']] if isinstance(value.get('name'), str) else []) + [n for v in value.values() for n in names(v)]
                            if isinstance(value, list):
                                return [n for v in value for n in names(v)]
                            return []
                        self.assertIsNotNone(schema, dict(model=requests[0]['model'], keys=list(requests[0]), names=names(requests[0])))
                        if not trusted:
                            self.assertNotIn(role + ':', str(schema['parameters']['properties'].get('agent_type','')))
                            self.assertFalse((base / 'events.jsonl').exists())
                            self.assertFalse((root / '.codex/tmp').exists())
                            return dict(project_trusted=False, hooks_loaded=False, role_available=False)
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
                        events = [json.loads(line) for line in (base / 'events.jsonl').read_text().splitlines()]
                        starts = [e for e in events if e['input'].get('hook_event_name') == 'SubagentStart' and e['input'].get('agent_id') == child['id']]
                        self.assertTrue(starts, events)
                        child_context = str(child_request['input'])
                        self.assertIn('子の共通制約', child_context)
                        if prepared_role:
                            data = json.loads(next((root / '.codex/tmp').glob('agent-input.*.json')).read_text())
                            self.assertEqual(data['child_id'], child['id'])
                            self.assertEqual(data['phase'], 'complete')
                            self.assertIn('検証済みJSON', child_context)
                            snapshots = [e['file_hashes'] for e in events if e['input'].get('hook_event_name') == 'PostToolUse' and 'file_hashes' in e]
                            self.assertTrue(snapshots, 'the real PostToolUse observer must capture file hashes')
                            self.assertEqual(snapshots[-1], {name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in ('value.py','test_value.py')})
                        if role == 'code-reviewer':
                            self.assertEqual(data['phase'], 'complete')
                            if probe_switch:
                                # switch_model is supplied by the ChatGPT-backed
                                # runtime, not this local simulated provider. Its
                                # rejection must never count as an applied switch.
                                parent_requests_after = [r for r in requests if not json.loads(r.get('client_metadata',{}).get('x-codex-turn-metadata','{}')).get('parent_thread_id')]
                                switch_outputs = [x for r in parent_requests_after for x in r['input'] if x.get('type') == 'function_call_output' and x.get('call_id') == 'switch']
                                self.assertTrue(any('unsupported call: switch_model' in str(x) for x in switch_outputs), switch_outputs)
                                self.assertEqual((parent_requests_after[-1]['model'], parent_requests_after[-1]['reasoning']['effort']), ('gpt-5.6-sol','high'))
                        if role == 'code-reviewer':
                            proof = json.loads(next((root / '.codex/tmp').glob('independent-review.*.json')).read_text())
                            self.assertEqual(proof['result']['status'], 'reviewed')
                        result = dict(role=child["agentRole"], model=child_request["model"], effort=child_request["reasoning"]["effort"], hook_events=len(events), contracts_delivered=True)
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

    def test_untrusted_project_does_not_load_roles_or_hooks(self):
        self.run_fixture('code-reviewer', trusted=False)

    def test_unsupported_switch_does_not_change_the_model(self):
        self.run_fixture('code-reviewer', probe_switch=True)

    def test_failed_emit_does_not_spawn_from_internal_state(self):
        self.run_fixture('code-reviewer', fail_emit=True)

    def test_validated_unstage_runs_through_the_real_policy(self):
        for command in ('git restore --staged .', 'git restore --staged --source=HEAD -- value.py'):
            with self.subTest(command=command):
                print(self.run_fixture('code-reviewer', unstage=command), flush=True)

if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ['--probe-permissions']:
        # This extra diagnostic intentionally fails when the runtime inherits
        # workspace-write despite a role's read-only declaration. It is NOT
        # counted as successful role registration or silently skipped.
        RoleRuntime().run_fixture('code-reviewer', probe_permissions=True)
    else:
        unittest.main()
