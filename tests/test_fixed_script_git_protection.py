"""Run shipped write scripts against normal paths and metadata aliases."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class FixedScriptGitProtection(unittest.TestCase):
    def fixture(self, parent, agent):
        root = Path(parent).resolve() / agent
        root.mkdir()
        # A fixture must not inherit workstation-wide filter definitions.
        self.environment = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        product = root / ("." + agent)
        skills = root / (".agents/skills" if agent == "codex" else ".claude/skills")
        shutil.copytree(REPO / "hooks", product / "hooks")
        shutil.copytree(REPO / "skills", skills)
        for name in ("e2e/apply-e2e-plan.sh", "tdd/mark-prompt-done.sh", "polish/capture-scope.sh", "polish/quality-gate.sh", "rebase/rebase.sh"):
            file = skills / name
            file.write_text(file.read_text().replace("[agent_name]", agent))
        return root, product, skills

    def git(self, root, *args):
        return subprocess.check_output(["git", "-C", str(root), *args], env=self.environment, text=True).strip()

    def commits(self, root):
        self.git(root, "config", "user.name", "Fixture")
        self.git(root, "config", "user.email", "fixture@example.invalid")
        (root / ".gitattributes").write_text("*.txt filter=fixture\n")
        self.git(root, "add", ".gitattributes")
        self.git(root, "commit", "-qm", "base")
        base = self.git(root, "rev-parse", "HEAD")
        result = []
        for number in (1, 2):
            (root / "file.txt").write_text(str(number) + "\n")
            self.git(root, "add", "file.txt")
            self.git(root, "commit", "-qm", "file.txt: 変更")
            result.append(self.git(root, "rev-parse", "HEAD"))
        return base, result

    def test_hardlinked_plan_and_index_do_not_modify_metadata(self):
        for agent in ("claude", "codex"):
            with self.subTest(agent=agent), tempfile.TemporaryDirectory() as parent:
                root, product, skills = self.fixture(parent, agent)
                sentinel = root / ".git/script-sentinel"
                original = "- [ ] branch-example-prompt.md\n"
                sentinel.write_text(original)
                draft = root / "draft.md"
                draft.write_text("replacement plan\n")
                for relative, script, args in (
                    ("e2e/.e2e.md", "e2e/apply-e2e-plan.sh", [str(draft)]),
                    ("prompt/.prompt.md", "tdd/mark-prompt-done.sh", ["example"]),
                ):
                    target = product / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    os.link(sentinel, target)
                    result = subprocess.run(["bash", str(skills / script), *args], cwd=root, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(sentinel.read_text(), original)
                    target.unlink()
                    target.write_text(original)
                    result = subprocess.run(["bash", str(skills / script), *args], cwd=root, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(target.read_text(), draft.read_text() if relative.startswith("e2e/") else original.replace("[ ]", "[x]"))

    def test_bootstrap_rejects_metadata_as_product_root(self):
        for agent in ("claude", "codex"):
            with self.subTest(agent=agent), tempfile.TemporaryDirectory() as parent:
                root = Path(parent).resolve()
                subprocess.run(["git", "init", "-q", str(root)], check=True)
                sentinel = root / ".git/script-sentinel"
                sentinel.write_text("keep [agent_name]\n")
                (root / ("." + agent)).symlink_to(root / ".git", target_is_directory=True)
                result = subprocess.run(["bash", str(REPO / "skills/bootstrap/bootstrap.sh"), agent], cwd=root, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(sentinel.read_text(), "keep [agent_name]\n")

    def test_bootstrap_rejects_nested_links_before_any_replacement(self):
        for agent in ("claude", "codex"):
            for link_kind in ("symlink", "hardlink"):
                with self.subTest(agent=agent, link=link_kind), tempfile.TemporaryDirectory() as parent:
                    root, product, skills = self.fixture(parent, agent)
                    sentinel = root / ".git/script-sentinel"
                    sentinel.write_text("keep [agent_name]\n")
                    normal = product / "normal.md"
                    normal.write_text("keep [agent_name]\n")
                    alias = product / "metadata-alias.md"
                    if link_kind == "symlink": alias.symlink_to(sentinel)
                    else: os.link(sentinel, alias)
                    result = subprocess.run(["bash", str(skills / "bootstrap/bootstrap.sh"), agent], cwd=root, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(sentinel.read_text(), "keep [agent_name]\n")
                    self.assertEqual(normal.read_text(), "keep [agent_name]\n")

    def test_temporary_directory_cannot_redirect_writes_into_metadata(self):
        for agent in ("claude", "codex"):
            with self.subTest(agent=agent), tempfile.TemporaryDirectory() as parent:
                root, product, skills = self.fixture(parent, agent)
                base, commits = self.commits(root)
                (product / "prompt").mkdir()
                (product / "prompt/.prompt.md").write_text("- [ ] branch-example-prompt.md\n")
                before = {str(p.relative_to(root)): p.read_bytes() for p in (root / ".git").rglob("*") if p.is_file()}
                environment = dict(self.environment, TMPDIR=str(root / ".git"))
                for script, args in (
                    ("tdd/mark-prompt-done.sh", ["example"]),
                    ("polish/capture-scope.sh", ["example", "--auto"]),
                    ("rebase/rebase.sh", ["--base", base, "--group", "feature: 統合", ",".join(commits)]),
                ):
                    result = subprocess.run(["bash", str(skills / script), *args], cwd=root, env=environment, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    after = {str(p.relative_to(root)): p.read_bytes() for p in (root / ".git").rglob("*") if p.is_file()}
                    self.assertEqual(before, after)

    def test_fixed_rebase_does_not_run_external_git_helpers(self):
        for agent in ("claude", "codex"):
            with self.subTest(agent=agent), tempfile.TemporaryDirectory() as parent:
                root, product, skills = self.fixture(parent, agent)
                base, commits = self.commits(root)
                marker = root / "helper-ran"
                helper = root / ".git/hooks/prepare-commit-msg"
                helper.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\n')
                helper.chmod(0o755)
                for key in ("core.fsmonitor", "diff.external", "gpg.program"):
                    self.git(root, "config", key, str(helper))
                self.git(root, "config", "commit.gpgSign", "true")
                for key in ("clean", "smudge", "process"):
                    self.git(root, "config", "filter.fixture." + key, str(helper))
                self.git(root, "config", "filter.fixture.required", "true")
                script = skills / "rebase/rebase.sh"
                result = subprocess.run(["bash", str(script), "--base", base, "--group", "feature: 統合", ",".join(commits)], cwd=root, env=self.environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(marker.exists())
                self.assertEqual(self.git(root, "rev-parse", "HEAD^{tree}"), self.git(root, "rev-parse", commits[-1] + "^{tree}"))
                self.git(root, "config", "filter.fixture.clean", str(helper))
                head = self.git(root, "rev-parse", "HEAD")
                result = subprocess.run(["bash", str(script), "--check", "--base", base], cwd=root, env=self.environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.git(root, "rev-parse", "HEAD"), head)
                self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
