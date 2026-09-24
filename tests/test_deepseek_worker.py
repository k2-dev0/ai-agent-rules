"""Exercise configured asynchronous worker hooks with synthetic MCP results."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class Worker(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.hooks = self.root / ".codex/hooks/shell"
        shutil.copytree(REPO / "hooks/shell", self.hooks)
        adapter = self.hooks / "hook-io.sh"
        adapter.write_text(adapter.read_text().replace("[agent_name]", "codex"))
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        (self.root / ".gitignore").write_text(".codex/\n")
        (self.root / "code.txt").write_text("original\n")
        self.git("add", ".")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "baseline")
        self.base = self.git("rev-parse", "HEAD")
        self.state = self.root / ".codex/tmp/deepseek-worker.json"
        self.review = self.root / ".codex/tmp/independent-review.TEST.json"
        self.settings = json.loads((REPO / "codex/hooks.json").read_text())

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True).strip()

    def call(self, action="start_task", event="PreToolUse", owner="TEST", call_id="call-1", result=None, **inputs):
        tool = action if action in ("Bash", "apply_patch", "spawn_agent") else "mcp__deepseek-worker__" + action
        payload = dict(hook_event_name=event, session_id=owner, cwd=str(self.root), tool_name=tool,
                       tool_use_id=call_id, tool_input=inputs)
        if result is not None:
            payload["tool_response"] = result
        outputs = []
        for group in self.settings["hooks"].get(event, []):
            if not re.search(group.get("matcher", ".*"), tool):
                continue
            for hook in group["hooks"]:
                script = re.search(r"shell/([\w-]+\.(?:py|sh))", hook["command"])[1]
                if script not in ("deepseek-worker.sh", "independent-review.sh"):
                    continue
                proc = subprocess.run(["python3" if script.endswith(".py") else "bash", str(self.hooks / script)],
                                      input=json.dumps(payload), text=True, capture_output=True, cwd=self.root, check=True)
                self.assertEqual(proc.stderr, "")
                if proc.stdout:
                    response = json.loads(proc.stdout)
                    outputs.append(response)
                    if response.get("hookSpecificOutput", {}).get("permissionDecision") == "deny":
                        return outputs
        return outputs

    def post(self, action="start_task", status="running", task="task-1", **kwargs):
        if action in ("wait_task", "abort_task"):
            self.call(action, **kwargs)
        return self.call(action, event="PostToolUse", result={"structuredContent": {"task_id": task, "status": status}}, **kwargs)

    def denied(self, output):
        self.assertTrue(any(o.get("hookSpecificOutput", {}).get("permissionDecision") == "deny" for o in output), output)

    def start_error(self, text=None, omit=(), **changes):
        payload = {"class": "configuration_error", "message": "The brief was rejected",
                   "rejection": "input_validation", "execution_started": False}
        payload.update(changes)
        for key in omit:
            payload.pop(key, None)
        return {"isError": True,
                "content": [{"type": "text", "text": json.dumps(payload) if text is None else text}]}

    def assert_guard_held(self, output, before):
        self.assertFalse(output[0]["continue"])
        self.assertEqual(self.state.read_bytes(), before)
        self.denied(self.call("Bash", command="git status --short"))

    def test_baseline_before_worker_and_exclusive_parent_until_completion(self):
        self.assertEqual(self.call(brief="Rename a private symbol"), [])
        self.assertEqual(json.loads(self.review.read_text())["base"], self.base)
        self.post()
        for action, inputs in (("Bash", {"command": "git add code.txt"}), ("apply_patch", {"command": "patch"}),
                               ("spawn_agent", {"agent_type": "code-reviewer"}), ("start_task", {"brief": "second"})):
            self.denied(self.call(action, **inputs))
        self.assertEqual(self.post("wait_task", task_id="task-1"), [])
        self.denied(self.call("Bash", command="git commit -m done"))
        self.assertEqual(self.post("wait_task", "completed", task_id="task-1"), [])
        self.assertEqual(self.call("Bash", command="git status --short"), [])
        self.assertEqual(self.call("continue_task", task_id="task-1", message="Fix one finding"), [])
        self.post("continue_task", task_id="task-1")
        self.denied(self.call("apply_patch", command="patch"))

    def test_wrong_owner_task_or_call_cannot_unlock(self):
        self.call(brief="implement")
        self.assertTrue(self.post(call_id="other")[0].get("continue") is False)
        self.post()
        for kwargs in ({"owner": "OTHER"}, {"task": "other"}):
            self.assertFalse(self.post("wait_task", "completed", task_id="task-1", **kwargs)[0]["continue"])
        self.denied(self.call("wait_task", owner="OTHER", task_id="task-1"))
        self.assertTrue(json.loads(self.state.read_text())["busy"])

    def test_errors_unknown_results_and_aborts(self):
        self.call(brief="implement")
        for result in ({"isError": True}, {}, {"content": [{"type": "text", "text": "not JSON"}]}):
            self.assertFalse(self.call(event="PostToolUse", result=result)[0]["continue"])
            self.assertTrue(json.loads(self.state.read_text())["busy"])
        self.post()
        self.assertEqual(self.call("abort_task", task_id="task-1"), [])
        self.denied(self.call("Bash", command="git status --short"))
        self.post("abort_task", "aborted", task_id="task-1")
        self.assertEqual((self.root / "code.txt").read_text(), "original\n")
        self.assertFalse(json.loads(self.state.read_text())["busy"])

    def test_text_mcp_result_and_new_request_invalidate_review(self):
        self.call(brief="implement")
        self.call(event="PostToolUse", result={"content": [{"type": "text", "text": json.dumps({"task_id": "task-1", "status": "needs_decision"})}]})
        data = json.loads(self.review.read_text())
        data["result"] = {"status": "reviewed", "review_head": self.base}
        self.review.write_text(json.dumps(data))
        self.call("continue_task", task_id="task-1", message="Decision")
        self.assertNotIn("result", json.loads(self.review.read_text()))
        self.assertEqual(json.loads(self.review.read_text())["base"], self.base)

    def test_state_alias_cannot_modify_git_metadata(self):
        self.state.parent.mkdir(exist_ok=True)
        sentinel = self.root / ".git/sentinel"
        sentinel.write_text('{"busy":false}')
        for kind in ("symlink", "hardlink"):
            if kind == "symlink":
                self.state.symlink_to(sentinel)
            else:
                os.link(sentinel, self.state)
            self.denied(self.call(brief="implement"))
            self.assertEqual(sentinel.read_text(), '{"busy":false}')
            self.state.unlink()

    def test_old_wait_cannot_unlock_a_continued_turn(self):
        self.call(brief="implement")
        self.post()
        self.call("wait_task", call_id="old-wait", task_id="task-1")
        self.post("wait_task", "completed", call_id="finish", task_id="task-1")
        self.call("continue_task", call_id="next", task_id="task-1", message="Fix")
        self.post("continue_task", call_id="next", task_id="task-1")
        late = self.call("wait_task", event="PostToolUse", call_id="old-wait", task_id="task-1",
                         result={"structuredContent": {"task_id": "task-1", "status": "completed"}})
        self.assertFalse(late[0]["continue"])
        self.assertTrue(json.loads(self.state.read_text())["busy"])

    def test_bridge_registration_preserves_worker_with_sol_high_parent(self):
        config = (REPO / "codex/config.toml").read_text()
        root_settings = config.split("[", 1)[0]
        self.assertIn('model = "gpt-5.6-sol"', root_settings)
        self.assertIn('model_reasoning_effort = "high"', root_settings)
        section = config.split("[mcp_servers.deepseek-worker]", 1)[1].split("\n[", 1)[0]
        self.assertIn('args = [".codex/hooks/shell/deepseek-launch.sh", "deepseek-bridge"]', section)
        self.assertIn('env_vars = ["DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL"]', section)
        self.assertIn('tool_timeout_sec = 1300', section)
        self.assertIn('enabled_tools = ["start_task", "wait_task", "continue_task", "abort_task"]', section)

    def test_invalid_start_does_not_reserve_the_worktree(self):
        self.denied(self.call(brief="  "))
        self.assertFalse(self.state.exists())
        self.assertEqual(self.call("Bash", command="git status --short"), [])

    def test_missing_initial_commit_cannot_start_an_unreviewable_worker(self):
        self.git("symbolic-ref", "HEAD", "refs/heads/unborn")
        self.denied(self.call(brief="implement"))
        self.assertFalse(self.state.exists())

    def test_cleanup_failure_never_releases_parent_writer(self):
        self.call(brief="implement")
        self.post()
        self.call("wait_task", task_id="task-1")
        result = {"task_id": "task-1", "status": "failed",
                  "error": {"class": "abort_error", "message": "Runtime cleanup failed"}}
        output = self.call("wait_task", event="PostToolUse", task_id="task-1",
                           result={"structuredContent": result})
        self.assertFalse(output[0]["continue"])
        self.assertTrue(json.loads(self.state.read_text())["busy"])
        for action, inputs in (("Bash", {"command": "git add code.txt"}),
                               ("apply_patch", {"command": "patch"}),
                               ("spawn_agent", {"agent_type": "code-reviewer"}),
                               ("start_task", {"brief": "second"})):
            self.denied(self.call(action, **inputs))

    def test_failed_requires_a_known_non_cleanup_error(self):
        self.call(brief="implement")
        self.post()
        for error in (None, {}, {"class": "unknown_error"}):
            self.call("wait_task", task_id="task-1")
            result = {"task_id": "task-1", "status": "failed", "error": error}
            output = self.call("wait_task", event="PostToolUse", task_id="task-1",
                               result={"content": [{"type": "text", "text": json.dumps(result)}]})
            self.assertFalse(output[0]["continue"])
            self.assertTrue(json.loads(self.state.read_text())["busy"])
        self.call("wait_task", task_id="task-1")
        result["error"] = {"class": "authentication_error", "message": "Invalid API key"}
        self.assertEqual(self.call("wait_task", event="PostToolUse", task_id="task-1",
                                  result={"structuredContent": result}), [])
        self.assertFalse(json.loads(self.state.read_text())["busy"])

    def test_timeout_releases_only_a_matched_confirmed_terminal_result(self):
        self.call(brief="implement")
        self.post()
        self.call("wait_task", call_id="timeout-wait", task_id="task-1")
        result = {"task_id": "task-1", "status": "failed",
                  "error": {"class": "task_timeout_error"}}
        for changes in ({"owner": "OTHER"}, {"call_id": "wrong"}, {"task_id": "wrong"}):
            args = dict(call_id="timeout-wait", task_id="task-1")
            args.update(changes)
            output = self.call("wait_task", event="PostToolUse",
                               result={"structuredContent": result}, **args)
            self.assertFalse(output[0]["continue"])
            self.assertTrue(json.loads(self.state.read_text())["busy"])
        for changed in ({**result, "task_id": "wrong"}, {**result, "status": "running"},
                        {**result, "error": {"class": "abort_error"}}, {"isError": True}):
            self.call("wait_task", call_id="timeout-wait", task_id="task-1")
            self.call("wait_task", event="PostToolUse", call_id="timeout-wait", task_id="task-1",
                      result={"structuredContent": changed})
            self.assertTrue(json.loads(self.state.read_text())["busy"])
            self.denied(self.call("Bash", command="git status --short"))
        self.call("wait_task", call_id="timeout-wait", task_id="task-1")
        self.assertEqual(self.call("wait_task", event="PostToolUse", call_id="timeout-wait",
                                  task_id="task-1", result={"structuredContent": result}), [])
        self.assertFalse(json.loads(self.state.read_text())["busy"])
        self.assertEqual(self.call("Bash", command="git status --short"), [])

    def test_confirmed_start_rejection_releases_the_pending_reservation(self):
        self.call(brief="Implement the change")
        self.denied(self.call("Bash", command="git status --short"))
        marked = self.start_error()
        marked["content"][0].update({"annotations": {"audience": ["assistant"]}, "_meta": {"trace": "local"}})
        marked["_meta"] = {}
        self.assertEqual(self.call(event="PostToolUse", result=marked), [])
        data = json.loads(self.state.read_text())
        self.assertFalse(data["busy"])
        self.assertIsNone(data["task_id"])
        self.assertEqual(data["observations"], {})
        self.assertEqual(self.call("Bash", command="git status --short"), [])
        self.assertEqual(self.call("start_task", brief="Second attempt"), [])
        self.assertEqual(self.call(event="PostToolUse", result=json.dumps(self.start_error())), [])
        self.assertFalse(json.loads(self.state.read_text())["busy"])
        self.assertEqual(self.call("Bash", command="git status --short"), [])
        self.assertEqual(self.call("start_task", brief="Third attempt"), [])
        self.post()
        self.assertEqual(self.post("wait_task", "completed", task_id="task-1"), [])
        self.assertFalse(json.loads(self.state.read_text())["busy"])
        self.assertEqual(self.call("Bash", command="git status --short"), [])

    def test_only_a_matching_pending_start_rejection_can_release(self):
        self.call(brief="implement")
        pending = self.state.read_bytes()
        cases = (
            ("old_format", self.start_error(omit=("rejection", "execution_started"))),
            ("transport_error", self.start_error(**{"class": "transport_error"})),
            ("abort_error", self.start_error(**{"class": "abort_error"})),
            ("missing_rejection", self.start_error(omit=("rejection",))),
            ("missing_execution_started", self.start_error(omit=("execution_started",))),
            ("extra_payload_field", self.start_error(task_id="task-1")),
            ("non_string_message", self.start_error(message=1)),
            ("string_false", self.start_error(execution_started="false")),
            ("isError_one", {**self.start_error(), "isError": 1}),
            ("isError_string_false", {**self.start_error(), "isError": "false"}),
            ("extra_outer_key", {**self.start_error(), "extra": 1}),
            ("structured_content", {**self.start_error(),
                                    "structuredContent": {"task_id": "task-1", "status": "running"}}),
            ("multiple_content", {"isError": True,
                                  "content": self.start_error()["content"] + [{"type": "text", "text": "{}"}]}),
            ("non_text", {"isError": True, "content": [{"type": "image", "data": "x"}]}),
            ("text_not_string", {"isError": True, "content": [{"type": "text", "text": 1}]}),
            ("invalid_json", self.start_error(text="not JSON")),
            ("payload_not_object", self.start_error(text=json.dumps(["configuration_error"]))),
            ("duplicate_payload_key", self.start_error(
                text='{"class":"configuration_error","class":"transport_error","message":"m",'
                     '"rejection":"input_validation","execution_started":false}')),
            ("nan_constant", self.start_error(
                text='{"class":"configuration_error","message":"m",'
                     '"rejection":"input_validation","execution_started":NaN}')),
            ("duplicate_outer_key", '{"isError":true,"isError":true,"content":'
                                    + json.dumps(self.start_error()["content"]) + '}'),
            ("response_not_object", ["isError"]),
            ("part_extra_key", {**self.start_error(),
                                "content": [{**self.start_error()["content"][0], "extra": "x"}]}),
            ("part_meta_not_object", {**self.start_error(),
                                      "content": [{**self.start_error()["content"][0], "_meta": None}]}),
            ("part_annotations_not_object", {**self.start_error(),
                                             "content": [{**self.start_error()["content"][0],
                                                          "annotations": ["assistant"]}]}),
            ("outer_meta_not_object", {**self.start_error(), "_meta": ["x"]}),
        )
        for label, result in cases:
            with self.subTest(label):
                self.assert_guard_held(self.call(event="PostToolUse", result=result), pending)
        for label, kwargs in (("owner_mismatch", {"owner": "OTHER"}),
                              ("call_mismatch", {"call_id": "other"}),
                              ("missing_event_call_id", {"call_id": None})):
            with self.subTest(label):
                self.assert_guard_held(self.call(event="PostToolUse", result=self.start_error(), **kwargs), pending)
        for label, state, kwargs in (
                ("missing_task_id_key", {"busy": True, "owner": "TEST", "call_id": "call-1", "observations": {}},
                 {"call_id": "call-1"}),
                ("empty_call_id", {"busy": True, "owner": "TEST", "call_id": "", "task_id": None, "observations": {}},
                 {"call_id": ""}),
                ("missing_state_call_id", {"busy": True, "owner": "TEST", "task_id": None, "observations": {}},
                 {"call_id": None})):
            with self.subTest(label):
                self.state.write_text(json.dumps(state))
                before = self.state.read_bytes()
                self.assert_guard_held(self.call(event="PostToolUse", result=self.start_error(), **kwargs), before)

    def test_start_rejection_never_releases_other_actions_or_a_known_task(self):
        self.call(brief="implement")
        self.post()
        before = self.state.read_bytes()
        self.assert_guard_held(self.call(event="PostToolUse", call_id="call-1", result=self.start_error()), before)
        self.post("wait_task", "completed", task_id="task-1")
        self.call("continue_task", call_id="cont-1", task_id="task-1", message="Fix")
        before = self.state.read_bytes()
        self.assert_guard_held(self.call("continue_task", event="PostToolUse", call_id="cont-1",
                                         task_id="task-1", result=self.start_error()), before)
        self.call("wait_task", call_id="wait-1", task_id="task-1")
        before = self.state.read_bytes()
        self.assert_guard_held(self.call("wait_task", event="PostToolUse", call_id="wait-1",
                                         task_id="task-1", result=self.start_error()), before)
        self.call("abort_task", call_id="abort-1", task_id="task-1")
        before = self.state.read_bytes()
        self.assert_guard_held(self.call("abort_task", event="PostToolUse", call_id="abort-1",
                                         task_id="task-1", result=self.start_error()), before)


if __name__ == "__main__":
    unittest.main()
