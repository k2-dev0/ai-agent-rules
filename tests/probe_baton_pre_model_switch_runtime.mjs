#!/usr/bin/env node
// Opt-in live probe. It proves the rejected tool result entered the old model's turn.
import assert from "node:assert/strict";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const batonRoot = realpathSync(process.argv[2] ?? (() => { throw new Error("baton root is required"); })());
const output = realpathSync(mkdtempSync(path.join(tmpdir(), "baton-pre-model-switch-live-")));
const project = path.join(output, "project");
const codex = process.env.BATON_TEST_CODEX ?? "/Applications/ChatGPT.app/Contents/Resources/codex";
const configPath = path.join(output, "config.json");
const diagnosticsPath = path.join(output, "router.jsonl");
mkdirSync(path.join(project, ".codex/hooks/shell"), { recursive: true });
mkdirSync(path.join(project, ".agents/skills"), { recursive: true });
const hook = path.join(project, ".codex/hooks/shell/pre-model-switch.sh");
copyFileSync(path.join(source, "hooks/shell/pre-model-switch.sh"), hook);
chmodSync(hook, 0o755);
copyFileSync(path.join(source, "skills/MODEL_SWITCH.md"), path.join(project, ".agents/skills/MODEL_SWITCH.md"));
writeFileSync(path.join(project, ".codex/hooks.json"), JSON.stringify({ hooks: {
  PreModelSwitch: [{ hooks: [{ type: "command", command: JSON.stringify(hook), timeout: 5 }] }],
} }));
writeFileSync(path.join(project, "AGENTS.md"), "Use only switch_model and follow its result.\n");
writeFileSync(configPath, JSON.stringify({ schemaVersion: 2, enabledRepositories: [project],
  innerCodexPath: codex, desktopAppPath: "/Applications/ChatGPT.app", maxBufferedBytes: 32 * 1024 * 1024 }));
for (const args of [["init", "-q"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"],
  ["add", "."], ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"]]) {
  const result = spawnSync("git", ["-C", project, ...args], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
}

const child = spawn(process.execPath, [path.join(batonRoot, "src/proxy.mjs"), "app-server", "--listen", "stdio://"], {
  cwd: project, stdio: ["pipe", "pipe", "pipe"],
  env: { ...process.env, CODEX_CLI_PATH: "", CODEX_BATON_CONFIG: configPath, CODEX_BATON_STATE_DIR: output },
});
const pending = new Map();
const events = [];
let sequence = 0;
let stderr = "";
let testThread;
let switched = false;
let resolveCompleted;
let rejectCompleted;
const completed = new Promise((resolve, reject) => { resolveCompleted = resolve; rejectCompleted = reject; });
completed.catch(() => {});
child.stderr.on("data", data => { stderr += data; });
child.on("error", rejectCompleted);
child.on("exit", code => { if (code !== null && code !== 0) rejectCompleted(new Error(`Baton exited ${code}: ${stderr.slice(-2000)}`)); });
const send = (method, params) => new Promise((resolve, reject) => {
  const id = ++sequence;
  pending.set(id, { resolve, reject });
  child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
});
createInterface({ input: child.stdout }).on("line", line => {
  const message = JSON.parse(line);
  events.push(message);
  if (message.id !== undefined && !message.method && pending.has(message.id)) {
    const request = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) request.reject(new Error(JSON.stringify(message.error)));
    else request.resolve(message.result);
  }
  if (message.method === "thread/settings/updated" && message.params?.threadSettings?.model === "gpt-6-astra") switched = true;
  if (switched && message.method === "turn/completed" && message.params?.turn?.status !== "interrupted") resolveCompleted(message.params);
  if (message.method && message.id !== undefined) rejectCompleted(new Error(`Unexpected server request: ${message.method}`));
});

function strings(value, found = []) {
  if (typeof value === "string") found.push(value);
  else if (Array.isArray(value)) value.forEach(item => strings(item, found));
  else if (value && typeof value === "object") Object.values(value).forEach(item => strings(item, found));
  return found;
}

const timeout = setTimeout(() => rejectCompleted(new Error(`Live probe timed out: ${stderr.slice(-2000)}`)), 240_000);
try {
  await send("initialize", { clientInfo: { name: "pre_model_switch_probe", version: "1" }, capabilities: { experimentalApi: true } });
  child.stdin.write(`${JSON.stringify({ method: "initialized", params: {} })}\n`);
  const started = await send("thread/start", { model: "gpt-5.6-sol", cwd: project, ephemeral: false,
    experimentalRawEvents: true, developerInstructions: "Call only switch_model and follow its result. After the applied continuation, answer exactly PRE_MODEL_SWITCH_LIVE_OK." });
  testThread = started.thread;
  await send("turn/start", { threadId: testThread.id, effort: "high", input: [{ type: "text",
    text: 'Call switch_model({"model":"gpt-6-astra","config":{"effort":"high"}}) alone. Follow its result. After the applied continuation answer exactly PRE_MODEL_SWITCH_LIVE_OK.' }] });
  await completed;
  const dynamicCalls = events.filter(event => event.method === "item/completed" &&
    event.params?.item?.type === "dynamicToolCall" && event.params.item.tool === "switch_model");
  assert.equal(dynamicCalls.length, 2, "the old model must retry exactly once");
  assert.equal(dynamicCalls[0].params.item.success, false);
  assert.equal(dynamicCalls[1].params.item.success, true);
  const delivered = strings(dynamicCalls[0]).find(text => text.includes("PRE_MODEL_SWITCH_CONTEXT"));
  assert.ok(delivered?.includes("# メインモデルの切り替え"), "the failed tool result must contain MODEL_SWITCH.md");
  assert.ok(events.some(event => event.method === "item/completed" && event.params?.item?.type === "agentMessage" &&
    event.params.item.text.trim() === "PRE_MODEL_SWITCH_LIVE_OK"));
  const rollout = readFileSync(testThread.path, "utf8");
  writeFileSync(path.join(output, "rollout.jsonl"), rollout, { mode: 0o600 });
  const records = rollout.trim().split("\n").map(JSON.parse);
  const runtimeCalls = records.filter(record => record.type === "event_msg" && record.payload?.type === "item_completed" &&
    record.payload.item?.type === "DynamicToolCall" && record.payload.item.tool === "switch_model");
  assert.equal(runtimeCalls.length, 2, "runtime history must contain the failed call and one retry");
  const document = readFileSync(path.join(project, ".agents/skills/MODEL_SWITCH.md"), "utf8");
  const expected = "PRE_MODEL_SWITCH_CONTEXT: 切替手順を注入しました。モデル・設定は変更していません。同じswitch_model要求を一度だけ再試行してください。\n\n" + document.trimEnd();
  const runtimeDelivered = runtimeCalls[0].payload.item.content_items?.find(item => item.type === "inputText")?.text;
  assert.equal(runtimeDelivered, expected, "the failed tool result must equal the distributed document");
  assert.equal(runtimeCalls[0].payload.item.success, false);
  assert.equal(runtimeCalls[1].payload.item.success, true);
  const metrics = { old_model: "gpt-5.6-sol", target_model: "gpt-6-astra", context_bytes: Buffer.byteLength(runtimeDelivered),
    context_injections: 1, unnecessary_injections: 0, retry_calls: 1, final_status: "completed" };
  writeFileSync(path.join(output, "report.json"), JSON.stringify(metrics, null, 2), { mode: 0o600 });
  writeFileSync(path.join(output, "events.json"), JSON.stringify(events, null, 2), { mode: 0o600 });
  process.stdout.write(`${output}\n${JSON.stringify(metrics)}\n`);
} finally {
  clearTimeout(timeout);
  writeFileSync(path.join(output, "events.json"), JSON.stringify(events, null, 2), { mode: 0o600 });
  writeFileSync(path.join(output, "stderr.txt"), stderr, { mode: 0o600 });
  if (testThread) await send("thread/archive", { threadId: testThread.id }).catch(() => {});
  child.stdin.end();
  child.kill("SIGTERM");
}
