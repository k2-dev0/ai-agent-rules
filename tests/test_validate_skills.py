import runpy
import unittest
from pathlib import Path

import yaml

validate = runpy.run_path(str(Path(__file__).with_name("validate-skills.py")))["validate_content"]


def skill(extra="", body="Instructions."):
    return f"---\nname: example\ndescription: A valid skill\n{extra}---\n{body}\n"


class SkillValidationTests(unittest.TestCase):
    def test_shared_metadata(self):
        validate(skill("disable-model-invocation: true\nuser-invocable: false\nallowed-tools: [Read, Grep]\n"))

    def test_command_hook(self):
        validate(skill("hooks:\n  PreToolUse:\n    - matcher: Edit\n      hooks:\n        - type: command\n          command: check.sh\n"))

    def test_invalid_metadata(self):
        for extra in (
            'disable-model-invocation: "true"\n', 'user-invocable: 0\n',
            "disable-model-invocation: null\n", "unknown: true\n",
            "name: duplicate\n", "allowed-tools: [Read, 5]\n",
            "hooks: []\n", "metadata: text\n", "license: false\n",
            "hooks:\n  PreToolUse:\n    - hooks:\n        - type: command\n          command: 3\n",
            "hooks:\n  PreToolUse:\n    - hooks:\n        - type: command\n          command: check\n          timeout: true\n",
        ):
            with self.subTest(extra=extra), self.assertRaises((ValueError, yaml.YAMLError)):
                validate(skill(extra))

    def test_missing_or_invalid_required_fields(self):
        for text in ("plain text", "---\n[]\n---\n", skill().replace("example", ""),
                     skill().replace("example", "Bad_Name"), skill().replace("A valid skill", ""),
                     skill().replace("A valid skill", "[broken")):
            with self.subTest(text=text), self.assertRaises((ValueError, yaml.YAMLError)):
                validate(text)

    def test_unfinished_placeholder(self):
        with self.assertRaises(ValueError):
            validate(skill(body="[TODO: finish this]"))
        validate(skill(body="```text\n[TODO: example only]\n```"))


if __name__ == "__main__":
    unittest.main()
