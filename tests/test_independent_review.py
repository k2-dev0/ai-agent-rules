"""Exercise distributed lifecycle hooks against real Git commits, without model calls."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class ReviewLifecycle(unittest.TestCase):
    def test_distributed_lifecycle(self):
        for agent in ('codex', 'claude'):
            with self.subTest(agent=agent), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                hookdir = root / f'.{agent}/hooks/shell'
                shutil.copytree(REPO / 'hooks/shell', hookdir)
                adapter = hookdir / 'hook-io.sh'
                adapter.write_text(adapter.read_text().replace('[agent_name]', agent))
                state = root / f'.{agent}/tmp/independent-review.TEST.json'
                def git(*args):
                    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
                git('init', '-q')
                git('config', 'user.name', 'Test')
                git('config', 'user.email', 'test@example.invalid')
                (root / '.gitignore').write_text('.codex/\n.claude/\n')
                source = root / 'sample.py'
                source.write_text('value = 0\n')
                git('add', '.')
                git('-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'baseline')
                base = git('rev-parse', 'HEAD')
                def call(event, **kwargs):
                    payload = dict(hook_event_name=event, session_id='TEST', cwd=str(root), **kwargs)
                    result = subprocess.run(['bash', str(hookdir / 'independent-review.sh')], input=json.dumps(payload), text=True, capture_output=True, check=True)
                    self.assertEqual(result.stderr, '')
                    return json.loads(result.stdout) if result.stdout else None
                def edit(path='sample.py'):
                    if agent == 'codex':
                        return call('PreToolUse', tool_name='apply_patch', tool_input={'command': f'*** Update File: {path}\n'})
                    return call('PreToolUse', tool_name='Edit', tool_input={'file_path': path})
                def commit(value):
                    source.write_text(f'value = {value}\n')
                    git('add', 'sample.py')
                    git('-c', 'core.hooksPath=/dev/null', 'commit', '-qm', f'value {value}')
                    return git('rev-parse', 'HEAD')
                rolekey = 'agent_type' if agent == 'codex' else 'subagent_type'
                def launch(review_base=base, head=None):
                    brief = dict(repository=str(root), review_base=review_base, review_head=head or git('rev-parse', 'HEAD'), requirements='Implement the requested value.')
                    response = call('PreToolUse', tool_name='Agent', tool_input={rolekey:'code-reviewer', 'prompt':json.dumps(brief)})
                    if response is None:
                        brief['request_id'] = json.loads(state.read_text())['pending']['request_id']
                    return brief, response
                def start():
                    call('SubagentStart', agent_id='child', agent_type='code-reviewer')
                def result(brief, **changes):
                    report = dict(status='reviewed', review_base=brief['review_base'], review_head=brief['review_head'], request_id=brief['request_id'], unchecked=[], findings=[])
                    report.update(changes)
                    return report
                def end(report, child='child'):
                    return call('SubagentStop', agent_id=child, agent_type='code-reviewer', last_assistant_message=json.dumps(report))
                def blocked():
                    self.assertEqual(call('Stop', last_assistant_message='Completed')['decision'], 'block')
                # Read-only/document-only work does not acquire a review requirement.
                self.assertIsNone(call('Stop'))
                edit('README.md')
                self.assertFalse(state.exists())
                edit()
                self.assertEqual(json.loads(state.read_text())['base'], base)
                self.assertIsNone(call('Stop'))  # rejected/no-op edit causes no change
                h1 = commit(1)
                blocked()
                edit()
                h2 = commit(2)
                self.assertEqual(json.loads(state.read_text())['base'], base)
                _, denied = launch(h1)
                self.assertEqual(denied['hookSpecificOutput']['permissionDecision'], 'deny')
                brief, response = launch()
                self.assertIsNone(response)
                start()
                end(result(brief), child='other')
                blocked()
                end(result(brief, unchecked=['ignored test']))
                blocked()
                end(result(brief, review_head=h1))
                blocked()
                end(result(brief, status='incomplete'))
                blocked()
                end(result(brief, findings=[{'severity': 'urgent'}]))
                blocked()
                end(result(brief))
                self.assertIsNone(call('Stop'))
                # A clean new user request starts a fresh scope after completion.
                call('UserPromptSubmit', prompt='Next change')
                self.assertFalse(state.exists())
                edit()
                self.assertEqual(json.loads(state.read_text())['base'], h2)
                h3 = commit(3)
                brief, response = launch(h2)
                self.assertIsNone(response)
                start()
                call('UserPromptSubmit', prompt='Changed requirement')
                end(result(brief))
                blocked()
                self.assertEqual(json.loads(state.read_text())['base'], h2)
                # Dirty tracked files and edited untracked files cannot pass completion.
                brief, _ = launch(h2)
                start()
                source.write_text('value = dirty\n')
                end(result(brief))
                blocked()
                source.write_text('value = 3\n')
                brief, _ = launch(h2)
                start()
                end(result(brief))
                edit('new.py')
                (root / 'new.py').write_text('new = True\n')
                brief, _ = launch(h2)
                start()
                end(result(brief))
                blocked()
                self.assertIsNone(call('Stop', last_assistant_message='独立レビュー未完了: untracked test'))
                self.assertFalse(json.loads(state.read_text()).get('finished', False))
                call('UserPromptSubmit', prompt='Continue')
                self.assertEqual(json.loads(state.read_text())['base'], h2)
                # Lifecycle registration is present in both deployed configurations.
                settings = json.loads((REPO / ('codex/hooks.json' if agent == 'codex' else 'claude/settings.json')).read_text())
                for event in ('PreToolUse','UserPromptSubmit','SubagentStart','SubagentStop','Stop'):
                    self.assertTrue(any('independent-review.sh' in hook['command'] for group in settings['hooks'][event] for hook in group['hooks']))


if __name__ == '__main__':
    unittest.main()
