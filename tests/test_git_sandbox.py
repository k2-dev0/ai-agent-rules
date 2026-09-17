"""Exercise the installed Codex OS sandbox against disposable metadata only."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class GitSandbox(unittest.TestCase):
    def test_filesystem_protection(self):
        cli = shutil.which("codex")
        self.assertIsNotNone(cli, "Codex CLI is required for the OS sandbox probe")
        with tempfile.TemporaryDirectory(prefix="git-sandbox-") as directory:
            temp = Path(directory).resolve()
            root = temp / "repo"
            root.mkdir()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            metadata = root / ".git/objects/sentinel"
            metadata.write_text("unchanged")
            (root / ".git/HEAD").write_text("ref: refs/heads/main\n")
            (root / ".codex").mkdir()
            shutil.copyfile(REPO / "codex/config.toml", root / ".codex/config.toml")
            (root / ".codex/prompt").mkdir()
            prompt = root / ".codex/prompt/branch-example-prompt.md"
            prompt.write_text("original")
            (root / ".codex/e2e").mkdir()
            e2e = root / ".codex/e2e/.e2e.md"
            e2e.write_text("original")
            (root / ".claude/hooks/shell").mkdir(parents=True)
            controller = root / ".claude/hooks/shell/guard.sh"
            controller.write_text("unchanged")
            (root / ".claude/tmp").mkdir()
            state = root / ".claude/tmp/independent-review.TEST.json"
            state.write_text("unchanged")
            (root / "alias").symlink_to(root / ".git", target_is_directory=True)
            (temp / "source").write_text("overwrite")
            program = temp / "attack.py"
            program.write_text('''import os, pathlib, shutil, sys
root = pathlib.Path(sys.argv[1])
op = sys.argv[2]
target = root / ".git/objects/sentinel"
try:
    if op == "write": target.write_text("changed")
    elif op == "copy": shutil.copyfile(root.parent / "source", target)
    elif op == "symlink": (root / "alias/objects/sentinel").write_text("changed")
    elif op == "delete": target.unlink()
    elif op == "new": (root / ".git/new").write_text("new")
    elif op == "rename-git": (root / ".git").rename(root / "metadata-moved")
    elif op == "rename-parent": root.rename(root.parent / "moved")
    elif op == "hardlink":
        os.link(target, root / "hardlink")
        (root / "hardlink").write_text("changed")
    elif op == "controller": (root / ".claude/hooks/shell/guard.sh").write_text("disabled")
    elif op == "review-state": (root / ".claude/tmp/independent-review.TEST.json").write_text("forged")
    elif op == "prompt": (root / ".codex/prompt/branch-example-prompt.md").write_text("updated")
    elif op == "e2e": (root / ".codex/e2e/.e2e.md").write_text("updated")
    elif op == "ordinary": (root / "ordinary").write_text("allowed")
    else: raise ValueError(op)
except PermissionError:
    sys.exit(2 if op in ("ordinary", "prompt", "e2e") else 0)
except OSError as error:
    if error.errno in (1, 13, 16, 30): sys.exit(2 if op in ("ordinary", "prompt", "e2e") else 0)
    raise
else:
    sys.exit(0 if op in ("ordinary", "prompt", "e2e") else 3)
''')
            # Pass the actual permission entries explicitly: sandbox's profile
            # resolver does not prove trusted project config loading.
            source = (root / ".codex/config.toml").read_text()
            sections = re.split(r"(?m)^\[", source)
            policy = {}
            for section in sections[1:]:
                header, body = section.split("]", 1)
                if header.startswith("permissions.distributed"):
                    table = policy
                    for key in header.split(".")[1:]:
                        table = table.setdefault(key.strip('"'), {})
                    for line in body.splitlines():
                        line = line.split("#", 1)[0].strip()
                        if line:
                            key, value = line.split("=", 1)
                            table[key.strip().strip('"')] = json.loads(value.strip())
            def inline(value):
                if isinstance(value, dict):
                    return "{" + ",".join(json.dumps(k) + "=" + inline(v) for k, v in value.items()) + "}"
                return json.dumps(value)
            base = [cli, "sandbox", "-C", str(root), "-P", "distributed", "-c", "permissions=" + inline(policy)]
            for operation in ("ordinary", "prompt", "e2e", "write", "copy", "symlink", "delete", "new", "rename-git", "rename-parent", "hardlink", "controller", "review-state"):
                with self.subTest(operation=operation):
                    result = subprocess.run([*base, "--", sys.executable, str(program), str(root), operation], capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertTrue(root.exists(), "repository parent was moved")
                    self.assertEqual(metadata.read_text(), "unchanged")
                    self.assertEqual(controller.read_text(), "unchanged")
                    self.assertEqual(state.read_text(), "unchanged")
                    self.assertFalse((root / ".git/new").exists())
                    if operation == "prompt":
                        self.assertEqual(prompt.read_text(), "updated")
                    if operation == "e2e":
                        self.assertEqual(e2e.read_text(), "updated")


if __name__ == "__main__":
    unittest.main()
