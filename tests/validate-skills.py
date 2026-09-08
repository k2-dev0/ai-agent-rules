#!/usr/bin/env python3
"""Validate this repository's shared Claude/Codex skill format."""

import re
import sys
from pathlib import Path

import yaml


class UniqueLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        if not isinstance(key, str) or key in result:
            raise ValueError("YAML keys must be unique strings")
        result[key] = loader.construct_object(value_node)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def validate_content(content):
    match = re.match(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|\Z)", content, re.S)
    if not match:
        raise ValueError("Missing or invalid YAML frontmatter")
    data = yaml.load(match[1], Loader=UniqueLoader)
    if not isinstance(data, dict):
        raise ValueError("Frontmatter must be a mapping")
    allowed = {"name", "description", "license", "metadata", "allowed-tools",
               "disable-model-invocation", "user-invocable", "hooks"}
    if unknown := data.keys() - allowed:
        raise ValueError(f"Unknown frontmatter fields: {sorted(unknown)}")
    name = data.get("name")
    if not isinstance(name, str) or len(name) > 64 or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name):
        raise ValueError("name must be nonempty hyphen-case, at most 64 characters")
    description = data.get("description")
    if not isinstance(description, str) or not description.strip() or len(description) > 1024:
        raise ValueError("description must be a nonempty string, at most 1024 characters")
    if "<" in description or ">" in description or description.lstrip().startswith("[TODO:"):
        raise ValueError("description contains markup or an unfinished placeholder")
    for field in ("disable-model-invocation", "user-invocable"):
        if field in data and type(data[field]) is not bool:
            raise ValueError(f"{field} must be a boolean")
    if "metadata" in data and not isinstance(data["metadata"], dict):
        raise ValueError("metadata must be a mapping")
    if "license" in data and not isinstance(data["license"], str):
        raise ValueError("license must be a string")
    if "allowed-tools" in data:
        tools = data["allowed-tools"]
        if isinstance(tools, str):
            tools = [tools]
        if not isinstance(tools, list) or not tools or any(not isinstance(t, str) or not t.strip() for t in tools):
            raise ValueError("allowed-tools must be a string or a nonempty string list")
    if "hooks" in data:
        hooks = data["hooks"]
        if not isinstance(hooks, dict) or not hooks:
            raise ValueError("hooks must be a nonempty event mapping")
        for event, groups in hooks.items():
            if event not in {"PreToolUse", "PostToolUse", "Stop"} or not isinstance(groups, list) or not groups:
                raise ValueError("Unsupported hook event or invalid hook groups")
            for group in groups:
                if not isinstance(group, dict) or group.keys() - {"matcher", "hooks"}:
                    raise ValueError("Invalid hook group")
                if "matcher" in group and not isinstance(group["matcher"], str):
                    raise ValueError("hook matcher must be a string")
                commands = group.get("hooks")
                if not isinstance(commands, list) or not commands:
                    raise ValueError("hook group must contain commands")
                for command in commands:
                    if not isinstance(command, dict) or command.keys() - {"type", "command", "timeout"}:
                        raise ValueError("Invalid command hook")
                    if command.get("type") != "command" or not isinstance(command.get("command"), str) or not command["command"].strip():
                        raise ValueError("hook requires type: command and a command string")
                    if "timeout" in command and (type(command["timeout"]) is not int or command["timeout"] <= 0):
                        raise ValueError("hook timeout must be a positive integer")
    fence = None
    for line in content[match.end():].splitlines():
        marker = re.match(r"^\s*(?:[-+*]\s+|\d+[.)]\s+)?(`{3,}|~{3,})(.*)$", line)
        if marker:
            if fence is None:
                fence = marker[1]
            elif marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = None
        elif fence is None and re.fullmatch(r"\s*\[TODO:[^\n]*\]\s*", line):
            raise ValueError("Unfinished instruction placeholder")


def main(paths):
    if not paths:
        print("Usage: python3 tests/validate-skills.py <skill-directory> ...", file=sys.stderr)
        return 2
    failed = False
    for path in paths:
        try:
            source = Path(path)
            if source.is_dir():
                source = source / "SKILL.md"
            validate_content(source.read_text(encoding="utf-8"))
            print(f"PASS {path}")
        except (OSError, UnicodeError, ValueError, yaml.YAMLError) as error:
            print(f"FAIL {path}: {error}")
            failed = True
    return int(failed)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
