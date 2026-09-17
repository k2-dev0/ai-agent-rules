"""Opt-in, real-model test of the distributed native agent/hook boundary.

Only disposable projects are changed. This is not a production fallback for an
unavailable role. Hook decisions are observed, never replaced or disabled.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import tempfile
import stat
import hashlib
from workflow_evidence import verify

REPO = Path(__file__).resolve().parents[1]


def toml(value):
    if isinstance(value, dict):
        return "{" + ",".join(json.dumps(k) + "=" + toml(v) for k, v in value.items()) + "}"
    if isinstance(value, list):
        return "[" + ",".join(map(toml, value)) + "]"
    return json.dumps(value)


def prepare(output, name="project"):
    root = output / name
    root.mkdir()
    product = root / ".codex"
    shutil.copytree(REPO / "codex", product)
    shutil.copytree(REPO / "hooks", product / "hooks")
    shutil.copytree(REPO / "skills", root / ".agents/skills")
    for base in (product, root / ".agents"):
        for path in base.rglob("*"):
            if path.is_file() and path.suffix in (".md", ".sh", ".toml", ".json", ".yaml"):
                path.write_text(path.read_text().replace("[agent_name]", "codex").replace("[skills_root]", ".agents/skills"))
    # MCP services are not part of this agent-boundary test; disable them without
    # substituting any of the distributed role, permissions, or hook settings.
    config = product / "config.toml"
    config.write_text(config.read_text().split("[mcp_servers.", 1)[0])
    (root / "AGENTS.md").write_text((REPO / "AGENTS.md").read_text().replace("[skills_root]", ".agents/skills"))
    (root / ".gitignore").write_text(".codex/\n.agents/\n__pycache__/\n")
    (root / "value.py").write_text("def double(value):\n    return value * 2\n")
    (root / "test_value.py").write_text("import unittest\nfrom value import double\n\nclass DoubleTest(unittest.TestCase):\n    def test_positive(self):\n        self.assertEqual(double(3), 6)\n")
    for args in (("init", "-q"), ("config", "user.name", "Fixture"),
                 ("config", "user.email", "fixture@example.invalid"), ("add", "."),
                 ("-c", "core.hooksPath=/dev/null", "commit", "-qm", "baseline")):
        subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)
    observer = output / "observe.py"
    observer.write_text('''import json, os, subprocess, sys, hashlib
from pathlib import Path
raw = sys.stdin.read()
r = subprocess.run((["python3", sys.argv[1], "hook"] if sys.argv[1].endswith(".py") else ["bash", sys.argv[1]]), input=raw, text=True, capture_output=True)
record = {"hook":sys.argv[1].rsplit("/",1)[-1], "input":json.loads(raw), "stdout":r.stdout, "stderr":r.stderr, "returncode":r.returncode}
event = record["input"]
if event.get("hook_event_name") == "PostToolUse" and event.get("tool_name") == "Bash":
    root = Path(sys.argv[1]).parents[3]
    record["file_hashes"] = {name: hashlib.sha256((root/name).read_bytes()).hexdigest() if (root/name).is_file() else None for name in ("value.py", "test_value.py")}
if record["hook"] == "agent-input.sh" and event.get("hook_event_name") == "SubagentStop":
    path = Path(sys.argv[1]).parents[3] / ".codex/tmp" / ("agent-input." + event["session_id"] + ".json")
    try:
        record["recorded_agent_state"] = json.loads(path.read_text())
    except (OSError, ValueError):
        record["recorded_agent_state"] = {}
fd = os.open(sys.argv[2], os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600)
os.write(fd, (json.dumps(record, ensure_ascii=False)+"\\n").encode())
os.close(fd)
sys.stdout.write(r.stdout)
sys.stderr.write(r.stderr)
sys.exit(r.returncode)
''')
    path = product / "hooks.json"
    settings = json.loads(path.read_text())
    for groups in settings["hooks"].values():
        for group in groups:
            for hook in group["hooks"]:
                name = re.search(r"shell/([\w-]+\.(?:sh|py))", hook["command"]).group(1)
                hook["command"] = shlex.join(["python3", str(observer), str(product / "hooks/shell" / name), str(output / "events.jsonl")])
    # Observation only: this hook returns no decision for PostToolUse. Capture
    # the tested bytes so later shell writes cannot masquerade as tested code.
    settings['hooks'].setdefault('PostToolUse', []).append({'matcher':'^Bash$', 'hooks':[{
        'type':'command','command':shlex.join(['python3',str(observer),str(product/'hooks/shell/agent-input.sh'),str(output/'events.jsonl')]),'timeout':5}]})
    path.write_text(json.dumps(settings))
    return root


def head_files(repository):
    """Enumerate the committed tree, unaffected by staged additions/deletions."""
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=repository)
    width = 32 if git('rev-parse', '--show-object-format').strip() == b'sha256' else 20
    def walk(tree, prefix):
        raw = git('cat-file', 'tree', tree)
        cursor = 0
        while cursor < len(raw):
            end = raw.index(b'\0', cursor)
            mode, name = raw[cursor:end].split(b' ', 1)
            oid = raw[end + 1:end + 1 + width].hex()
            cursor = end + 1 + width
            relative = prefix / os.fsdecode(name)
            mode = int(mode, 8)
            if stat.S_ISDIR(mode):
                yield from walk(oid, relative)
            elif stat.S_ISREG(mode):
                yield relative, git('cat-file', 'blob', oid), mode & 0o777
            else:
                raise ValueError('source snapshot supports regular files only: ' + str(relative))
    yield from walk(git('rev-parse', 'HEAD^{tree}').decode().strip(), Path())


def source_review_fixture(root):
    """Review a clean snapshot of source changes, never the user's worktree."""
    for relative, contents, mode in head_files(REPO):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)
        path.chmod(mode)
    ignore = root / '.gitignore'
    ignore.write_text((ignore.read_text() if ignore.exists() else '')+'\n.codex/\n.agents/\n__pycache__/\n')
    subprocess.run(['git','add','.'],cwd=root,check=True,capture_output=True)
    subprocess.run(['git','-c','core.hooksPath=/dev/null','commit','-qm','source baseline'],cwd=root,check=True,capture_output=True)
    base = subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
    changed = subprocess.check_output(['git','diff','--name-only','--no-renames','HEAD','-z'],cwd=REPO).split(b'\0')
    changed += subprocess.check_output(['git','ls-files','--others','--exclude-standard','-z'],cwd=REPO).split(b'\0')
    for raw in dict.fromkeys(changed):
        if not raw:
            continue
        relative = os.fsdecode(raw)
        source, target = REPO / relative, root / relative
        if source.is_file():
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(source,target)
        elif target.exists():
            target.unlink()
        subprocess.run(['git','add','--',relative],cwd=root,check=True,capture_output=True)
        subprocess.run(['git','-c','core.hooksPath=/dev/null','commit','-qm','snapshot '+relative],cwd=root,check=True,capture_output=True)
    head = subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
    return base, head


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--timeout", type=int, default=240)
    parser.add_argument("--case", choices=("source-review",), default="source-review")
    args = parser.parse_args()
    output = Path(tempfile.mkdtemp(prefix="agent-workflow-live-")).resolve()
    root = prepare(output)
    print(str(output), flush=True)
    if args.case == 'source-review':
        base, head = source_review_fixture(root)
        brief = dict(repository=str(root),review_base=base,review_head=head,requirements=(
            "Migrate Codex to DeepSeek repository work and Astra design/review while preserving mechanical changes on the current parent model. "
            "Remove Codex difficulty routing and preserve fixed-commit review input validation, "
            "actual child identity binding, independent review results and .git protection. "
            "Keep model instructions sufficient for correct workflows. Tests must exercise real hooks and not mistake "
            "component or simulated success for a completed live workflow. Do not modify distribution targets or user settings."))
        prompt = ("Review only. Read .agents/skills/SUBAGENT_RULES.md and .agents/skills/INDEPENDENT_REVIEW.md, "
                  "then use a fresh native code-reviewer for the following fixed source change. Do not review it yourself, "
                  "edit, commit, or run tests. Wait for the reviewer and report its final result and whether the recorded result was accepted. "
                  + json.dumps(brief))
    command = [args.codex, "exec", "--ignore-user-config", "--json", "--dangerously-bypass-hook-trust",
               "-c", "projects=" + toml({str(root): {"trust_level": "trusted"}}),
               "-c", "sqlite_home=" + toml(str(output / "sqlite")),
               "-c", "log_dir=" + toml(str(output / "logs")),
               "-c", 'approval_policy="never"', "-c", 'web_search="disabled"',
               "-c", "features.apps=false", "-c", "features.plugins=false",
               "-m", "gpt-6-astra", "-c", 'model_reasoning_effort="xhigh"', "-C", str(root), prompt]
    with (output / "runtime.jsonl").open("w") as stdout, (output / "stderr.log").open("w") as stderr:
        process = subprocess.Popen(command, cwd=root, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            code = process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            code = 124
    path = output / "events.jsonl"
    events = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    starts = {e['input'].get('agent_id') for e in events if e['input'].get('hook_event_name') == 'SubagentStart'}
    stops = {e['input'].get('agent_id') for e in events if e['input'].get('hook_event_name') == 'SubagentStop'}
    proofs = [json.loads(p.read_text()) for p in (root / '.codex/tmp').glob('independent-review.*.json')]
    clean = subprocess.check_output(['git','status','--porcelain','--untracked-files=all'],cwd=root,text=True).strip() == ''
    head = subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
    evidence = verify(events, proofs, head, clean)
    summary = {"case":args.case,"exit_code":code, "events":len(events), "starts":len(starts), "stops":len(stops),
               **evidence}
    (output / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary), flush=True)
    return 0 if code == 0 and starts and stops and evidence['success'] else 2


if __name__ == "__main__":
    raise SystemExit(main())
