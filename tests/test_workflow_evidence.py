import json
import unittest
import subprocess
import tempfile
from pathlib import Path
from workflow_evidence import verify, prepared_arguments
from probe_agent_workflow import head_files


class WorkflowEvidence(unittest.TestCase):
    def setUp(self):
        self.report = {'status': 'reviewed', 'review_head': 'head', 'request_id': 'request', 'unchecked': [], 'findings': []}
        self.proofs = [{'result': self.report}]
        self.events = [
            {'input': {'hook_event_name': 'SubagentStart', 'session_id': 'parent', 'agent_id': 'child', 'agent_type': 'code-reviewer'}},
            {'hook': 'independent-review.sh', 'input': {'hook_event_name': 'SubagentStop', 'session_id': 'parent',
                'agent_id': 'child', 'agent_type': 'code-reviewer', 'last_assistant_message': json.dumps(self.report)}},
        ]

    def test_observed_and_recorded_review_is_accepted(self):
        self.assertTrue(verify(self.events, self.proofs, 'head', True)['success'])

    def test_receipt_alone_wrong_identity_or_changed_head_is_not_completion(self):
        self.assertFalse(verify([], self.proofs, 'head', True)['success'])
        self.assertFalse(verify(self.events, self.proofs, 'old', True)['success'])
        self.assertFalse(verify(self.events, self.proofs, 'head', False)['success'])
        self.events[-1]['input']['agent_id'] = 'other'
        self.assertFalse(verify(self.events, self.proofs, 'head', True)['success'])

    def test_unchecked_or_unresolved_findings_fail(self):
        for change in ({'unchecked': ['dependency']}, {'findings': [{'severity': 'high'}]}):
            report = dict(self.report, **change)
            self.events[-1]['input']['last_assistant_message'] = json.dumps(report)
            self.assertFalse(verify(self.events, [{'result': report}], 'head', True)['success'])

    def test_only_successful_prepare_output_can_supply_arguments(self):
        brief = {'repository': '/fixture', 'review_base': 'a'*40, 'review_head': 'b'*40, 'requirements': 'Review double.'}
        args = {'agent_type': 'code-reviewer', 'fork_turns': 'none', 'task_name': 'request_' + 'a' * 32, 'message': json.dumps(brief)}
        def request(header, body):
            return {'input': [{'type': 'function_call_output', 'call_id': 'prepare', 'output': header + '\nFinal output:\n' + body}]}
        self.assertEqual(prepared_arguments(request('Process exited with code 0', json.dumps(args)), 'code-reviewer', brief), args)
        actual = request('Chunk ID: fixture\nWall time: 0.0000 seconds\nProcess exited with code 0\nOriginal token count: 84', json.dumps(args))
        actual['input'][0]['output'] = actual['input'][0]['output'].replace('Final output:', 'Output:')
        self.assertEqual(prepared_arguments(actual, 'code-reviewer', brief), args)
        for value in (request('Process exited with code 2', json.dumps(args)), request('Script running', json.dumps(args)),
                      request('Process exited with code 0', 'not json'), {'input': []},
                      request('Process exited with code 0', json.dumps(dict(args, agent_type='default')))):
            with self.assertRaises(ValueError):
                prepared_arguments(value, 'code-reviewer', brief)

    def test_source_baseline_comes_from_head_not_index(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                subprocess.run(['git', *args], cwd=root, check=True, capture_output=True)
            git('init', '-q')
            git('config', 'user.name', 'Fixture')
            git('config', 'user.email', 'fixture@example.invalid')
            (root / 'original.sh').write_text('original\n')
            (root / 'original.sh').chmod(0o755)
            git('add', 'original.sh')
            git('-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'baseline')
            (root / 'new.py').write_text('new\n')
            (root / 'original.sh').unlink()
            git('add', '--all')
            files = list(head_files(root))
            self.assertEqual(files, [(Path('original.sh'), b'original\n', 0o755)])


if __name__ == '__main__':
    unittest.main()
