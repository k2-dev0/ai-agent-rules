"""Validate fixture outcomes from runtime events and hook-owned evidence."""
import json
from pathlib import Path
import shlex
import re


def prepared_arguments(request, role, brief):
    """Consume the real exec result, never reconstruct a successful emit."""
    outputs = [item.get('output') for item in request.get('input', [])
               if item.get('type') == 'function_call_output' and item.get('call_id') == 'prepare']
    if not outputs:
        raise ValueError('prepare result missing')
    output = outputs[-1]
    if isinstance(output, dict):
        if output.get('exit_code') != 0:
            raise ValueError('prepare command failed')
        body = output.get('output', '')
    elif isinstance(output, str):
        parts = re.split(r'^(?:Final output|Output):\n', output, maxsplit=1, flags=re.MULTILINE)
        if len(parts) != 2 or not re.search(r'^Process exited with code 0$', parts[0], re.MULTILINE):
            raise ValueError('prepare command did not complete successfully')
        body = parts[1]
    else:
        raise ValueError('unknown prepare result shape')
    args = json.loads(body)
    if (not isinstance(args, dict) or set(args) != {'agent_type', 'task_name', 'fork_turns', 'message'} or
        args['agent_type'] != role or args['fork_turns'] != 'none' or
        not isinstance(args['task_name'], str) or not re.fullmatch(r'request_[0-9a-f]{32}', args['task_name']) or
        not isinstance(args['message'], str) or json.loads(args['message']) != brief):
        raise ValueError('prepare output does not match the request')
    return args


def accepted_evaluations(events):
    starts = set()
    accepted = []
    for index, row in enumerate(events):
        event = row.get('input', {})
        identity = (event.get('session_id'), event.get('agent_id'), event.get('agent_type'))
        if event.get('hook_event_name') == 'SubagentStart':
            starts.add(identity)
        if row.get('hook') != 'agent-input.sh' or event.get('hook_event_name') != 'SubagentStop' or identity not in starts or identity[2] != 'difficulty-evaluator':
            continue
        try:
            result = json.loads(event.get('last_assistant_message', ''))
        except (ValueError, TypeError):
            continue
        state = row.get('recorded_agent_state', {})
        if (isinstance(result, dict) and set(result) == {'score', 'reason'} and
            type(result['score']) is int and 1 <= result['score'] <= 10 and
            isinstance(result['reason'], str) and result['reason'].strip() and
            state.get('phase') == 'complete' and state.get('child_id') == identity[1] and
            state.get('role') == identity[2] and state.get('result') == result):
            accepted.append((index, event['session_id'], result))
    return accepted


def fixture_test_command(command):
    try:
        argv = shlex.split(command)
        if len(argv) == 3 and Path(argv[0]).name in ('bash', 'zsh', 'sh') and argv[1] in ('-c', '-lc'):
            argv = shlex.split(argv[2])
        return len(argv) == 4 and Path(argv[0]).name == 'python3' and argv[1:] == ['-m', 'unittest', '-v']
    except ValueError:
        return False


def fixture_test_results(output, green):
    """The fixture explicitly names its three independently executable cases."""
    rows = re.findall(r'^(test_\w+) \([^\n]+\) \.\.\. (ok|FAIL|ERROR|skipped[^\n]*|expected failure|unexpected success)$', output, re.MULTILINE)
    counts = re.findall(r'^Ran (\d+) tests?(?: in [0-9.]+s)?$', output, re.MULTILINE)
    required = {'test_negative', 'test_zero', 'test_positive'}
    if not counts or int(counts[-1]) != len(rows) or len(rows) < 3 or not required.issubset(dict(rows)):
        return False
    if green:
        return all(status == 'ok' for _, status in rows) and bool(re.search(r'^OK$', output, re.MULTILINE))
    result = dict(rows)
    return (result['test_negative'] == 'FAIL' and result['test_zero'] == result['test_positive'] == 'ok' and
            'AssertionError' in output and 'FAIL:' in output and 'ERROR:' not in output)


def review_evidence(proofs, head):
    matching = [p['result'] for p in proofs if isinstance(p.get('result'), dict) and
                p['result'].get('status') == 'reviewed' and p['result'].get('review_head') == head and
                p['result'].get('unchecked') == [] and isinstance(p['result'].get('findings'), list)]
    return matching[-1] if matching else None


def verify(events, runtime, proofs, root, head, commit_paths, case, clean, allow_native_downgrade=False, file_hashes=None):
    evaluations = accepted_evaluations(events)
    errors = []
    review = review_evidence(proofs, head)
    selection = None
    red_green = False
    if not clean:
        errors.append('worktree_not_clean')
    if case != 'source-review' and not evaluations:
        errors.append('no_accepted_evaluation')
    if case != 'difficulty':
        if review is None:
            errors.append('no_accepted_review_for_head')
        elif review['findings']:
            # The fixture grants no finding waivers. A reviewed result with
            # findings proves review occurred, not that the work is complete.
            errors.append('unresolved_review_findings')
    if case == 'workflow':
        edits = [(i, e['input']) for i, e in enumerate(events) if e.get('input', {}).get('tool_name') == 'apply_patch' and not e['input'].get('agent_id')]
        if not edits:
            errors.append('no_observed_edits')
        if evaluations and edits:
            evaluation_index, session, result = evaluations[-1]
            if evaluation_index >= edits[0][0] or any(e.get('session_id') != session for _, e in edits):
                errors.append('evaluation_not_before_first_edit')
            expected = 'gpt-5.6-luna' if result['score'] <= 3 else 'gpt-5.6-sol' if result['score'] <= 7 else 'gpt-6-astra'
            if all(e.get('model') == expected for _, e in edits):
                selection = 'selected_model_observed'
            elif allow_native_downgrade and result['score'] <= 3 and all(e.get('model') == 'gpt-5.6-sol' for _, e in edits):
                selection = 'native_cli_downgrade_unavailable'
            else:
                selection = 'not_applied'
                errors.append('selected_model_not_applied')
        changes, tests = [], []
        allowed = {str(Path(root) / name): name for name in ('value.py', 'test_value.py')}
        for index, row in enumerate(runtime):
            item = row.get('item', {})
            if row.get('type') != 'item.completed':
                continue
            if item.get('type') == 'file_change' and item.get('status') == 'completed':
                for change in item.get('changes', []):
                    if change.get('path') not in allowed:
                        errors.append('out_of_scope_edit')
                    else:
                        changes.append((index, allowed[change['path']]))
            if item.get('type') == 'command_execution' and fixture_test_command(item.get('command', '')):
                tests.append((index, item))
        source_edits = [i for i, name in changes if name == 'value.py']
        test_edits = [i for i, name in changes if name == 'test_value.py']
        red = [i for i, t in tests if t.get('exit_code') == 1 and fixture_test_results(t.get('aggregated_output', ''), green=False)]
        green = [i for i, t in tests if t.get('exit_code') == 0 and fixture_test_results(t.get('aggregated_output', ''), green=True)]
        red_green = bool(source_edits and test_edits and red and green and
                         min(test_edits) < min(red) < min(source_edits) and
                         max(green) > max(i for i, _ in changes) and green[-1] == tests[-1][0])
        if not red_green:
            errors.append('red_green_order_invalid')
        observed_tests = [e for e in events if e.get('input',{}).get('hook_event_name') == 'PostToolUse' and
                          e['input'].get('tool_name') == 'Bash' and not e['input'].get('agent_id') and
                          fixture_test_command(e['input'].get('tool_input',{}).get('command',''))]
        if (not file_hashes or not all(file_hashes.values()) or len(observed_tests) != len(tests) or not observed_tests or
            observed_tests[-1].get('file_hashes') != file_hashes):
            errors.append('final_files_not_tested')
        if (not commit_paths or any(len(paths) != 1 or paths[0] not in ('value.py', 'test_value.py') for paths in commit_paths) or
            commit_paths[0] != ['test_value.py'] or commit_paths[-1] != ['value.py']):
            errors.append('test_first_single_file_commits_missing')
    return {'valid_evaluation': bool(evaluations), 'model_selection': selection,
            'review_accepted': review is not None if case != 'difficulty' else None,
            'review_findings': len(review['findings']) if review else None,
            'red_green': red_green if case == 'workflow' else None, 'clean': clean,
            'errors': errors, 'success': not errors}
