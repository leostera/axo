// Launch staged runtime by absolute path without PATH shims or the build cache.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, mkdtempSync, realpathSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

assert.equal(process.platform, "win32");
assert.equal(process.versions.bun, "1.4.5");
assert.equal(process.argv.length, 3, "Usage: bun.exe smoke.mjs <staged-pi-directory>");
const bundle = resolve(process.argv[2]);
const bun = join(bundle, "bun.exe");
const cli = join(bundle, "node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
const root = mkdtempSync(join(tmpdir(), "axo-pi-package-test-"));
const cwd = join(root, "destination ž");
mkdirSync(cwd);
const id = randomUUID();
const file = join(root, `${id}.jsonl`);
const timestamp = new Date().toISOString();
const origin = `Forked from fixture-source (/fixture/source) to fixture-windows (${cwd}). Previous tool output is historical; project files were not copied.`;
const contents = [
  { type: "session", version: 3, id, cwd, timestamp },
  { type: "message", id: "a", parentId: null, timestamp, message: { role: "user", timestamp: Date.now(), content: [{ type: "text", text: "disposable fixture" }] } },
  { type: "custom_message", customType: "axo_host_fork", id: "b", parentId: "a", timestamp, display: false, content: origin },
].map(record => JSON.stringify(record) + "\n").join("");
writeFileSync(file, contents, { flag: "wx" });

// A replacement environment cannot inherit user auth, NODE_PATH or Bun's install cache.
const child = spawn(bun, [cli, "--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files", "--session", file], {
  cwd,
  env: {
    SystemRoot: process.env.SystemRoot,
    TEMP: root,
    TMP: root,
    USERPROFILE: root,
    HOME: root,
    PATH: "",
    BUN_INSTALL_CACHE_DIR: join(root, "empty-cache"),
    PI_CODING_AGENT_DIR: join(root, "agent"),
  },
  windowsHide: true,
  stdio: ["pipe", "pipe", "inherit"],
});
const events = [];
const responses = new Map();
const output = createInterface({ input: child.stdout });
const exit = new Promise((resolveExit, reject) => {
  child.once("error", reject);
  child.once("close", resolveExit);
});
const requests = (async () => {
  for await (const line of output) {
    const record = JSON.parse(line);
    if (record.type === "response") {
      assert.equal(record.success, true, JSON.stringify(record));
      responses.set(record.id, record.data);
      if (responses.size === 2) break;
    } else {
      events.push(record.type);
    }
  }
})();
try {
  child.stdin.write('{"id":"state","type":"get_state"}\n{"id":"messages","type":"get_messages"}\n');
  let deadline;
  try {
    await Promise.race([requests, new Promise((_, reject) => {
      deadline = setTimeout(() => reject(Error("Pi RPC timed out")), 20_000);
    })]);
  } finally {
    clearTimeout(deadline);
  }
  const state = responses.get("state");
  const messages = responses.get("messages")?.messages;
  assert.equal(state?.sessionId, id);
  assert.equal(realpathSync(state.sessionFile), realpathSync(file));
  assert.equal(state.isStreaming, false);
  assert.equal(state.pendingMessageCount, 0);
  assert.equal(messages?.length, 2);
  assert.equal(messages[1].role, "custom");
  assert.equal(messages[1].display, false);
  assert.equal(messages[1].content, origin);
  assert(!events.some(event => ["agent_start", "tool_execution_start"].includes(event)));
  // First startup can persist Pi's default thinking level, not a chat turn.
  const persisted = readFileSync(file, "utf8");
  assert(persisted.startsWith(contents));
  const appended = persisted.slice(contents.length).trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
  assert(appended.every(entry => entry.type === "thinking_level_change"));
  console.log(JSON.stringify({ id, cwd, transcript: file, hiddenOrigin: messages[1], status: "idle", pendingMessageCount: state.pendingMessageCount }));
} finally {
  child.stdin.end();
  child.kill();
  await exit;
}
