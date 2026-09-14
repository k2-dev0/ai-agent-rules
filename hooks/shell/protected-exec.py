"""Keep repository metadata read-only even for approved outside execution."""
import json
import os
from pathlib import Path
import runpy
import shutil
import stat
import sys


def repository():
    control = Path(__file__).resolve().parents[2]
    if control.name not in (".codex", ".claude"):
        raise ValueError("run the distributed script from .codex or .claude")
    return control.parent


def protected_paths(root, policy):
    result = set(policy["metadata_paths"](root))
    if not result:
        raise ValueError("repository metadata could not be located")
    for relative in (
        ".codex/hooks", ".codex/agents", ".codex/config.toml", ".codex/hooks.json", ".codex/rules",
        ".claude/hooks", ".claude/agents", ".claude/skills", ".claude/settings.json", ".claude/settings.local.json",
        ".agents/skills", ".mcp.json",
    ):
        path = root / relative
        result.update((path, path.resolve()))
    # An existing hardlink outside the protected tree can name the same inode.
    # Refuse execution rather than claim a pathname policy protects that alias.
    def scan_error(error):
        raise error
    for path in result:
        nodes = [path] if path.is_file() else []
        if path.is_dir():
            for directory, directories, files in os.walk(path, onerror=scan_error):
                nodes.extend(Path(directory) / name for name in directories + files)
        for node in nodes:
            info = node.lstat()
            if stat.S_ISREG(info.st_mode) and info.st_nlink > 1:
                raise ValueError("protected file has a hardlink: " + str(node))
            if stat.S_ISLNK(info.st_mode):
                raise ValueError("protected tree contains a symlink: " + str(node))
    return sorted(result, key=str)


def sandbox_command(paths, command):
    if sys.platform == "darwin":
        launcher = "/usr/bin/sandbox-exec"
        if not Path(launcher).is_file():
            raise ValueError("sandbox-exec is unavailable")
        clauses = ["(version 1)", "(allow default)", "(deny appleevent-send)",
                   '(deny file-write* (regex "(^|/)[.][gG][iI][tT](/|$)"))']
        ancestors = set()
        for path in paths:
            quoted = json.dumps(str(path), ensure_ascii=False)
            clauses.append("(deny file-write* (subpath " + quoted + "))")
            ancestors.update(path.parents)
        for ancestor in sorted(ancestors, key=str):
            clauses.append("(deny file-write-unlink (literal " + json.dumps(str(ancestor), ensure_ascii=False) + "))")
        return [launcher, "-p", "\n".join(clauses), *command]
    if sys.platform.startswith("linux"):
        launcher = shutil.which("bwrap")
        if not launcher:
            raise ValueError("bubblewrap is required for protected outside execution")
        # Bind mounts keep existing metadata read-only even after parent renames.
        args = [launcher, "--die-with-parent", "--unshare-user", "--unshare-pid", "--bind", "/", "/"]
        # A missing controller must not become writable. Conservatively bind its
        # nearest existing ancestor read-only too (possibly the whole worktree).
        mounts = set()
        for path in paths:
            while not path.exists():
                path = path.parent
            mounts.add(path)
        for path in sorted(mounts, key=lambda p: len(p.parts)):
            args.extend(["--ro-bind", str(path), str(path)])
        return [*args, "--", *command]
    raise ValueError("protected outside execution is unavailable on this platform")


def main(args):
    root = repository()
    policy = runpy.run_path(str(Path(__file__).with_name("git-policy.py")))
    if len(args) == 2 and args[0] == "--shell":
        result = policy["inspect"]({"cwd": str(Path.cwd()), "tool_name": "Bash", "tool_input": {"command": args[1]}}, outside_payload=True)
        if result and result.get("commit_check"):
            raise ValueError("use the checked standalone Git command for add/commit")
        command = ["/bin/bash", "--noprofile", "--norc", "-c", (result or {}).get("command", args[1])]
    elif args[:1] == ["--"] and len(args) > 1:
        command = args[1:]
    else:
        raise ValueError("usage: protected-exec.py --shell <command> | -- <argv...>")
    # No retry without the OS policy, including when nested sandboxing is denied.
    command = sandbox_command(protected_paths(root, policy), command)
    # Replace the launcher so cancellation and stdio EOF reach the real process.
    os.execv(command[0], command)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, RuntimeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
