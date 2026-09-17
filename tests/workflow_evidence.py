"""Validate fixture outcomes from runtime events and hook-owned evidence."""
import json
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


def verify(events, proofs, head, clean):
    """Accept an observed native review; never infer a DeepSeek workflow from it."""
    errors = []
    starts = {(e['input'].get('session_id'), e['input'].get('agent_id')) for e in events
              if e.get('input', {}).get('hook_event_name') == 'SubagentStart'
              and e['input'].get('agent_type') == 'code-reviewer'}
    ended = []
    for row in events:
        event = row.get('input', {})
        if (row.get('hook') != 'independent-review.sh' or event.get('hook_event_name') != 'SubagentStop'
                or event.get('agent_type') != 'code-reviewer'
                or (event.get('session_id'), event.get('agent_id')) not in starts):
            continue
        try:
            ended.append(json.loads(event.get('last_assistant_message', '')))
        except (ValueError, TypeError):
            pass
    matching = [p['result'] for p in proofs if isinstance(p.get('result'), dict)
                and p['result'].get('status') == 'reviewed' and p['result'].get('review_head') == head
                and p['result'].get('unchecked') == [] and isinstance(p['result'].get('findings'), list)
                and p['result'] in ended]
    review = matching[-1] if matching else None
    if not clean:
        errors.append('worktree_not_clean')
    if review is None:
        errors.append('no_accepted_review_for_head')
    elif review['findings']:
        errors.append('unresolved_review_findings')
    return {'review_accepted': review is not None, 'success': not errors, 'errors': errors}
