"""Credential import keeps rc output and key values away from MCP transport."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
CANARY = "launch-test-key-not-a-real-secret"


class Launch(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copyfile(REPO / "hooks/shell/deepseek-launch.sh", self.root / "deepseek-launch.sh")
        # Only the final protected entry is replaced; its real OS effect is
        # tested by test_protected_exec and probe_deepseek_bridge.
        (self.root / "mcp-protected.sh").write_text('exec "$@"\n')
        self.env = {k: v for k, v in os.environ.items() if k != "DEEPSEEK_API_KEY"}
        self.env["ZDOTDIR"] = str(self.root)

    def run_launcher(self):
        program = ('import json, os; print(json.dumps({"key_present": bool(os.getenv("DEEPSEEK_API_KEY")), '
                   '"key_matches": os.getenv("DEEPSEEK_API_KEY") == ' + repr(CANARY) + '}))')
        result = subprocess.run(["bash", str(self.root / "deepseek-launch.sh"), "python3", "-c", program],
                                env=self.env, text=True, capture_output=True)
        self.assertNotIn(CANARY, result.stdout + result.stderr)
        return result

    def test_inherited_key_does_not_load_rc(self):
        self.env["DEEPSEEK_API_KEY"] = CANARY
        (self.root / ".zshrc").write_text('exit 3\n')
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"key_present": True, "key_matches": True})

    @unittest.skipUnless(shutil.which("zsh"), "zsh not installed")
    def test_rc_key_and_banners_never_reach_transport(self):
        (self.root / ".zshrc").write_text("set -x\nexport DEEPSEEK_API_KEY=" + CANARY + "\necho RC_BANNER\n")
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("RC_BANNER", result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout), {"key_present": True, "key_matches": True})

    @unittest.skipUnless(shutil.which("zsh"), "zsh not installed")
    def test_missing_key_fails_before_bridge_launch(self):
        (self.root / ".zshrc").write_text("echo RC_BANNER\n")
        result = self.run_launcher()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("not configured", result.stderr)


if __name__ == "__main__":
    unittest.main()
