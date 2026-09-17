"""Run both distributed outside/MCP entries under a real OS filesystem fence.

Run outside an existing agent sandbox; nested sandbox failure is NOT a pass.
Only disposable repositories and loopback sockets are used.
"""
import ast
import json
import os
from pathlib import Path
import shlex
import shutil
import re
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
PROGRAM = '''import os, pathlib, shutil, socket, subprocess, sys
root = pathlib.Path(sys.argv[1])
op = sys.argv[2]
target = root / ".git/objects/sentinel"
if op == "ordinary": (root / "ordinary").write_text("allowed")
elif op == "outside": (root.parent / "outside").write_text("allowed")
elif op == "network":
    with socket.socket() as connection: connection.bind(("127.0.0.1", 0))
elif op == "write": target.write_text("changed")
elif op == "copy": shutil.copyfile(root.parent / "source", target)
elif op == "copy-tree": shutil.copytree(root.parent / "copy-source", root / ".git", dirs_exist_ok=True)
elif op == "symlink": (root / "alias/objects/sentinel").write_text("changed")
elif op == "delete": target.unlink()
elif op == "new": (root / ".git/new").write_text("new")
elif op == "rename-git": (root / ".git").rename(root / "metadata-moved")
elif op == "rename-parent": root.rename(root.parent / "moved")
elif op == "hardlink":
    os.link(target, root / "hardlink")
    (root / "hardlink").write_text("changed")
elif op == "controller": (root / ".codex/hooks/shell/git-policy.py").write_text("disabled")
elif op == "new-controller": (root / ".mcp.json").write_text("disabled")
elif op == "review-state": (root / ".claude/tmp/independent-review.TEST.json").write_text("forged")
elif op == "script-git": subprocess.run(["git", "config", "fixture.unsafe", "changed"], cwd=root, check=True)
else: raise ValueError(op)
'''


class ProtectedExec(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="protected-exec-")
        self.addCleanup(temp.cleanup)
        self.parent = Path(temp.name).resolve()
        self.root = self.parent / "repo"
        self.root.mkdir()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / ".git/objects/sentinel").write_text("unchanged")
        (self.parent / "source").write_text("overwrite")
        (self.parent / "copy-source/objects").mkdir(parents=True)
        (self.parent / "copy-source/objects/sentinel").write_text("overwrite")
        (self.root / "alias").symlink_to(self.root / ".git", target_is_directory=True)
        self.program = self.parent / "attack.py"
        self.program.write_text(PROGRAM)
        for agent in ("claude", "codex"):
            hooks = self.root / f".{agent}/hooks"
            shutil.copytree(REPO / "hooks", hooks)
            adapter = hooks / "shell/hook-io.sh"
            adapter.write_text(adapter.read_text().replace("[agent_name]", agent))
        (self.root / ".claude/tmp").mkdir()
        (self.root / ".claude/tmp/independent-review.TEST.json").write_text("unchanged")

    def run_entry(self, agent, entry, argv, **kwargs):
        args = ["bash", f".{agent}/hooks/shell/{entry}.sh"]
        args.extend([shlex.join(argv)] if entry == "outside" else argv)
        return subprocess.run(args, cwd=self.root, capture_output=True, text=True, **kwargs)

    def snapshot(self):
        result = {}
        for path in (self.root / ".git").rglob("*"):
            info = path.lstat()
            result[str(path.relative_to(self.root))] = (path.read_bytes() if path.is_file() else None, info.st_mode, info.st_nlink, info.st_ino, info.st_mtime_ns, info.st_ctime_ns)
        return result

    def test_both_entries_allow_work_and_block_actual_metadata_mutations(self):
        before = self.snapshot()
        guard = self.root / ".codex/hooks/shell/git-policy.py"
        guard_before = guard.read_bytes()
        for agent in ("claude", "codex"):
            for entry in ("outside", "mcp-protected"):
                for op in ("ordinary", "outside", "network", "write", "copy", "copy-tree", "symlink", "delete", "new", "rename-git", "rename-parent", "hardlink", "controller", "new-controller", "script-git", "review-state"):
                    with self.subTest(agent=agent, entry=entry, op=op):
                        result = self.run_entry(agent, entry, ["python3", str(self.program), str(self.root), op])
                        if op in ("ordinary", "outside", "network"):
                            self.assertEqual(result.returncode, 0, result.stderr)
                        else:
                            self.assertNotEqual(result.returncode, 0, "OS fence did not stop " + op)
                            self.assertRegex(result.stderr, r"Operation not permitted|Permission denied|Read-only file system|Device or resource busy")
                        self.assertEqual(self.snapshot(), before)
                        self.assertEqual(guard.read_bytes(), guard_before)
                        self.assertFalse((self.root / ".mcp.json").exists())
                        self.assertFalse((self.root / "hardlink").exists())
                        self.assertEqual((self.root / ".claude/tmp/independent-review.TEST.json").read_text(), "unchanged")
        self.assertEqual((self.parent / "outside").read_text(), "allowed")
        self.assertEqual((self.root / "ordinary").read_text(), "allowed")

    def test_preexisting_hardlink_refuses_before_program_execution(self):
        os.link(self.root / ".git/objects/sentinel", self.parent / "alias")
        for agent in ("claude", "codex"):
            result = self.run_entry(agent, "outside", ["touch", str(self.root / "must-not-run")])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("hardlink", result.stderr)
        self.assertFalse((self.root / "must-not-run").exists())

    def test_symlink_inside_metadata_refuses_before_program_execution(self):
        (self.root / ".git/alias").symlink_to(self.parent / "source")
        result = self.run_entry("codex", "outside", ["touch", str(self.root / "must-not-run")])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr)
        self.assertFalse((self.root / "must-not-run").exists())

    def test_shell_payload_cannot_use_compounds_or_unapproved_git(self):
        for agent in ("claude", "codex"):
            for command in ("touch unexpected; pwd", "git reset --hard", "git config key.value changed"):
                result = subprocess.run(["bash", f".{agent}/hooks/shell/outside.sh", command], cwd=self.root, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "unexpected").exists())

    def test_missing_backend_never_falls_back_to_unprotected_execution(self):
        # Invoke the policy builder with a simulated unsupported platform without
        # replacing any real executable or changing the machine configuration.
        import runpy
        module = runpy.run_path(str(REPO / "hooks/shell/protected-exec.py"))
        from unittest.mock import patch
        with patch("sys.platform", "unsupported"), self.assertRaises(ValueError):
            module["sandbox_command"]([self.root / ".git"], ["touch", "unexpected"])
        self.assertFalse((self.root / "unexpected").exists())

    def test_configured_mcp_launch_preserves_arguments_and_stdio(self):
        fake_bin = self.parent / "bin"
        fake_bin.mkdir()
        driver = self.parent / "stdio.py"
        driver.write_text('import json, os, pathlib, sys\n'
                          'root = pathlib.Path.cwd()\n'
                          'try: (root / ".git/objects/sentinel").write_text("changed")\n'
                          'except PermissionError: protected = True\n'
                          'else: protected = False\n'
                          'print(json.dumps({"argv": sys.argv[1:], "input": sys.stdin.read(), "agent": os.environ.get("CONTEXT_AGENT"), "protected": protected}))\n')
        context = self.parent / "context dictionary"
        for program in (fake_bin / "npx", context / "node_modules/.bin/tsx"):
            program.parent.mkdir(parents=True, exist_ok=True)
            program.write_text("#!/bin/sh\nexec python3 " + shlex.quote(str(driver)) + ' "$@"\n')
            program.chmod(0o755)
        for agent in ("claude", "codex"):
            if agent == "claude":
                configs = json.loads((REPO / "claude/.mcp.json").read_text())["mcpServers"]
            else:
                source = (REPO / "codex/config.toml").read_text()
                configs = {}
                for name in ("chrome-devtools", "context-dictionary"):
                    section = source.split("[mcp_servers." + name + "]\n", 1)[1].split("\n[", 1)[0]
                    # These shipped fields are basic strings/lists; strict TOML
                    # parsing is independently exercised by verify-all's CLI.
                    configs[name] = dict(command=ast.literal_eval(re.search(r'^command = (.+)$', section, re.M)[1]), args=ast.literal_eval(re.search(r'^args = (\[.*?\])\n', section, re.M | re.S)[1]))
            for name, config in configs.items():
                with self.subTest(agent=agent, server=name):
                    args = [a.replace("__CONTEXT_DICTIONARY_ROOT__", str(context)) for a in config["args"]]
                    self.assertEqual(config["command"], "bash")
                    self.assertEqual(args[0], f".{agent}/hooks/shell/mcp-protected.sh")
                    environment = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ["PATH"], CONTEXT_AGENT=agent)
                    result = subprocess.run([config["command"], *args], cwd=self.root, env=environment, input="stdio request", text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    output = json.loads(result.stdout)
                    self.assertEqual(output, dict(argv=args[2:], input="stdio request", agent=agent, protected=True))

    def test_gitdir_and_commondir_targets_are_protected(self):
        metadata = self.parent / "metadata"
        shutil.move(str(self.root / ".git"), metadata)
        common = self.parent / "common"
        common.mkdir()
        sentinel = common / "sentinel"
        sentinel.write_text("unchanged")
        (metadata / "commondir").write_text("../common\n")
        (self.root / ".git").write_text("gitdir: " + str(metadata) + "\n")
        for agent in ("claude", "codex"):
            for target in (metadata / "objects/sentinel", sentinel):
                result = self.run_entry(agent, "mcp-protected", ["python3", "-c", "from pathlib import Path; Path(" + repr(str(target)) + ").write_text('changed')"])
                self.assertNotEqual(result.returncode, 0)
                self.assertRegex(result.stderr, r"Operation not permitted|Permission denied|Read-only file system")
                self.assertEqual(target.read_text(), "unchanged")


if __name__ == "__main__":
    unittest.main()
