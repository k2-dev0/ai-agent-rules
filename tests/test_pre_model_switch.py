"""Verify Baton's PreModelSwitch contract for the distributed hook."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class PreModelSwitch(unittest.TestCase):
    def test_injection_and_receipts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            script = root / ".codex/hooks/shell/pre-model-switch.sh"
            script.parent.mkdir(parents=True)
            shutil.copy2(REPO / "hooks/shell/pre-model-switch.sh", script)
            skill = root / ".agents/skills/MODEL_SWITCH.md"
            skill.parent.mkdir(parents=True)
            skill.write_text("SWITCH_GUIDANCE_V1\n")
            nested = root / "src"
            nested.mkdir()
            subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)

            def event(thread="thread-1", turn="turn-1", model="new-model", effort="high", config=None):
                return {
                    "event": "PreModelSwitch", "threadId": thread, "turnId": turn, "cwd": str(nested),
                    "from": {"model": "old-model", "effort": "medium"},
                    "to": {"model": model, "config": config or {"effort": effort}},
                }

            def call(payload):
                return subprocess.run(
                    [str(script)], input=json.dumps(payload), text=True, capture_output=True,
                )

            first = call(event())
            self.assertEqual(first.returncode, 2)
            self.assertEqual(first.stdout, "")
            self.assertIn("PRE_MODEL_SWITCH_CONTEXT", first.stderr)
            self.assertIn("SWITCH_GUIDANCE_V1", first.stderr)
            self.assertEqual(call(event(turn="turn-2")).returncode, 0)

            self.assertEqual(call(event(thread="thread-2")).returncode, 2)
            skill.write_text("SWITCH_GUIDANCE_V2\n")
            changed = call(event(turn="turn-3"))
            self.assertEqual(changed.returncode, 2)
            self.assertIn("SWITCH_GUIDANCE_V2", changed.stderr)
            self.assertEqual(call(event(turn="turn-4")).returncode, 0)

            noop = event(thread="noop", model="old-model", config={"effort": "medium"})
            self.assertEqual(call(noop).returncode, 0)
            setting_change = event(thread="setting", model="old-model", config={"effort": "medium", "summary": "concise"})
            self.assertEqual(call(setting_change).returncode, 2)

            skill.write_text("x" * 49153)
            oversized = call(event(thread="oversized"))
            self.assertEqual(oversized.returncode, 2)
            self.assertIn("上限", oversized.stderr)
            skill.write_text("SWITCH_GUIDANCE_V3\\n")

            for invalid in (
                {},
                {**event(thread="bad-event"), "event": "Other"},
                {**event(thread="bad-thread"), "threadId": ""},
                {**event(thread="bad-config"), "to": {"model": "new-model", "config": {}}},
            ):
                result = call(invalid)
                self.assertEqual(result.returncode, 2)
                self.assertIn("不正", result.stderr)

            skill.unlink()
            missing = call(event(thread="missing"))
            self.assertEqual(missing.returncode, 2)
            self.assertIn("見つかりません", missing.stderr)


if __name__ == "__main__":
    unittest.main()
