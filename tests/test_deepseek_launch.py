"""Credential import keeps rc output and key values away from MCP transport."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
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

    def run_launcher(self, background_terminal=False, input=None):
        program = ('import json, os; print(json.dumps({"key_present": bool(os.getenv("DEEPSEEK_API_KEY")), '
                   '"key_matches": os.getenv("DEEPSEEK_API_KEY") == ' + repr(CANARY) + '}))')
        command = ["bash", str(self.root / "deepseek-launch.sh"), "python3", "-c", program]
        if background_terminal:
            command = [sys.executable, "-c", '''
import fcntl, os, pty, signal, subprocess, sys, termios
master, slave = pty.openpty()
os.setsid()
fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
os.tcsetpgrp(slave, os.getpgrp())
child = subprocess.Popen(sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         stdin=subprocess.PIPE, preexec_fn=os.setpgrp)
try:
    out, err = child.communicate(timeout=3)
except subprocess.TimeoutExpired:
    os.killpg(child.pid, signal.SIGKILL)
    child.communicate()
    sys.exit("background MCP launcher stalled on terminal job control")
sys.stdout.buffer.write(out)
sys.stderr.buffer.write(err)
sys.exit(child.returncode)
''', *command]
        result = subprocess.run(command, env=self.env, text=True, capture_output=True,
                                input=input, timeout=8)
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

    @unittest.skipUnless(shutil.which("zsh") and os.name == "posix", "POSIX zsh required")
    def test_rc_key_loads_in_background_terminal_process(self):
        (self.root / ".zshrc").write_text("export DEEPSEEK_API_KEY=" + CANARY + "\n")
        result = self.run_launcher(background_terminal=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"key_present": True, "key_matches": True})

    @unittest.skipUnless(shutil.which("zsh"), "zsh not installed")
    def test_rc_cannot_consume_mcp_stdin(self):
        (self.root / ".zshrc").write_text("read -r line\nexport DEEPSEEK_API_KEY=" + CANARY + "\n")
        (self.root / "mcp-protected.sh").write_text('IFS= read -r line\nprintf "%s\\n" "$line"\n')
        result = self.run_launcher(input="MCP_INITIALIZE\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "MCP_INITIALIZE\n")


if __name__ == "__main__":
    unittest.main()
