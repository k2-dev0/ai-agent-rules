"""Opt-in real-model probes. Outputs stay under a new temporary directory.

python3 tests/probe_context_runtime.py codex investigation
Requires an authenticated CLI. Never run as part of the offline test suite.
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
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
CASES = ("investigation", "document_change", "normal_implementation", "from_doc", "review_repair")


def prepare(engine, case, output):
    root = output / "project"
    root.mkdir()
    product = root / f".{engine}"
    product.mkdir()
    skills = root / (".agents/skills" if engine == "codex" else ".claude/skills")
    shutil.copytree(REPO / "skills", skills)
    shutil.copytree(REPO / "hooks", product / "hooks")
    shutil.copytree(REPO / engine / "agents", product / "agents")
    shutil.copytree(REPO / "rules", product / "rules")
    for base in (skills, product / "hooks", product / "agents", product / "rules"):
        for path in base.rglob("*"):
            if path.is_file() and path.suffix in (".md", ".sh", ".toml", ".json", ".yaml", ".yml"):
                text = path.read_text()
                path.write_text(text.replace("[agent_name]", engine).replace("[skills_root]", str(skills)))
    (root / "AGENTS.md").write_text((REPO / "AGENTS.md").read_text().replace("[skills_root]", str(skills)))
    if engine == "claude":
        (root / "CLAUDE.md").write_text("@AGENTS.md\n")
    (root / ".gitignore").write_text(".codex/\n.claude/\n.agents/\n")
    (root / "src").mkdir()
    (root / "src/value.py").write_text("def double(value):\n    return value * 2\n")
    (root / "notes.md").write_text("This is a smple fixture.\n")
    promptdir = product / "prompt"
    promptdir.mkdir()
    (promptdir / ".prompt.md").write_text("- [ ] branch-double-prompt.md\n")
    (promptdir / "branch-double-prompt.md").write_text(
        "# double\nReturn zero for negative inputs to double(). Keep nonnegative inputs unchanged.\n"
    )
    for args in (("init", "-q"), ("config", "user.name", "Test"),
                 ("config", "user.email", "test@example.invalid"), ("add", "."),
                 ("-c", "core.hooksPath=/dev/null", "commit", "-qm", "baseline")):
        subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)
    head = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()

    # The wrapper records the actual runtime payload/output, without changing the decision.
    wrapper = output / "observe.py"
    wrapper.write_text("""import json, os, subprocess, sys
from pathlib import Path
raw = sys.stdin.read()
payload = json.loads(raw)
result = subprocess.run(["bash", sys.argv[1]], input=raw, text=True, capture_output=True)
record = {"hook": Path(sys.argv[1]).name, "input": payload,
          "stdout": result.stdout, "stderr": result.stderr, "returncode": result.returncode}
fd = os.open(sys.argv[2], os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600)
os.write(fd, (json.dumps(record, ensure_ascii=False) + "\\n").encode())
os.close(fd)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
""")
    settings = json.loads((REPO / ("codex/hooks.json" if engine == "codex" else "claude/settings.json")).read_text())
    # Keep all distributed hook matchers; no substitute hook is used.
    for groups in settings["hooks"].values():
        for group in groups:
            for hook in group["hooks"]:
                name = re.search(r"shell/([\w-]+\.sh)", hook["command"]).group(1)
                hook["command"] = " ".join(map(shlex.quote, (
                    sys.executable, str(wrapper), str(product / "hooks/shell" / name),
                    str(output / "hook-events.jsonl"),
                )))
                hook["timeout"] = 10
    if engine == "codex":
        (product / "hooks.json").write_text(json.dumps(settings))
        (product / "config.toml").write_text(
            '[features]\nhooks = true\n[agents]\nmax_threads = 1\n'
        )
    else:
        (product / "settings.json").write_text(json.dumps(settings))

    prompts = {
        "investigation": "Explain src/value.py. Read only; do not propose or perform a change.",
        "document_change": "Correct smple to simple in notes.md. This is documentation only. Do not use TDD.",
        "normal_implementation": "Change double in src/value.py to return zero for negative inputs. Present test scenarios before editing.",
        "from_doc": "$tdd --from-doc\nPresent test scenarios before editing.",
        "review_repair": "Run an independent code-reviewer on the current fixed commits using this JSON: " + json.dumps({
            "repository": str(root), "review_base": head, "review_head": head,
            "requirements": "Review the double function for the specified doubling behavior.",
        }),
    }
    prompt = (
        "Work only in this isolated fixture. Use the current main model without difficulty evaluation. "
        "Do not access any other repository or network service.\n" + prompts[case]
    )
    return root, prompt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", choices=("codex", "claude"))
    parser.add_argument("case", choices=CASES)
    parser.add_argument("--inline-hooks", action="store_true", help="Probe CLI config overrides if project hook discovery is unavailable.")
    args = parser.parse_args()
    output = Path(tempfile.mkdtemp(prefix=f"context-live-{args.engine}-{args.case}-")).resolve()
    root, prompt = prepare(args.engine, args.case, output)
    print(str(output), flush=True)
    if args.engine == "codex":
        command = [
            "codex", "exec", "--ignore-user-config", "--ephemeral", "--json",
            "--dangerously-bypass-hook-trust", "-s", "workspace-write",
            "-c", "approval_policy=never", "-c", "features.hooks=true",
            "-c", f'projects.{json.dumps(str(root))}.trust_level="trusted"',
            "-m", "gpt-5.6-sol", "-c", 'model_reasoning_effort="high"', "-C", str(root), prompt,
        ]
        if args.inline_hooks:
            def toml(value):
                if isinstance(value, dict):
                    return "{" + ",".join(json.dumps(k) + "=" + toml(v) for k, v in value.items()) + "}"
                if isinstance(value, list):
                    return "[" + ",".join(map(toml, value)) + "]"
                return json.dumps(value, ensure_ascii=False)
            hooks_path = root / ".codex/hooks.json"
            hooks = json.loads(hooks_path.read_text())["hooks"]
            hooks_path.unlink()
            for event, groups in hooks.items():
                command[2:2] = ["-c", f"hooks.{event}={toml(groups)}"]
    else:
        command = [
            "claude", "-p", "--output-format", "stream-json", "--verbose",
            "--include-hook-events", "--no-session-persistence", "--setting-sources", "project",
            "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
            "--permission-mode", "dontAsk", "--allowedTools", "Read,Edit,Write,Glob,Grep,Bash,Agent,Skill",
            "--model", "opus", prompt,
        ]
    with (output / "runtime.jsonl").open("w") as stdout, (output / "runtime.stderr").open("w") as stderr:
        process = subprocess.Popen(command, cwd=root, stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            code = process.wait(timeout=180)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=15)
            code = 124
    events = output / "hook-events.jsonl"
    rows = [json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
    deliveries = []
    for row in rows:
        try:
            decision = json.loads(row["stdout"])
        except (ValueError, TypeError):
            continue
        hook = decision.get("hookSpecificOutput", {})
        text = hook.get("additionalContext") or hook.get("permissionDecisionReason")
        if text:
            deliveries.append({
                "hook": row["hook"], "event": row["input"].get("hook_event_name"),
                "recipient": "child" if row["input"].get("hook_event_name") == "SubagentStart" else "parent",
                "bytes": len(text.encode()), "text": text,
            })
    assertions = {
        "hooks_observed": bool(rows),
        "child_contract_observed": any(d["recipient"] == "child" for d in deliveries) if args.case == "review_repair" else None,
    }
    if code == 0 and (not rows or assertions["child_contract_observed"] is False):
        code = 2
    runtime_items = []
    for line in (output / "runtime.jsonl").read_text().splitlines():
        try:
            runtime_items.append(json.loads(line))
        except ValueError:
            pass
    usages = [item.get("usage") for item in runtime_items if item.get("type") == "turn.completed"]
    report = {"engine": args.engine, "case": args.case, "exit_code": code,
              "mode": "inline" if args.inline_hooks else "project",
              "hook_events": len(rows), "deliveries": deliveries,
              "assertions": assertions, "reported_usage": usages,
              "operation_context_bytes": sum(d["bytes"] for d in deliveries if d["hook"] == "load-operation-context.sh"),
              "other_hook_feedback_bytes": sum(d["bytes"] for d in deliveries if d["hook"] != "load-operation-context.sh"),
              "note": "Observed runtime hook outputs; confirm model receipt in runtime.jsonl. Not total model input tokens."}
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps({**report, "deliveries": [{k: v for k, v in d.items() if k != "text"} for d in deliveries]}, ensure_ascii=False))
    return code


if __name__ == "__main__":
    sys.exit(main())
