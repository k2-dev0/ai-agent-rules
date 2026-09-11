"""Measure model-visible context from every configured hook in representative flows."""
import json
from pathlib import Path
import re
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
                product = root / f".{agent}"
                hookdir = product / "hooks/shell"
                skilldir = root / (".agents/skills" if agent == "codex" else ".claude/skills")
                shutil.copytree(REPO / "hooks/shell", hookdir)
                shutil.copytree(REPO / "skills", skilldir)
                other_skilldir = root / (".claude/skills" if agent == "codex" else ".agents/skills")
                shutil.copytree(REPO / "skills", other_skilldir)
                for file in other_skilldir.rglob("*.md"):
                    file.write_text("WRONG_PRODUCT_CONTEXT")
                for file in skilldir.rglob("*.md"):
                    file.write_text(file.read_text().replace("[agent_name]", agent).replace("[skills_root]", str(skilldir)))
                shutil.copytree(REPO / agent / "agents", product / "agents")
                adapter = hookdir / "hook-io.sh"
                adapter.write_text(adapter.read_text().replace("[agent_name]", agent))
                settings = json.loads((REPO / ("codex/hooks.json" if agent == "codex" else "claude/settings.json")).read_text())

                def git(*args):
                    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()

                git("init", "-q")
                git("config", "user.name", "Test")
                git("config", "user.email", "test@example.invalid")
                (root / ".gitignore").write_text(".codex/\n.claude/\n.agents/\n")
                (root / "src").mkdir()
                (root / "src/example.ts").write_text("export const value = 1\n")
                (root / "docs").mkdir()
                (root / "docs/notes.md").write_text("notes\n")
                git("add", ".")
                git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "baseline")
                head = git("rev-parse", "HEAD")

                def matches(event, group, payload):
                    matcher = group.get("matcher")
                    if not matcher or matcher in ("", "*") or event in ("UserPromptSubmit", "Stop"):
                        return True
                    value = payload.get("tool_name", "") if event == "PreToolUse" else payload.get("agent_type", "")
                    return re.search(matcher, value) is not None

                def configured(event, session, event_cwd=None, **kwargs):
                    payload = dict(hook_event_name=event, session_id=session, cwd=str(event_cwd or root), **kwargs)
                    outputs = []
                    for group in settings["hooks"].get(event, []):
                        if not matches(event, group, payload):
                            continue
                        for handler in group["hooks"]:
                            script = re.search(r"shell/([\w-]+\.sh)", handler["command"])
                            self.assertIsNotNone(script, handler["command"])
                            result = subprocess.run(
                                ["bash", str(hookdir / script.group(1))],
                                input=json.dumps(payload), text=True, capture_output=True, check=True,
                            )
                            self.assertEqual(result.stderr, "")
                            if result.stdout:
                                outputs.append(json.loads(result.stdout))
                    return outputs

                def visible(outputs):
                    texts = []
                    for output in outputs:
                        hook = output.get("hookSpecificOutput", {})
                        text = hook.get("permissionDecisionReason") or hook.get("additionalContext") or output.get("systemMessage")
                        if text:
                            texts.append(text)
                    return texts

                def metric(case, outputs):
                    texts = visible(outputs)
                    metrics[f"{agent}:{case}"] = {
                        "hook_injections": len(texts),
                        "hook_context_bytes": sum(len(text.encode()) for text in texts),
                    }
                    return texts

                edit_name = "apply_patch" if agent == "codex" else "Edit"
                edit_input = {"command": "*** Update File: src/example.ts\n"} if agent == "codex" else {"file_path": "src/example.ts"}
                doc_input = {"command": "*** Update File: docs/notes.md\n"} if agent == "codex" else {"file_path": "docs/notes.md"}
                flow_cwd = root / "src"
                self.assertEqual(metric("normal_implementation", configured(
                    "PreToolUse", "FLOW", event_cwd=flow_cwd, tool_name=edit_name, tool_input=edit_input,
                )), [])
                self.assertEqual(metric("document_change", configured(
                    "PreToolUse", "DOC", tool_name=edit_name, tool_input=doc_input,
                )), [])
                self.assertEqual(metric("investigation", configured(
                    "PreToolUse", "READ", tool_name="Read", tool_input={"file_path": "src/example.ts"},
                )), [])
                self.assertEqual(metric("tdd_from_doc", configured(
                    "UserPromptSubmit", "DOCMODE", prompt="$tdd --from-doc",
                )), [])

                role_key = "agent_type" if agent == "codex" else "subagent_type"
                difficulty_input = {
                    role_key: "difficulty-evaluator", "fork_turns": "none",
                    "prompt": json.dumps({"repository": str(root), "implementation_policy": "Implement value conversion."}),
                }
                parent = configured("PreToolUse", "FLOW", event_cwd=flow_cwd, tool_name="Agent", tool_input=difficulty_input)
                parent_text = metric("difficulty_parent", parent)
                self.assertEqual(len(parent_text), 1)
                self.assertIn("サブエージェント", parent_text[0])
                self.assertNotIn("WRONG_PRODUCT_CONTEXT", parent_text[0])
                self.assertNotIn("実装難度の独立評価", parent_text[0])
                self.assertEqual(visible(configured("PreToolUse", "FLOW", event_cwd=flow_cwd, tool_name="Agent", tool_input=difficulty_input)), [])
                child_text = metric("difficulty_child", configured(
                    "SubagentStart", "FLOW", event_cwd=flow_cwd, agent_id="difficulty", agent_type="difficulty-evaluator",
                ))
                self.assertEqual(len(child_text), 1)
                self.assertIn("実装難度の独立評価", child_text[0])
                self.assertNotIn("WRONG_PRODUCT_CONTEXT", child_text[0])
                self.assertNotIn("サブエージェント", child_text[0])

                review_brief = {
                    "repository": str(root), "review_base": head, "review_head": head,
                    "requirements": "Review the requested value.",
                }
                review_input = {role_key: "code-reviewer", "fork_turns": "none", "prompt": json.dumps(review_brief)}
                parent = configured("PreToolUse", "FLOW", event_cwd=flow_cwd, tool_name="Agent", tool_input=review_input)
                parent_text = metric("review_repair_parent", parent)
                self.assertEqual(len(parent_text), 1)
                self.assertIn("独立レビューの起動・結果処理", parent_text[0])
                self.assertIn(f".{agent}/tmp", parent_text[0])
                self.assertNotIn("サブエージェント", parent_text[0])
                retry = configured("PreToolUse", "FLOW", event_cwd=flow_cwd, tool_name="Agent", tool_input=review_input)
                self.assertEqual(visible(retry), [])
                rewrites = [
                    output["hookSpecificOutput"]["updatedInput"]
                    for output in retry
                    if output.get("hookSpecificOutput", {}).get("updatedInput")
                ]
                self.assertEqual(len(rewrites), 1)
                rewritten_brief = json.loads(rewrites[0]["prompt"])
                self.assertRegex(rewritten_brief["request_id"], r"^[0-9a-f]{64}$")
                child_text = metric("review_repair_child", configured(
                    "SubagentStart", "FLOW", event_cwd=flow_cwd, agent_id="review", agent_type="code-reviewer",
                ))
                self.assertEqual(len(child_text), 1)
                self.assertIn("読み取り専用の独立コードレビュー", child_text[0])
                self.assertNotIn("独立レビューの起動・結果処理", child_text[0])

                contract = skilldir / "DIFFICULTY_CONTRACT.md"
                missing = contract.with_suffix(".missing")
                contract.rename(missing)
                unavailable = visible(configured(
                    "SubagentStart", "MISSING", agent_id="missing", agent_type="difficulty-evaluator",
                ))
                self.assertEqual(len(unavailable), 1)
                self.assertIn("成功扱いせず失敗", unavailable[0])
                missing.rename(contract)

                relative = skilldir.relative_to(root) / "INDEPENDENT_REVIEW.md"
                for command in (
                    f"cat {relative}",
                    f"git show HEAD:{relative}",
                    f"git cat-file -p HEAD:{relative}",
                    f"cat {str(relative)[:-2]}[m]d",
                    f"cat {relative.parent}/INDEPENDENT_REVIEW.*",
                    f"rg role {relative.parent.parent}",
                ):
                    outputs = configured("PreToolUse", "PREREAD", tool_name="Bash", tool_input={"command": command})
                    self.assertTrue(any(
                        output.get("hookSpecificOutput", {}).get("permissionDecision") == "deny"
                        and "先読み" in output["hookSpecificOutput"].get("permissionDecisionReason", "")
                        for output in outputs
                    ), command)

                model_switch = configured(
                    "PreToolUse", "MODEL_SWITCH_READ", tool_name="Read",
                    tool_input={"file_path": str(skilldir / "MODEL_SWITCH.md")},
                )
                model_switch_denied = any(
                    output.get("hookSpecificOutput", {}).get("permissionDecision") == "deny"
                    and "先読み" in output["hookSpecificOutput"].get("permissionDecisionReason", "")
                    for output in model_switch
                )
                self.assertEqual(model_switch_denied, agent == "codex")

        print("CONTEXT_METRICS=" + json.dumps(metrics, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    unittest.main()
