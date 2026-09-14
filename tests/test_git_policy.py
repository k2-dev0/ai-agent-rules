"""Run the distributed Git/path guard and execute its accepted reads in fixtures."""
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class GitPolicy(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="git-policy-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / "repo"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.root / "file.txt").write_text("one\n")
        self.git("add", "file.txt")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture")
        self.head = self.git("rev-parse", "HEAD").strip()
        for agent in ("claude", "codex"):
            hooks = self.root / f".{agent}/hooks/shell"
            shutil.copytree(REPO / "hooks/shell", hooks)
            adapter = hooks / "hook-io.sh"
            adapter.write_text(adapter.read_text().replace("[agent_name]", agent))

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True)

    def guard(self, agent, tool, inputs):
        payload = dict(hook_event_name="PreToolUse", cwd=str(self.root), tool_name=tool, tool_input=inputs)
        script = self.root / f".{agent}/hooks/shell/protect-git.sh"
        result = subprocess.run(["bash", str(script)], input=json.dumps(payload), text=True, capture_output=True, check=True)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)["hookSpecificOutput"] if result.stdout else {}

    def test_read_commands_execute_without_metadata_changes(self):
        commands = [
            "git log --oneline", "git status --short", "git diff --stat", "git show --format=short HEAD",
            "git ls-files", "git grep one", "git rev-parse HEAD", "git merge-base HEAD HEAD",
            "git branch --list", "git tag --list", "git remote -v", "git check-ignore --no-index -v file.txt",
            "git cat-file -p HEAD", "git count-objects", "git worktree list", "git blame file.txt",
            "command git status", "git -C . log -1 --format=%H",
        ]
        before = {str(p.relative_to(self.root)): p.read_bytes() for p in (self.root / ".git").rglob("*") if p.is_file()}
        for agent in ("claude", "codex"):
            for command in commands:
                with self.subTest(agent=agent, command=command):
                    hook = self.guard(agent, "Bash", {"command": command})
                    self.assertEqual(hook.get("permissionDecision"), "allow", hook)
                    result = subprocess.run(shlex.split(hook["updatedInput"]["command"]), cwd=self.root, capture_output=True)
                    self.assertIn(result.returncode, (0, 1) if "check-ignore" in command else (0,), result.stderr)
        after = {str(p.relative_to(self.root)): p.read_bytes() for p in (self.root / ".git").rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_write_and_external_program_options_are_denied(self):
        commands = [
            "git add .", "git add file.txt extra.txt", "git add -f file.txt", "git commit -m change", "git rebase HEAD", "git reset --hard", "git config a.b c",
            "git fetch", "git push", "git statusanything", "git alias-name", "git branch topic", "git tag name",
            "git worktree add /tmp/other", "git remote add remote path", "git log --output=out", "git diff --out=out",
            "git diff --ext-diff", "git log --textconv", "git log --show-signature", "git log --format=%G?",
            "git branch --list --format=%(signature)", "git cat-file --filters HEAD:file.txt",
            "git grep --open-files-in-pager=sh one", "git grep -n --open-files-in-pager=sh one",
            "git branch --format --list topic", "git tag --format --list topic",
            "git -c core.pager=sh log", "env GIT_CONFIG_COUNT=1 git status", "sudo git add file.txt",
            "env PATH=/tmp git add file.txt", "FOO=bar /usr/bin/git add file.txt",
            "git status; git add file.txt", "git status > .git/HEAD", "git log $(touch bad)",
        ]
        for agent in ("claude", "codex"):
            for command in commands:
                with self.subTest(agent=agent, command=command):
                    self.assertEqual(self.guard(agent, "Bash", {"command": command}).get("permissionDecision"), "deny")

    def test_optional_context_option_cannot_hide_file_output(self):
        (self.root / "file.txt").write_text("two\n")
        target = self.root / "unexpected.patch"
        for agent in ("claude", "codex"):
            hook = self.guard(agent, "Bash", {"command": "git diff -U --output=" + str(target)})
            if hook.get("permissionDecision") == "allow":
                subprocess.run(shlex.split(hook["updatedInput"]["command"]), cwd=self.root, capture_output=True)
            self.assertFalse(target.exists(), "an optional -U argument hid a file-writing option")
            self.assertEqual(hook.get("permissionDecision"), "deny")

    def test_configured_external_helpers_do_not_run(self):
        sentinel = self.root / "helper-ran"
        helper = self.root / "helper.sh"
        helper.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(sentinel))}\n")
        helper.chmod(0o755)
        self.git("config", "core.fsmonitor", str(helper))
        self.git("config", "diff.external", str(helper))
        self.git("config", "diff.fixture.textconv", str(helper))
        (self.root / ".gitattributes").write_text("*.txt diff=fixture\n")
        (self.root / "file.txt").write_text("two\n")
        for command in ("git status --short", "git diff", "git show HEAD:file.txt"):
            hook = self.guard("codex", "Bash", {"command": command})
            result = subprocess.run(shlex.split(hook["updatedInput"]["command"]), cwd=self.root, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(sentinel.exists())

    def test_add_commit_use_one_file_and_suppress_executable_config(self):
        for agent in ("claude", "codex"):
            (self.root / "file.txt").write_text(agent + "\n")
            helper = self.root / ".git/hooks/pre-commit"
            sentinel = self.root / "hook-ran"
            helper.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(sentinel))}\n")
            helper.chmod(0o755)
            self.git("config", "commit.gpgSign", "true")
            for command in ("git add -- file.txt", "git commit -m 'file.txt: 変更'"):
                hook = self.guard(agent, "Bash", {"command": command})
                self.assertEqual(hook.get("permissionDecision"), "allow", hook)
                rewritten = hook["updatedInput"]["command"]
                if agent == "codex" and shutil.which("codex"):
                    policy = subprocess.check_output(["codex", "execpolicy", "check", "--rules", str(REPO / "codex/rules/default.rules"), "--", *shlex.split(rewritten)], stderr=subprocess.DEVNULL, text=True)
                    self.assertEqual(json.loads(policy).get("decision"), "allow")
                elif agent == "claude":
                    permissions = json.loads((REPO / "claude/settings.local.json").read_text())["permissions"]["allow"]
                    self.assertTrue(any(p.startswith("Bash(") and p.endswith(":*)") and rewritten.startswith(p[5:-3] + " ") for p in permissions))
                result = subprocess.run(shlex.split(hook["updatedInput"]["command"]), cwd=self.root, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.git("diff", "HEAD~", "HEAD", "--name-only").strip(), "file.txt")
            self.assertFalse(sentinel.exists())
        (self.root / ".gitattributes").write_text("file.txt filter=external\n")
        self.assertEqual(self.guard("codex", "Bash", {"command": "git add file.txt"}).get("permissionDecision"), "deny")

    def test_indirect_paths_and_parents_are_denied(self):
        (self.root / "alias").symlink_to(self.root / ".git", target_is_directory=True)
        (self.root.parent / "other/.git").mkdir(parents=True)
        for agent in ("claude", "codex"):
            for path in (".git/HEAD", "alias/HEAD", "file/../.git/HEAD", ".GIT/config", str(self.root), ".."):
                with self.subTest(agent=agent, path=path):
                    self.assertEqual(self.guard(agent, "Edit", {"file_path": path}).get("permissionDecision"), "deny")
            for command in ("rm -rf .", "rm -rf ../other", "mv ../repo ../moved", "cp -n -- file.txt alias/HEAD", "ln -s -- file.txt .git/new", "chmod -R 777 alias", "touch .git/new"):
                self.assertEqual(self.guard(agent, "Bash", {"command": command}).get("permissionDecision"), "deny")
            self.assertEqual(self.guard(agent, "apply_patch", {"command": "*** Update File: file.txt\n*** Move to: alias/HEAD\n"}).get("permissionDecision"), "deny")
            self.assertEqual(self.guard(agent, "Edit", {"file_path": "file.txt"}), {})

    def test_worktree_pointer_and_common_directory_are_protected(self):
        worktree = Path(self.temp.name) / "worktree"
        self.git("worktree", "add", "--detach", "-q", str(worktree), "HEAD")
        original = self.root
        self.root = worktree
        for agent in ("claude", "codex"):
            shutil.copytree(original / f".{agent}", worktree / f".{agent}")
            for path in (str(original / ".git/HEAD"), str(original), ".git"):
                self.assertEqual(self.guard(agent, "Write", {"file_path": path}).get("permissionDecision"), "deny")

    def test_both_configurations_dispatch_to_the_guard(self):
        for agent, config in (("codex", "codex/hooks.json"), ("claude", "claude/settings.json")):
            settings = json.loads((REPO / config).read_text())
            for tool in ("Bash", "apply_patch") if agent == "codex" else ("Bash", "Edit", "Write", "NotebookEdit", "MultiEdit"):
                handlers = [h for group in settings["hooks"]["PreToolUse"] if re.search(group["matcher"], tool) for h in group["hooks"]]
                self.assertTrue(any("protect-git.sh" in h["command"] for h in handlers), (agent, tool))


if __name__ == "__main__":
    unittest.main()
