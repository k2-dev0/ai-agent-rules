"""Exercise both deployed hook chains, including the real approval handoff."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class CommandPermissions(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="command-permissions-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.configs = {}
        for agent in ("claude", "codex"):
            hooks = self.root / f".{agent}/hooks"
            shutil.copytree(REPO / "hooks", hooks)
            adapter = hooks / "shell/hook-io.sh"
            adapter.write_text(adapter.read_text().replace("[agent_name]", agent))
            config = REPO / ("claude/settings.json" if agent == "claude" else "codex/hooks.json")
            self.configs[agent] = json.loads(config.read_text())

    def chain(self, agent, command, event="PreToolUse", tool_name="Bash", tool_input=None):
        outputs = []
        payload = dict(hook_event_name=event, session_id="COMMAND1", cwd=str(self.root), tool_name=tool_name, tool_input=tool_input if tool_input is not None else dict(command=command))
        for group in self.configs[agent]["hooks"].get(event, []):
            if not re.search(group.get("matcher", ".*"), tool_name):
                continue
            for hook in group["hooks"]:
                name = re.search(r"/hooks/shell/([^\"/]+)", hook["command"])[1]
                result = subprocess.run(["bash", str(self.root / f".{agent}/hooks/shell" / name)], input=json.dumps(payload), cwd=self.root, env=dict(os.environ, CLAUDE_PROJECT_DIR=str(self.root)), text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                if result.stdout:
                    outputs.append(json.loads(result.stdout)["hookSpecificOutput"])
        return outputs

    def test_only_baton_switch_model_permission_is_approved(self):
        request = {'model':'gpt-5.6-sol', 'config':{'effort':'high'}}
        decisions = self.chain('codex', '', 'PermissionRequest', 'mcp__baton__switch_model', request)
        self.assertEqual(decisions, [{'hookEventName':'PermissionRequest', 'decision':{'behavior':'allow'}}])
        for name in ('mcp__baton__restart', 'mcp__other__switch_model', 'mcp__baton__switch_model_extra', 'switch_model'):
            self.assertEqual(self.chain('codex', '', 'PermissionRequest', name, request), [])
        self.assertEqual(self.chain('claude', '', 'PermissionRequest', 'mcp__baton__switch_model', request), [])
        self.assertEqual(self.chain('codex', '', 'PreToolUse', 'mcp__baton__switch_model', request), [])

    def test_index_restore_does_not_count_as_a_config_file_write(self):
        for agent in ('claude', 'codex'):
            outputs = self.chain(agent, 'git restore --staged -- .' + agent + '/config.toml')
            self.assertFalse(any(o.get('permissionDecision') == 'deny' for o in outputs), outputs)
            self.assertTrue(any(o.get('updatedInput') for o in outputs), outputs)
            outputs = self.chain(agent, 'git restore --staged --worktree .' + agent + '/config.toml')
            self.assertTrue(any(o.get('permissionDecision') == 'deny' for o in outputs), outputs)

    def test_single_commands_are_not_a_command_allowlist(self):
        commands = [
            "cp source.txt destination.txt", "rm destination.txt", "mv source.txt destination.txt",
            "rsync source.txt destination.txt", "sed -i s/a/b/ source.txt", "truncate -s 0 destination.txt",
            "printf changed > destination.txt", "printf changed >| destination.txt", "echo x &> destination.txt",
            "dd if=source.txt of=destination.txt", "sort -o destination.txt source.txt", "find work -delete",
            "find work -exec touch destination.txt +", "rg --pre preprocess.sh x source.txt",
            "python3 -c 'import pathlib; pathlib.Path(\"destination.txt\").write_text(\"changed\")'",
            "node -e 'require(\"fs\").writeFileSync(\"destination.txt\", \"changed\")'",
            "npm install example", "npx prisma migrate deploy", "yarn test", "yarn lint", "yarn build",
            'cp "$SOURCE" "$DESTINATION"', 'rm work/*.tmp', "bash -c 'cp source.txt destination.txt'",
            "aws lambda update-function-code --profile daresuma-readonly --function-name example",
            "unlisted-project-tool --output destination.txt",
        ]
        for agent in self.configs:
            for command in commands:
                with self.subTest(agent=agent, command=command):
                    self.assertEqual(self.chain(agent, command), [])

    def test_accepted_single_commands_act_on_ordinary_files(self):
        for agent in self.configs:
            commands = ["printf source > source.txt", "cp source.txt destination.txt", "mv destination.txt renamed.txt", "rm renamed.txt", "python3 -c 'from pathlib import Path; Path(\"result.txt\").write_text(\"done\")'"]
            for command in commands:
                self.assertEqual(self.chain(agent, command), [])
                subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", command], cwd=self.root, check=True)
            self.assertEqual((self.root / "result.txt").read_text(), "done")
            self.assertFalse((self.root / "renamed.txt").exists())

    def test_compounds_are_denied_but_literal_punctuation_is_not(self):
        rejected = ["pwd; ls", "pwd && ls", "pwd || ls", "pwd | cat", "pwd &", "(pwd)", "for f in a b; do echo $f; done", "if true; then pwd; fi", "pwd\nls", "echo $(pwd)", 'echo "$(pwd)"', "echo `pwd`", "bash -c 'pwd; ls'", "bash --rcfile /dev/null -c 'pwd; ls'", "bash -O extglob -c 'pwd; ls'", "env bash -c 'pwd | cat'", "eval 'pwd; ls'"]
        for agent in self.configs:
            for command in rejected:
                with self.subTest(agent=agent, command=command):
                    self.assertTrue(any(o.get("permissionDecision") == "deny" for o in self.chain(agent, command)))
            for command in ("printf '%s' 'a; b | c & d'", 'printf "%s" "$VALUE"', "rg 'a|b' source.txt"):
                self.assertEqual(self.chain(agent, command), [])

    def test_boundary_requests_require_protected_entry_and_real_approval(self):
        for agent in self.configs:
            for command in ("curl https://example.invalid", "rm /tmp/command-fixture", "rg --files /tmp", "aws sts get-caller-identity --profile daresuma-readonly"):
                decision, = self.chain(agent, command, "PermissionRequest")
                self.assertEqual(decision["decision"]["behavior"], "deny")
                retry = decision["decision"]["message"].split(": ", 1)[1]
                self.assertEqual(shlex.split(retry), ["bash", f".{agent}/hooks/shell/outside.sh", command])
                self.assertEqual(self.chain(agent, retry), [])
                # Abstention, not a fabricated approval or updated command.
                self.assertEqual(self.chain(agent, retry, "PermissionRequest"), [])
            for inner in ("rm .git/HEAD", "git reset --hard", "pwd; ls"):
                command = shlex.join(["bash", f".{agent}/hooks/shell/outside.sh", inner])
                outputs = self.chain(agent, command, "PermissionRequest")
                self.assertTrue(any(o.get("decision", {}).get("behavior") == "deny" for o in outputs))


if __name__ == "__main__":
    unittest.main()
