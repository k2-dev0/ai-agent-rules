"""Validate literal tool paths and Git argv. This is not a process sandbox."""
import glob
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys


class Denied(ValueError):
    pass


def metadata_paths(cwd):
    """Read worktree pointers without executing config-dependent Git helpers."""
    paths = set()
    for parent in (cwd, *cwd.parents):
        marker = parent / ".git"
        if marker.exists() or marker.is_symlink():
            paths.add(marker)
            target = marker.resolve()
            paths.add(target)
            if target.is_file():
                value = target.read_text().strip()
                if not value.startswith("gitdir: "):
                    raise Denied(".gitの参照先を確認できません。")
                target = (parent / value[8:]).resolve()
                paths.add(target)
            common = target / "commondir"
            if common.is_file():
                paths.add((target / common.read_text().strip()).resolve())
            break
    return paths


def check_path(value, cwd, protected):
    if not isinstance(value, str) or not value or "\x00" in value:
        raise Denied("編集対象pathを確認できません。")
    path = Path(os.path.abspath(cwd / value))
    resolved = path.resolve()
    if any(p.casefold() == ".git" for p in (*path.parts, *resolved.parts)):
        raise Denied(".gitへの直接・間接の変更は禁止です。承認による解除はできません。")
    if any(p == t or t in p.parents or p in t.parents for p in (path, resolved) for t in protected):
        raise Denied(".gitの参照先または親directoryの変更は禁止です。")
    if resolved.is_dir():
        for _, directories, files in os.walk(resolved):
            if any(name.casefold() == ".git" for name in directories + files):
                raise Denied(".gitを含むdirectoryの変更は禁止です。")


# Unknown options fail closed, including abbreviations. The runtime sandbox is
# still required for repository configuration, environment and script effects.
DIFF = "--no-ext-diff --no-textconv --exit-code --quiet --stat --numstat --shortstat --name-only --name-status --raw --patch --no-patch --binary --summary --check --no-color --color --cached --staged --find-renames --find-copies --no-renames --ignore-all-space --ignore-space-change --ignore-space-at-eol --ignore-cr-at-eol --ignore-blank-lines --word-diff --word-diff-regex --diff-filter --relative --src-prefix --dst-prefix --no-prefix --unified --patience --histogram --minimal --full-index -p -s -u -w -b -M -C -U -z"
LOG = "--oneline --format --pretty --max-count --skip --since --until --after --before --author --committer --grep --all --branches --tags --remotes --not --reverse --no-merges --merges --first-parent --topo-order --date-order --ancestry-path --left-right --cherry-pick --cherry-mark --boundary --decorate --no-decorate --graph --date --encoding --abbrev --no-abbrev --follow --simplify-by-decoration -n -S -G -i"
FLAGS = {
    "log": DIFF + " " + LOG,
    "show": DIFF + " " + LOG,
    "diff": DIFF + " -S -G",
    "status": "--short --branch --porcelain --untracked-files --ignored --ignore-submodules --show-stash --no-ahead-behind -s -b -z -u",
    "ls-files": "--cached --deleted --modified --others --ignored --stage --unmerged --killed --directory --no-empty-directory --exclude-standard --error-unmatch --full-name --eol --deduplicate -c -d -m -o -i -s -u -t -v -z",
    "grep": "--cached --no-index --untracked --no-exclude-standard --text --ignore-case --word-regexp --line-regexp --invert-match --full-name --extended-regexp --basic-regexp --fixed-strings --perl-regexp --line-number --column --files-with-matches --files-without-match --count --all-match --and --or --not --quiet --max-depth --after-context --before-context --context -a -i -w -v -E -G -F -P -n -l -L -c -z -q -h -H -A -B -C -e -f",
    "rev-parse": "--verify --quiet --short --abbrev-ref --symbolic --symbolic-full-name --show-toplevel --show-prefix --show-cdup --git-dir --absolute-git-dir --git-common-dir --is-inside-work-tree --is-inside-git-dir --is-bare-repository --is-shallow-repository --show-object-format --path-format --end-of-options -q",
    "merge-base": "--all --is-ancestor --octopus --independent --fork-point -a",
    "branch": "--list --all --remotes --verbose --no-color --color --contains --no-contains --merged --no-merged --points-at --format --sort -a -r -v -vv",
    "tag": "--list --no-color --color --contains --no-contains --merged --no-merged --points-at --format --sort -n",
    "remote": "-v --verbose",
    "check-ignore": "--quiet --verbose --non-matching --no-index -q -v -n -z",
    "cat-file": "-e -p -t -s --batch --batch-check --buffer --unordered -z -Z",
    "count-objects": "-v --verbose -H --human-readable",
    "worktree": "--porcelain -v --verbose -z",
    "blame": "--line-porcelain --porcelain --incremental --root --show-email --date --abbrev --ignore-rev --ignore-revs-file -L -l -s -e -n -p -w -M -C",
}
SHORT_VALUES = {
    "log": {"-n", "-S", "-G", "-U"},
    "show": {"-n", "-S", "-G", "-U"},
    "diff": {"-S", "-G", "-U"},
    "grep": {"-A", "-B", "-C", "-e", "-f"},
    "blame": {"-L"},
}


def git_command(argv, cwd, protected):
    executable, *argv = argv
    if executable != "git" and Path(executable).resolve() != Path(shutil.which("git") or "/usr/bin/git").resolve():
        raise Denied("未確認のGit実行fileは使えません。")
    directory = []
    while argv and argv[0] in ("--no-pager", "--no-optional-locks", "-C"):
        flag = argv.pop(0)
        if flag == "-C":
            if not argv or not argv[0] or argv[0].startswith("-"):
                raise Denied("git -Cのpathが不正です。")
            directory.extend([flag, argv.pop(0)])
    if not argv or argv[0] not in (*FLAGS, "add", "commit"):
        raise Denied("Gitは許可された読み取り用途とadd/commitだけ実行できます。履歴整理は固定rebaseスクリプトを使ってください。")
    command, *args = argv
    safe = ["git", "--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "core.hooksPath=/dev/null", "-c", "status.submoduleSummary=false", *directory]
    if command in ("add", "commit"):
        if directory:
            raise Denied("add/commitは対象repositoryのcwdから実行してください。")
        if command == "add":
            paths = args[1:] if args[:1] == ["--"] else args
            if len(paths) != 1 or paths[0].startswith("-") or paths[0] in (".", "..") or any(c in paths[0] for c in ("*", "?", ":", "\n", "\r")):
                raise Denied("git addは個別file一つだけを指定してください。")
            path = paths[0]
            check_path(path, cwd, protected)
            if (cwd / path).is_dir():
                raise Denied("git addへdirectoryは渡せません。")
            attributes = subprocess.check_output([*safe, "check-attr", "-z", "filter", "--", path], cwd=cwd, stderr=subprocess.DEVNULL).split(b"\0")
            if attributes[-2] not in (b"unspecified", b"unset"):
                raise Denied("filter付きfileのaddは外部programを実行し得るため自動許可できません。")
            canonical = shlex.join(["git", "add", "--", path])
            execution = [*safe, "--literal-pathspecs", "add", "--", path]
        else:
            if len(args) != 2 or args[0] not in ("-m", "--message") or not args[1].strip():
                raise Denied("git commitは-mと変更内容だけを指定してください。")
            canonical = shlex.join(["git", "commit", "-m", args[1]])
            execution = [*safe, "-c", "commit.gpgSign=false", "commit", "-m", args[1]]
        return {"command": shlex.join(execution), "commit_check": canonical}
    if command in ("branch", "tag") and "--list" not in args:
        raise Denied("branch・tagは--listだけ許可します。")
    if command == "remote" and args not in (["-v"], ["--verbose"]):
        raise Denied("remoteは-vだけ許可します。")
    if command == "worktree":
        if not args or args.pop(0) != "list":
            raise Denied("worktreeはlistだけ許可します。")
    allowed = set(FLAGS[command].split())
    operands = False
    need_value = False
    for arg in args:
        if need_value:
            need_value = False
            continue
        if arg == "--":
            operands = True
            continue
        if operands or not arg.startswith("-"):
            continue
        flag, sep, _ = arg.partition("=")
        if re.fullmatch(r"-[0-9]+", arg) and command in ("log", "show"):
            continue
        if re.fullmatch(r"-[nULABC][0-9]+", arg) and arg[:2] in allowed:
            continue
        if flag not in allowed:
            raise Denied("Gitの未許可optionです: " + flag)
        if flag in SHORT_VALUES.get(command, ()) and not sep:
            need_value = True
    if need_value:
        raise Denied("Git optionの値が不足しています。")
    if any("%G" in arg or "%(signature" in arg for arg in args):
        raise Denied("署名検証による外部program起動は許可しません。")
    safe.append(command)
    if command in ("diff", "log", "show"):
        safe.extend(["--no-ext-diff", "--no-textconv"])
    if command in ("log", "show"):
        safe.append("--no-show-signature")
    return {"command": shlex.join([*safe, *argv[1:]])}


def inspect(payload):
    tool = payload.get("tool_name", "")
    inputs = payload.get("tool_input") or {}
    cwd = Path(payload.get("cwd") or os.getcwd()).resolve()
    protected = metadata_paths(cwd)
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch"):
        if tool == "apply_patch":
            patch = inputs.get("command") if isinstance(inputs, dict) else inputs
            paths = re.findall(r"^\*\*\* (?:(?:Add|Update|Delete) File: |Move to: )(.+)$", patch or "", re.M)
        else:
            paths = [inputs[k] for k in ("file_path", "notebook_path", "path") if k in inputs]
            paths.extend(e["file_path"] for e in inputs.get("edits", []) if "file_path" in e)
        if not paths:
            raise Denied("編集対象pathを確認できません。")
        for path in paths:
            check_path(path, cwd, protected)
        return
    if tool != "Bash":
        return
    raw = inputs.get("command", "")
    if not raw:
        raise Denied("shell commandがありません。")
    argv = shlex.split(raw)
    while argv and argv[0] in ("command", "builtin", "exec", "env", "/usr/bin/env"):
        argv.pop(0)
        if argv and argv[0] == "--":
            argv.pop(0)
    if not argv:
        raise Denied("実行commandを確認できません。")
    if Path(argv[0]).name == "git":
        lexer = shlex.shlex(raw, posix=True, punctuation_chars=";&|<>()")
        lexer.whitespace_split = True
        if any(t in (";", "&&", "||", "|", ">", ">>", "<", "(", ")", "&") for t in lexer) or any(c in raw for c in ("$", "`", "\n", "\r")):
            raise Denied("Gitは展開・複合構文を使わず単独実行してください。")
        return git_command(argv, cwd, protected)
    if any("=" in t and t.split("=", 1)[0].startswith("GIT_") for t in argv) or (any(re.match(r"^[A-Za-z_][A-Za-z_0-9]*=", t) for t in argv) and any(Path(t).name == "git" for t in argv)) or (Path(argv[0]).name in ("sudo", "doas", "nice", "timeout") and any(Path(t).name == "git" for t in argv)):
        raise Denied("Gitの環境上書き・別wrapperによる起動は許可しません。")
    binary = Path(argv[0]).name
    mutators = {"rm", "rmdir", "unlink", "shred", "srm", "mv", "gmv", "cp", "gcp", "rsync", "install", "ln", "gln", "touch", "chmod", "chown", "chgrp", "mkdir", "truncate", "dd", "tee", "patch"}
    if binary in mutators:
        operands = [a for a in argv[1:] if not a.startswith("-")]
        if binary in ("cp", "gcp", "ln", "gln", "install", "rsync"):
            operands = operands[-1:]
        for arg in operands:
            for path in glob.glob(str(cwd / arg)) or [arg]:
                check_path(path, cwd, protected)


def main():
    try:
        payload = json.load(sys.stdin)
        return inspect(payload)
    except (ValueError, OSError, RuntimeError, TypeError, KeyError, subprocess.SubprocessError) as error:
        return {"error": str(error)}


if __name__ == "__main__":
    result = main()
    if result:
        print(json.dumps(result, ensure_ascii=False))
