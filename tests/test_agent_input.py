"""Exercise validated briefs across opaque native transport and real hook files."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class AgentInput(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.hooks = self.root / ".codex/hooks/shell"
        shutil.copytree(REPO / "hooks/shell", self.hooks)
        shutil.copytree(REPO / "codex/agents", self.root / ".codex/agents")
        shutil.copytree(REPO / "skills", self.root / ".agents/skills")
        path = self.hooks / "hook-io.sh"
        path.write_text(path.read_text().replace("[agent_name]", "codex"))
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        self.state = self.root / ".codex/tmp/agent-input.TEST.json"
        subprocess.run(["git", "config", "user.name", "Test"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=self.root, check=True)
        (self.root / ".gitignore").write_text(".codex/\n.agents/\n")
        subprocess.run(["git", "add", ".gitignore"], cwd=self.root, check=True)
        subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "baseline"], cwd=self.root, check=True)
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.root, text=True).strip()
        self.brief = {"repository": str(self.root), "review_base": head, "review_head": head, "requirements": "Check value conversion."}

    def call(self, name, event="PreToolUse", **kwargs):
        command = ["bash", str(self.hooks / ("agent-input.sh" if name == "agent-input.py" else name))]
        return subprocess.run(command, input=json.dumps({"hook_event_name": event, "session_id": "TEST", "cwd": str(self.root), **kwargs}),
                              text=True, capture_output=True, cwd=self.root)

    def prepare(self, brief=None, role="code-reviewer"):
        command = shlex.join(["python3", ".codex/hooks/shell/agent-input.py", "prepare", role, json.dumps(self.brief if brief is None else brief)])
        response = self.call("agent-input.py", tool_name="Bash", tool_input={"command": command})
        self.assertEqual(response.returncode, 0, response.stderr)
        output = json.loads(response.stdout)["hookSpecificOutput"]
        self.assertEqual(output["permissionDecision"], "allow", output)
        emitted = subprocess.run(shlex.split(output["updatedInput"]["command"]), cwd=self.root, text=True, capture_output=True, check=True)
        return json.loads(emitted.stdout)

    def launch(self, inputs):
        guard = self.call("require-implementer.sh", tool_name="collaborationspawn_agent", tool_input=inputs)
        if guard.stdout:
            return guard
        return self.call("independent-review.sh", tool_name="collaborationspawn_agent", tool_input=inputs)

    def denied(self, response):
        self.assertEqual(response.returncode, 0, response.stderr)
        self.assertEqual(json.loads(response.stdout)["hookSpecificOutput"]["permissionDecision"], "deny", response.stdout)

    def test_opaque_input_is_bound_to_real_role_and_delivered(self):
        inputs = self.prepare()
        self.assertEqual(json.loads(inputs["message"]), self.brief)
        inputs["message"] = "gAAAAA_opaque_transport_fixture_not_plaintext"
        self.assertEqual(self.launch(inputs).stdout, "")
        started = self.call("load-operation-context.sh", "SubagentStart", agent_type="code-reviewer", agent_id="child")
        context = json.loads(started.stdout)["hookSpecificOutput"]["additionalContext"]
        self.assertIn(self.brief["requirements"], context)
        self.assertNotIn(inputs["message"], context)
        self.assertIn("子の共通制約", context)
        self.assertIn("読み取り専用の独立コードレビュー", context)
        self.assertEqual(json.loads(self.state.read_text())["child_id"], "child")
        self.denied(self.launch(inputs))
        result = {"status": "incomplete"}
        self.call("agent-input.py", "SubagentStop", agent_type="code-reviewer", agent_id="other", last_assistant_message=json.dumps(result))
        self.assertNotIn("result", json.loads(self.state.read_text()))
        self.call("agent-input.py", "SubagentStop", agent_type="code-reviewer", agent_id="child", last_assistant_message=json.dumps(result))
        self.assertEqual(json.loads(self.state.read_text())["phase"], "complete")
        self.denied(self.launch(inputs))

    def test_critical_reviewer_delivers_contract_and_records_result(self):
        role = "code-reviewer-critical"
        inputs = self.prepare(role=role)
        inputs["message"] = "opaque"
        self.assertEqual(self.launch(inputs).stdout, "")
        self.call("independent-review.sh", "SubagentStart", agent_type=role, agent_id="critical-child")
        started = self.call("load-operation-context.sh", "SubagentStart", agent_type=role, agent_id="critical-child")
        context = json.loads(started.stdout)["hookSpecificOutput"]["additionalContext"]
        self.assertIn("読み取り専用の独立コードレビュー", context)
        self.assertIn(self.brief["requirements"], context)
        state_path = self.root / ".codex/tmp/independent-review.TEST.json"
        pending = json.loads(state_path.read_text())["pending"]
        report = dict(status="reviewed", review_base=self.brief["review_base"],
                      review_head=self.brief["review_head"], request_id=pending["request_id"],
                      unchecked=[], findings=[])
        self.call("independent-review.sh", "SubagentStop", agent_type=role, agent_id="critical-child",
                  last_assistant_message=json.dumps(report))
        self.call("agent-input.py", "SubagentStop", agent_type=role, agent_id="critical-child")
        self.assertEqual(json.loads(state_path.read_text())["result"], report)
        self.assertEqual(json.loads(self.state.read_text())["phase"], "complete")

    def test_missing_preparation_role_spoof_and_changed_token_fail(self):
        inputs = {"agent_type": "code-reviewer", "task_name": "review", "fork_turns": "none", "message": "opaque"}
        self.denied(self.launch(inputs))
        prepared = self.prepare()
        self.denied(self.launch(dict(prepared, message=json.dumps(dict(self.brief, requirements="Different request")))))
        prepared["message"] = "opaque"
        for changes in ({"agent_type": "default"}, {"agent_type": None}, {"task_name": "different"}, {"fork_turns": "all"}):
            self.denied(self.launch(dict(prepared, **changes)))

    def test_invalid_json_shape_repository_and_length_fail_before_launch(self):
        for raw in ("not json", "[]", json.dumps(dict(self.brief, extra=True)), json.dumps(dict(self.brief, repository="/elsewhere")),
                    json.dumps(dict(self.brief, requirements=" ")),
                    '{"repository":"x","repository":"y","requirements":"p"}'):
            command = shlex.join(["python3", ".codex/hooks/shell/agent-input.py", "prepare", "code-reviewer", raw])
            self.denied(self.call("agent-input.py", tool_name="Bash", tool_input={"command": command}))
        valid = dict(self.brief, requirements="日" * 4000)
        self.assertEqual(json.loads(self.prepare(valid)["message"]), valid)

    def test_without_preparation_hook_script_fails(self):
        result = subprocess.run(["python3", str(self.hooks / "agent-input.py"), "prepare", "code-reviewer", json.dumps(self.brief)],
                                cwd=self.root, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.state.exists())

    def test_prepare_json_is_data_not_a_shell_operation(self):
        brief = dict(self.brief, requirements='Add denial tests for rm .env ; mkdir .codex/tmp ; sed -i yarn.lock')
        command = shlex.join(['python3', '.codex/hooks/shell/agent-input.py', 'prepare', 'code-reviewer', json.dumps(brief)])
        for hook in ('protect-git.sh', 'protect-config.sh', 'protect-env.sh', 'protect-locks.sh'):
            response = self.call(hook, tool_name='Bash', tool_input={'command': command})
            self.assertEqual(response.returncode, 0, response.stderr)
            self.assertEqual(response.stdout, '', hook + ': ' + response.stdout)
        self.assertEqual(json.loads(self.prepare(brief)['message']), brief)

    def test_preparation_normalization_cannot_hide_real_operations(self):
        for command in ('rm .codex/agent-input.py',
                        'python3 .codex/hooks/shell/agent-input.py prepare code-reviewer "invalid" > .codex/config.toml',
                        'bash .codex/hooks/shell/outside.sh "rm .codex/agent-input.py"'):
            self.denied(self.call('protect-config.sh', tool_name='Bash', tool_input={'command': command}))
        helper = self.hooks / 'agent-input.py'
        helper.rename(helper.with_suffix('.missing'))
        self.denied(self.call('protect-config.sh', tool_name='Bash', tool_input={'command': 'rm .codex/agent-input.py'}))

    def test_metadata_aliases_are_not_written(self):
        directory = self.state.parent
        directory.mkdir()
        sentinel = self.root / ".git/sentinel"
        sentinel.write_text("unchanged")
        for link in ("symbolic", "hard"):
            if link == "symbolic":
                self.state.symlink_to(sentinel)
            else:
                os.link(sentinel, self.state)
            command = shlex.join(["python3", ".codex/hooks/shell/agent-input.py", "prepare", "code-reviewer", json.dumps(self.brief)])
            self.denied(self.call("agent-input.py", tool_name="Bash", tool_input={"command": command}))
            self.assertEqual(sentinel.read_text(), "unchanged")
            self.state.unlink()


if __name__ == "__main__":
    unittest.main()
