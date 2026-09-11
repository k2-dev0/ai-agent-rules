"""Verify review evidence without inferring that every code edit requires review."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class ReviewEvidence(unittest.TestCase):
    def test_distributed_lifecycle(self):
        for agent in ("codex", "claude"):
            with self.subTest(agent=agent), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                hookdir = root / f".{agent}/hooks/shell"
                shutil.copytree(REPO / "hooks/shell", hookdir)
                adapter = hookdir / "hook-io.sh"
                adapter.write_text(adapter.read_text().replace("[agent_name]", agent))
                state = root / f".{agent}/tmp/independent-review.TEST.json"

                def git(*args):
                    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()

                git("init", "-q")
                git("config", "user.name", "Test")
                git("config", "user.email", "test@example.invalid")
                (root / ".gitignore").write_text(".codex/\n.claude/\n")
                source = root / "sample.py"
                source.write_text("value = 0\n")
                git("add", ".")
                git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "baseline")
                base = git("rev-parse", "HEAD")

                def call(event, **kwargs):
                    payload = dict(hook_event_name=event, session_id="TEST", cwd=str(root), **kwargs)
                    result = subprocess.run(
                        ["bash", str(hookdir / "independent-review.sh")],
                        input=json.dumps(payload), text=True, capture_output=True, check=True,
                    )
                    self.assertEqual(result.stderr, "")
                    return json.loads(result.stdout) if result.stdout else None

                def edit(path="sample.py"):
                    if agent == "codex":
                        return call("PreToolUse", tool_name="apply_patch", tool_input={"command": f"*** Update File: {path}\n"})
                    return call("PreToolUse", tool_name="Edit", tool_input={"file_path": path})

                def commit(value):
                    source.write_text(f"value = {value}\n")
                    git("add", "sample.py")
                    git("-c", "core.hooksPath=/dev/null", "commit", "-qm", f"value {value}")
                    return git("rev-parse", "HEAD")

                role_key = "agent_type" if agent == "codex" else "subagent_type"

                def launch(review_base=None, head=None):
                    if review_base is None:
                        review_base = json.loads(state.read_text())["base"] if state.exists() else base
                    brief = {
                        "repository": str(root),
                        "review_base": review_base,
                        "review_head": head or git("rev-parse", "HEAD"),
                        "requirements": "Implement the requested value.",
                    }
                    response = call("PreToolUse", tool_name="Agent", tool_input={role_key: "code-reviewer", "prompt": json.dumps(brief)})
                    if response and response.get("hookSpecificOutput", {}).get("updatedInput"):
                        brief = json.loads(response["hookSpecificOutput"]["updatedInput"]["prompt"])
                    return brief, response

                def start():
                    call("SubagentStart", agent_id="child", agent_type="code-reviewer")

                def result(brief, **changes):
                    report = {
                        "status": "reviewed", "review_base": brief["review_base"],
                        "review_head": brief["review_head"], "request_id": brief["request_id"],
                        "unchecked": [], "findings": [],
                    }
                    report.update(changes)
                    return report

                def end(report, child="child"):
                    call("SubagentStop", agent_id=child, agent_type="code-reviewer", last_assistant_message=json.dumps(report))

                def accepted():
                    return "result" in json.loads(state.read_text())

                self.assertIsNone(call("Stop"))
                edit("README.md")
                self.assertFalse(state.exists())
                self.assertIsNone(edit())
                self.assertEqual(json.loads(state.read_text())["base"], base)
                head = commit(1)
                self.assertIsNone(call("Stop", last_assistant_message="Completed"))

                _, denied = launch(head=base)
                self.assertEqual(denied["hookSpecificOutput"]["permissionDecision"], "deny")
                brief, response = launch()
                self.assertEqual(response["hookSpecificOutput"]["permissionDecision"], "allow")
                start()
                end(result(brief), child="other")
                self.assertFalse(accepted())
                end(result(brief, unchecked=["ignored test"]))
                self.assertFalse(accepted())
                end(result(brief, status="incomplete"))
                self.assertFalse(accepted())
                end(result(brief, findings=[{"severity": "urgent"}]))
                self.assertFalse(accepted())
                end(result(brief))
                self.assertTrue(accepted())

                call("UserPromptSubmit", prompt="Next change")
                self.assertFalse(state.exists())
                self.assertIsNone(edit())
                head = commit(2)
                brief, _ = launch()
                start()
                source.write_text("value = dirty\n")
                end(result(brief))
                self.assertFalse(accepted())
                source.write_text("value = 2\n")
                brief, _ = launch()
                start()
                end(result(brief))
                self.assertTrue(accepted())

                edit("new.py")
                (root / "new.py").write_text("new = True\n")
                brief, _ = launch()
                start()
                end(result(brief))
                self.assertFalse(accepted())
                self.assertIsNone(call("Stop", last_assistant_message="Completed"))

                settings = json.loads((REPO / ("codex/hooks.json" if agent == "codex" else "claude/settings.json")).read_text())
                for event in ("PreToolUse", "UserPromptSubmit", "SubagentStart", "SubagentStop"):
                    self.assertTrue(any("independent-review.sh" in hook["command"] for group in settings["hooks"][event] for hook in group["hooks"]))
                self.assertNotIn("Stop", settings["hooks"])


if __name__ == "__main__":
    unittest.main()
