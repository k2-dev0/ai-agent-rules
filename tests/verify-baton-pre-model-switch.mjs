import assert from "node:assert/strict";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";

const batonRoot = process.argv[2];
if (!batonRoot) throw new Error("baton root is required");
const { loadPreModelSwitchHooks, runPreModelSwitchHooks } =
  await import(pathToFileURL(path.join(batonRoot, "src/hooks.mjs")));

const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const parent = mkdtempSync(path.join(tmpdir(), "baton-distributed-hook-"));
const root = path.join(parent, "project");
const nested = path.join(root, "src");
try {
  mkdirSync(path.join(root, ".codex/hooks/shell"), { recursive: true });
  mkdirSync(path.join(root, ".agents/skills"), { recursive: true });
  mkdirSync(nested);
  const script = path.join(root, ".codex/hooks/shell/pre-model-switch.sh");
  copyFileSync(path.join(source, "hooks/shell/pre-model-switch.sh"), script);
  chmodSync(script, 0o755);
  const document = path.join(root, ".agents/skills/MODEL_SWITCH.md");
  writeFileSync(document, "BATON_SWITCH_GUIDANCE_V1\n");
  writeFileSync(path.join(root, ".codex/hooks.json"), JSON.stringify({ hooks: {
    SessionStart: [],
    PreModelSwitch: [{ hooks: [{ type: "command", command: JSON.stringify(script), timeout: 5 }] }],
  }}));
  execFileSync("git", ["-C", root, "init", "-q"]);

  const handlers = loadPreModelSwitchHooks(nested, [root]);
  assert.equal(handlers.length, 1);
  const event = {
    event: "PreModelSwitch", threadId: "thread", turnId: "turn-1", cwd: nested,
    from: { model: "gpt-5.6-sol", effort: "high" },
    to: { model: "gpt-6-astra", config: { effort: "high" } },
  };
  const first = await runPreModelSwitchHooks(handlers, event);
  assert.equal(first.allowed, false);
  assert.equal(first.reasonCode, "denied");
  assert.match(first.reason, /PRE_MODEL_SWITCH_CONTEXT/);
  assert.match(first.reason, /BATON_SWITCH_GUIDANCE_V1/);

  const retry = await runPreModelSwitchHooks(handlers, { ...event, turnId: "turn-2" });
  assert.deepEqual(retry, { allowed: true, reasonCode: "allowed", hookCount: 1 });

  writeFileSync(document, "BATON_SWITCH_GUIDANCE_V2\n");
  const changed = await runPreModelSwitchHooks(handlers, { ...event, turnId: "turn-3" });
  assert.equal(changed.allowed, false);
  assert.match(changed.reason, /BATON_SWITCH_GUIDANCE_V2/);

  const noop = await runPreModelSwitchHooks(handlers, {
    ...event, threadId: "noop", from: { model: "gpt-5.6-sol", effort: "high" },
    to: { model: "gpt-5.6-sol", config: { effort: "high" } },
  });
  assert.deepEqual(noop, { allowed: true, reasonCode: "allowed", hookCount: 1 });
  process.stdout.write("baton PreModelSwitch integration: passed\n");
} finally {
  rmSync(parent, { recursive: true, force: true });
}
