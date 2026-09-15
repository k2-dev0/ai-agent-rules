import copy
import json
import unittest
import subprocess
import tempfile
from pathlib import Path
from workflow_evidence import verify, prepared_arguments
from probe_agent_workflow import head_files


class WorkflowEvidence(unittest.TestCase):
    def setUp(self):
        result = {'score': 1, 'reason': 'A local branch.'}
        self.events = [
            {'input': {'hook_event_name': 'SubagentStart', 'session_id': 'parent', 'agent_id': 'child', 'agent_type': 'difficulty-evaluator'}},
            {'hook': 'agent-input.sh', 'input': {'hook_event_name': 'SubagentStop', 'session_id': 'parent', 'agent_id': 'child', 'agent_type': 'difficulty-evaluator', 'last_assistant_message': json.dumps(result)},
             'recorded_agent_state': {'phase': 'complete', 'child_id': 'child', 'role': 'difficulty-evaluator', 'result': result}},
            {'input': {'hook_event_name': 'PreToolUse', 'tool_name': 'apply_patch', 'session_id': 'parent', 'model': 'gpt-5.6-luna'}},
        ]
        def item(kind, **fields):
            return {'type': 'item.completed', 'item': {'type': kind, **fields}}
        self.runtime = [
            item('file_change', status='completed', changes=[{'path': '/fixture/test_value.py'}]),
            item('command_execution', command="/bin/zsh -lc 'python3 -m unittest -v'", exit_code=1, aggregated_output='test_negative (test_value.DoubleTest) ... FAIL\ntest_positive (test_value.DoubleTest) ... ok\ntest_zero (test_value.DoubleTest) ... ok\nFAIL: test_negative\nAssertionError: -6 != 0\nRan 3 tests in 0.001s\nFAILED (failures=1)'),
            item('file_change', status='completed', changes=[{'path': '/fixture/value.py'}]),
            item('command_execution', command='python3 -m unittest -v', exit_code=0, aggregated_output='test_negative (test_value.DoubleTest) ... ok\ntest_positive (test_value.DoubleTest) ... ok\ntest_zero (test_value.DoubleTest) ... ok\nRan 3 tests in 0.001s\nOK'),
        ]
        self.proofs = [{'result': {'status': 'reviewed', 'review_head': 'head', 'unchecked': [], 'findings': []}}]
        self.commits = [['test_value.py'], ['value.py']]
        self.hashes = {'value.py':'a'*64,'test_value.py':'b'*64}
        self.events.extend([{'input': {'hook_event_name':'PostToolUse','tool_name':'Bash','tool_input':{'command':'python3 -m unittest -v'}},'file_hashes':dict(self.hashes)} for _ in range(2)])

    def check(self, case='workflow', **kwargs):
        return verify(self.events, self.runtime, self.proofs, '/fixture', 'head', self.commits, case, True, file_hashes=self.hashes, **kwargs)

    def test_real_evidence_sequence_is_accepted(self):
        self.assertTrue(self.check()['success'])

    def test_reason_and_hook_receipt_must_be_valid(self):
        for reason in ('', '  ', 1, True, [], {'reason': 'x'}):
            with self.subTest(reason=reason):
                changed = copy.deepcopy(self.events)
                invalid = {'score': 1, 'reason': reason}
                changed[1]['input']['last_assistant_message'] = json.dumps(invalid)
                changed[1]['recorded_agent_state']['result'] = invalid
                self.assertFalse(verify(changed, [], [], '/fixture', 'head', [], 'difficulty', True)['success'])
        for mutation in ('missing_receipt', 'wrong_child', 'wrong_role', 'unbound'):
            changed = copy.deepcopy(self.events)
            state = changed[1]['recorded_agent_state']
            if mutation == 'missing_receipt':
                state.pop('result')
            elif mutation == 'wrong_child':
                state['child_id'] = 'other'
            elif mutation == 'wrong_role':
                state['role'] = 'default'
            else:
                state['phase'] = 'reserved'
            self.assertFalse(verify(changed, [], [], '/fixture', 'head', [], 'difficulty', True)['success'])

    def test_evaluation_after_edit_is_rejected(self):
        self.events.insert(0, self.events.pop(2))
        self.assertIn('evaluation_not_before_first_edit', self.check()['errors'])

    def test_implementation_before_red_is_rejected(self):
        self.runtime[1], self.runtime[2] = self.runtime[2], self.runtime[1]
        self.assertIn('red_green_order_invalid', self.check()['errors'])

    def test_test_edit_after_green_is_rejected(self):
        self.runtime.append(copy.deepcopy(self.runtime[0]))
        self.assertFalse(self.check()['success'])

    def test_shell_edit_after_green_invalidates_the_tested_bytes(self):
        self.hashes['value.py'] = 'c'*64
        self.assertIn('final_files_not_tested', self.check()['errors'])

    def test_missing_post_test_snapshot_is_not_success(self):
        self.events.pop()
        self.assertIn('final_files_not_tested', self.check()['errors'])

    def test_faked_command_text_is_not_execution_evidence(self):
        self.runtime[1]['item']['command'] = 'echo "python3 -m unittest -v"'
        self.assertFalse(self.check()['success'])

    def test_zero_skipped_and_partial_green_are_rejected(self):
        good = self.runtime[-1]['item']['aggregated_output']
        for output in ('Ran 0 tests\nOK', good.replace(' ... ok', " ... skipped 'not run'").replace('OK', 'OK (skipped=3)'),
                       good.replace('test_negative (test_value.DoubleTest) ... ok\n', '').replace('Ran 3', 'Ran 2'),
                       good.replace('test_negative', 'test_unrelated'), good.replace(' ... ok', ' ... expected failure')):
            self.runtime[-1]['item']['aggregated_output'] = output
            self.assertFalse(self.check()['success'], output)

    def test_unresolved_finding_is_not_completion(self):
        for severity in ('critical', 'high', 'medium', 'low'):
            self.proofs[0]['result']['findings'] = [{'severity': severity}]
            result = self.check()
            self.assertTrue(result['review_accepted'])
            self.assertFalse(result['success'])

    def test_wrong_head_unchecked_and_multi_file_commits_fail(self):
        self.proofs[0]['result']['review_head'] = 'old'
        self.assertFalse(self.check()['success'])
        self.proofs[0]['result']['review_head'] = 'head'
        self.proofs[0]['result']['unchecked'] = ['unread dependency']
        self.assertFalse(self.check()['success'])
        self.proofs[0]['result']['unchecked'] = []
        self.commits = [['test_value.py', 'value.py']]
        self.assertFalse(self.check()['success'])

    def test_unavailable_downgrade_is_explicit_not_a_switch(self):
        self.events[2]['input']['model'] = 'gpt-5.6-sol'
        self.assertFalse(self.check()['success'])
        result = self.check(allow_native_downgrade=True)
        self.assertTrue(result['success'])
        self.assertEqual(result['model_selection'], 'native_cli_downgrade_unavailable')

    def test_only_successful_prepare_output_can_supply_arguments(self):
        brief = {'repository': '/fixture', 'implementation_policy': 'Change double.'}
        args = {'agent_type': 'difficulty-evaluator', 'fork_turns': 'none', 'task_name': 'request_' + 'a' * 32, 'message': json.dumps(brief)}
        def request(header, body):
            return {'input': [{'type': 'function_call_output', 'call_id': 'prepare', 'output': header + '\nFinal output:\n' + body}]}
        self.assertEqual(prepared_arguments(request('Process exited with code 0', json.dumps(args)), 'difficulty-evaluator', brief), args)
        actual = request('Chunk ID: fixture\nWall time: 0.0000 seconds\nProcess exited with code 0\nOriginal token count: 84', json.dumps(args))
        actual['input'][0]['output'] = actual['input'][0]['output'].replace('Final output:', 'Output:')
        self.assertEqual(prepared_arguments(actual, 'difficulty-evaluator', brief), args)
        for value in (request('Process exited with code 2', json.dumps(args)), request('Script running', json.dumps(args)),
                      request('Process exited with code 0', 'not json'), {'input': []},
                      request('Process exited with code 0', json.dumps(dict(args, agent_type='default')))):
            with self.assertRaises(ValueError):
                prepared_arguments(value, 'difficulty-evaluator', brief)

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
