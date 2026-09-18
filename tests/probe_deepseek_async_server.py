"""Shortened-timeout stdio MCP fixture for observing Codex async hook delivery.

Run outside the enclosing sandbox with the bridge's Python, started from the
repository Codex binds as the worker workspace:
  <bridge>/.venv/bin/python <rules>/tests/probe_deepseek_async_server.py \\
      --bridge-root <bridge> --scenario completed

The real bridge stdio server, TaskManager, Runtime and DSH stay in use; only the
external model is simulated by the bridge's tested SSE endpoint fixture. The
model calls its shell tool with `sleep 2` for `completed`, or `sleep 30` for
`timeout`, where this process also sets tasks.HARD_TIMEOUT_SECONDS and
tasks.INACTIVITY_TIMEOUT_SECONDS to 5. Bridge state goes to a TemporaryDirectory,
DEEPSEEK_API_KEY is the endpoint fixture's fixed canary and DEEPSEEK_BASE_URL is
that fixture's local URL; no real key or remote endpoint is read. stdout carries
MCP messages only.

This fixture alone does not prove Codex hook auto-delivery success: the parent
must run it under the real Codex MCP client and observe the hook delivery there.
"""

import argparse
import importlib
import os
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge-root", type=Path, required=True)
    parser.add_argument("--scenario", choices=("completed", "timeout"), required=True)
    args = parser.parse_args()
    root = args.bridge_root.resolve(strict=True)
    sys.path.insert(0, str(root / "src"))
    sys.path.insert(0, str(root / "tests"))
    # Use the bridge's tested SSE fixture; only the external model is simulated.
    wire = importlib.import_module("test_privacy_wire")
    fixture = wire.endpoint.__wrapped__()
    endpoint = next(fixture)
    try:
        with tempfile.TemporaryDirectory(prefix="deepseek-async-hook-state-") as state:
            from deepseek_bridge import privacy, tasks

            privacy.user_state_path = lambda *args, **kwargs: Path(state)
            if args.scenario == "timeout":
                # Keep the production deadline path, but bound the wait so the
                # parent can observe hook delivery without the real deadlines.
                tasks.HARD_TIMEOUT_SECONDS = 5
                tasks.INACTIVITY_TIMEOUT_SECONDS = 5
            endpoint["mode"] = "tool"
            endpoint["command"] = "sleep 2" if args.scenario == "completed" else "sleep 30"
            os.environ["DEEPSEEK_API_KEY"] = wire.KEY
            os.environ["DEEPSEEK_BASE_URL"] = endpoint["url"]
            from deepseek_bridge import server

            server.main()
    finally:
        try:
            next(fixture)
        except StopIteration:
            pass


if __name__ == "__main__":
    main()
