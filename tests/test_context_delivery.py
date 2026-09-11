"""Measure model-visible context delivered by distributed hooks."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class ContextDelivery(unittest.TestCase):
    def test_representative_cases(self):
        metrics = {}
        for agent in ("codex", "claude"):
            with self.subTest(agent=agent), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                hookdir = root / f".{agent}/hooks/shell"
                skilldir = root / (".agents/skills" if agent == "codex" else ".claude/skills")
                shutil.copytree(REPO / "hooks/shell", hookdir)
                shutil.copytree(REPO / "skills", skilldir)
                adapter = hookdir / "hook-io.sh"
                adapter.write_text(adapter.read_text().replace("[agent_name]", agent))

                def call(script, event, **kwargs):
                    payload = dict(hook_event_name=event, session_id="CONTEXT", cwd=str(root), **kwargs)
                    result = subprocess.run(
                        ["bash", str(hookdir / script)], input=json.dumps(payload),
                        text=True, capture_output=True, check=True,
                    )
                    self.assertEqual(result.stderr, "")
                    return json.loads(result.stdout) if result.stdout else None

                def visible(output):
                    if not output:
                        return ""
                    hook = output.get("hookSpecificOutput", {})
                    return hook.get("permissionDecisionReason") or hook.get("additionalContext") or output.get("systemMessage", "")

                no_context = {
                    "normal_implementation": call(
                        "load-required-contract.sh", "PreToolUse", tool_name="Edit",
                        tool_input={"file_path": "src/example.ts"},
                    ),
                    "document_change": call(
                        "load-required-contract.sh", "PreToolUse", tool_name="Edit",
                        tool_input={"file_path": "docs/notes.md"},
                    ),
                    "investigation": call(
                        "load-operation-context.sh", "PreToolUse", tool_name="Read",
                        tool_input={"file_path": "src/example.ts"},
                    ),
                    "tdd_from_doc": call(
                        "load-operation-context.sh", "UserPromptSubmit",
                        prompt="$tdd --from-doc",
                    ),
                    "other_agent": call(
                        "load-operation-context.sh", "PreToolUse", tool_name="Agent",
                        tool_input={("agent_type" if agent == "codex" else "subagent_type"): "explorer"},
                    ),
                }
                for case, output in no_context.items():
                    self.assertIsNone(output, case)
                    metrics[f"{agent}:{case}"] = {"hook_injections": 0, "hook_context_bytes": 0}

                role_key = "agent_type" if agent == "codex" else "subagent_type"
                difficulty_input = {
                    role_key: "difficulty-evaluator", "fork_turns": "none",
                    "prompt": json.dumps({"repository": str(root), "implementation_policy": "Implement value conversion."}),
                }
                first = call("load-operation-context.sh", "PreToolUse", tool_name="Agent", tool_input=difficulty_input)
                parent_text = visible(first)
                self.assertEqual(first["hookSpecificOutput"]["permissionDecision"], "deny")
                self.assertIn("実装方針", parent_text)
                self.assertNotIn("実装難度の独立評価", parent_text)
                self.assertIsNone(call("load-operation-context.sh", "PreToolUse", tool_name="Agent", tool_input=difficulty_input))
                child = call(
                    "load-operation-context.sh", "SubagentStart",
                    agent_id="difficulty", agent_type="difficulty-evaluator",
                )
                child_text = visible(child)
                self.assertIn("実装難度の独立評価", child_text)
                self.assertNotIn("サブエージェント", child_text)
                metrics[f"{agent}:difficulty"] = {
                    "hook_injections": 2,
                    "parent_hook_context_bytes": len(parent_text.encode()),
                    "child_hook_context_bytes": len(child_text.encode()),
                    "redundant_injections": 0,
                }

                contract = skilldir / "DIFFICULTY_CONTRACT.md"
                missing = contract.with_suffix(".missing")
                contract.rename(missing)
                unavailable = call(
                    "load-operation-context.sh", "SubagentStart",
                    agent_id="missing", agent_type="difficulty-evaluator",
                )
                self.assertIn("成功扱いせず失敗", visible(unavailable))
                missing.rename(contract)

                review_input = {role_key: "code-reviewer", "fork_turns": "none", "prompt": "{}"}
                first = call("load-operation-context.sh", "PreToolUse", tool_name="Agent", tool_input=review_input)
                parent_text = visible(first)
                self.assertEqual(first["hookSpecificOutput"]["permissionDecision"], "deny")
                self.assertIn("独立レビューの起動・結果処理", parent_text)
                self.assertNotIn("読み取り専用の独立コードレビュー", parent_text)
                self.assertIsNone(call("load-operation-context.sh", "PreToolUse", tool_name="Agent", tool_input=review_input))
                child = call(
                    "load-operation-context.sh", "SubagentStart",
                    agent_id="review", agent_type="code-reviewer",
                )
                child_text = visible(child)
                self.assertIn("読み取り専用の独立コードレビュー", child_text)
                self.assertNotIn("独立レビューの起動・結果処理", child_text)
                metrics[f"{agent}:review_repair"] = {
                    "hook_injections": 2,
                    "parent_hook_context_bytes": len(parent_text.encode()),
                    "child_hook_context_bytes": len(child_text.encode()),
                    "redundant_injections": 0,
                }

                blocked = call(
                    "deny-skill-source.sh", "PreToolUse", tool_name="Read",
                    tool_input={"file_path": str(skilldir / "DIFFICULTY_CONTRACT.md")},
                )
                self.assertEqual(blocked["hookSpecificOutput"]["permissionDecision"], "deny")
                blocked = call(
                    "deny-skill-source.sh", "PreToolUse", tool_name="Bash",
                    tool_input={"command": f"cat {skilldir / 'INDEPENDENT_REVIEW.md'}"},
                )
                self.assertEqual(blocked["hookSpecificOutput"]["permissionDecision"], "deny")

                settings = json.loads((REPO / ("codex/hooks.json" if agent == "codex" else "claude/settings.json")).read_text())
                for event in ("PreToolUse", "SubagentStart"):
                    self.assertTrue(any(
                        "load-operation-context.sh" in hook["command"]
                        for group in settings["hooks"][event] for hook in group["hooks"]
                    ))

        print("CONTEXT_METRICS=" + json.dumps(metrics, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    unittest.main()
