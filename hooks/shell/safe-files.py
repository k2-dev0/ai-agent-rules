"""Fixed script writes: reject metadata aliases and replace through pinned dirs."""
import os
from pathlib import Path
import runpy
import secrets
import stat
import sys


def load_path_guard():
    source = Path(__file__).parent / "git-policy.py"
    if source.is_symlink() or source.stat().st_nlink != 1:
        raise ValueError("path guard is linked")
    return runpy.run_path(str(source))


def regular_target(info):
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError("destination is not an unlinked regular file")


def replace_file(root, relative, data, check_path, protected, create_parent=False):
    """Pin each parent with O_NOFOLLOW; the final replace never follows a link."""
    path = Path(relative)
    if path.is_absolute() or ".." in path.parts or not path.name:
        raise ValueError("destination must be a repository-relative file")
    check_path(str(path), root, protected)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    parent = os.open(str(root), flags)
    temporary = None
    try:
        for component in path.parts[:-1]:
            if create_parent:
                try:
                    os.mkdir(component, dir_fd=parent)
                except FileExistsError:
                    pass
            child = os.open(component, flags, dir_fd=parent)
            os.close(parent)
            parent = child
        mode = 0o600
        try:
            info = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            regular_target(info)
            mode = stat.S_IMODE(info.st_mode) & 0o777
        except FileNotFoundError:
            pass
        temporary = ".safe-write-" + secrets.token_hex(12)
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=parent)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            os.fchmod(output.fileno(), mode)
            output.flush()
            os.fsync(output.fileno())
        # A target replaced during preparation must not introduce a hardlink.
        try:
            regular_target(os.stat(path.name, dir_fd=parent, follow_symlinks=False))
        except FileNotFoundError:
            pass
        os.replace(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent)
        temporary = None
    finally:
        if temporary is not None:
            os.unlink(temporary, dir_fd=parent)
        os.close(parent)


def main(args):
    if len(args) < 2 or args[0] not in ("claude", "codex"):
        raise ValueError("usage: safe-files.py <claude|codex> <operation> [file]")
    agent, operation, *values = args
    root = Path.cwd()
    product = Path("." + agent)
    skill_root = Path(".agents/skills") if agent == "codex" else product / "skills"
    guard = load_path_guard()
    check_path = guard["check_path"]
    protected = guard["metadata_paths"](root)
    if operation == "check" and values:
        for value in values:
            check_path(value, root, protected)
        return
    if operation in ("plan", "prompt-index") and len(values) == 1:
        destination = product / ("e2e/.e2e.md" if operation == "plan" else "prompt/.prompt.md")
        data = Path(values[0]).read_bytes()
        replace_file(root, destination, data, check_path, protected, create_parent=operation == "plan")
        return
    if operation not in ("bootstrap-check", "bootstrap-file") or (root / "SOURCE_REPOSITORY.md").exists():
        raise ValueError("invalid operation or bootstrap source repository")
    targets = [product]
    if Path("AGENTS.md").exists() or Path("AGENTS.md").is_symlink():
        targets.append(Path("AGENTS.md"))
    if agent == "codex" and (Path(".agents").exists() or Path(".agents").is_symlink()):
        targets.append(Path(".agents"))
    if operation == "bootstrap-check" and not values:
        def fail_scan(error):
            raise error
        for path in targets:
            check_path(str(path), root, protected)
            nodes = [path]
            if path.is_dir():
                for directory, directories, files in os.walk(path, onerror=fail_scan):
                    nodes.extend(Path(directory) / name for name in directories + files)
            for node in nodes:
                info = node.lstat()
                if stat.S_ISLNK(info.st_mode):
                    raise ValueError("bootstrap path is a symlink: " + str(node))
                if not stat.S_ISDIR(info.st_mode):
                    regular_target(info)
        if not (skill_root / "bootstrap").is_dir():
            raise ValueError("bootstrap directory not found")
        return
    if operation == "bootstrap-file" and len(values) == 1:
        path = Path(values[0])
        if path.is_absolute() or ".." in path.parts or "bootstrap" in path.parts or not any(path == target or target in path.parents for target in targets):
            raise ValueError("invalid bootstrap file")
        # Split marker literals so bootstrap does not rewrite its own parser.
        data = path.read_bytes().replace(b"[" + b"skills_root]", str(skill_root).encode()).replace(b"[" + b"agent_name]", agent.encode())
        replace_file(root, path, data, check_path, protected)
        return
    raise ValueError("invalid operation arguments")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, RuntimeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
