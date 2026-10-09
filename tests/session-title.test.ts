import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import type { ExtensionAPI, ExtensionContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { cleanTitle, registerSessionTitles } from "../bridge/session-title";

function fixture() {
  const handlers = new Map<string, ((event: any, ctx: any) => void)[]>();
  let tool: ToolDefinition<any>, name: string | undefined, conversation = "first", file = "/first.jsonl", waits = 0;
  let confirm: () => Promise<boolean> = async () => false;
  const entries: any[] = [], titles: string[] = [];
  const pi = {
    on: (event: string, handler: (event: any, ctx: any) => void) => handlers.set(event, [...(handlers.get(event) ?? []), handler]),
    registerTool: (value: ToolDefinition<any>) => { tool = value; },
    getSessionName: () => name, setSessionName: (title: string) => { name = title; titles.push(title); },
    appendEntry: (customType: string, data: unknown) => entries.push({ type: "custom", customType, data }),
  } as unknown as ExtensionAPI;
  const ctx = { hasUI: true, ui: { confirm: () => confirm() }, sessionManager: {
    getSessionId: () => conversation, getSessionFile: () => file, getEntries: () => entries,
  } } as unknown as ExtensionContext;
  registerSessionTitles(pi, () => { waits++; return () => { waits--; }; });
  const emit = (event: string, data = {}) => handlers.get(event)?.forEach(handler => handler(data, ctx));
  const execute = (title: string, replace = false, signal?: AbortSignal, id = crypto.randomUUID()) => {
    emit("tool_call", { toolName: "axo_set_title", toolCallId: id });
    return tool.execute(id, { title, replace }, signal, undefined, ctx as any);
  };
  const prompt = () => {
    const event = { systemPromptOptions: { sections: {} as Record<string, string>, selectedTools: ["axo_set_title"] } };
    emit("before_agent_start", event); return event;
  };
  return { emit, execute, prompt, titles, entries, ctx, get tool() { return tool; }, get waits() { return waits; },
    setName: (value: string) => { name = value; }, setConfirm: (fn: () => Promise<boolean>) => { confirm = fn; },
    switchTo: (id: string) => { conversation = id; file = `/${id}.jsonl`; } };
}

test("title validation bounds UTF-8 bytes, lines, control characters, and Unicode titles", () => {
  assert.equal(cleanTitle('  "Workspace Sidebar Polish"  '), "Workspace Sidebar Polish");
  assert.equal(cleanTitle("語".repeat(40)), "語".repeat(40));
  for (const invalid of ["", "first\nsecond", "x".repeat(121), "語".repeat(41), "bad\u0000title"]) assert.equal(cleanTitle(invalid), undefined);
});

test("title guidance is a structured prompt section, not startup execution or a user message", async () => {
  const previous = process.env.AXO_AUTO_TITLE; process.env.AXO_AUTO_TITLE = "1";
  try {
    const f = fixture(); f.emit("session_start");
    assert.equal(f.tool.name, "axo_set_title"); assert.deepEqual(f.titles, []); assert.equal(f.entries.length, 0);
    assert.match(f.prompt().systemPromptOptions.sections.axo_conversation_title!, /user's first request/);
    await f.execute("Workspace Sidebar Polish");
    assert.deepEqual(f.titles, ["Workspace Sidebar Polish"]);
    assert.equal(f.entries[0].customType, "axo.title_set");
    assert.equal(f.prompt().systemPromptOptions.sections.axo_conversation_title, undefined);
    process.env.AXO_AUTO_TITLE = "0";
    const disabled = fixture(); disabled.emit("session_start");
    assert.equal(disabled.prompt().systemPromptOptions.sections.axo_conversation_title, undefined);
    await disabled.execute("Explicit naming still works");
  } finally { if (previous === undefined) delete process.env.AXO_AUTO_TITLE; else process.env.AXO_AUTO_TITLE = previous; }
});

test("existing titles are idempotent or require real approval; cancel and newer manual names win", async () => {
  const f = fixture(); f.emit("session_start"); f.setName("Manual name");
  await f.execute("Manual name"); assert.deepEqual(f.titles, []);
  await assert.rejects(f.execute("Automatic overwrite"), /already has a title/);
  await assert.rejects(f.execute("Cancelled replacement", true), /cancelled/);
  assert.equal(f.waits, 0); assert.deepEqual(f.titles, []);
  f.setConfirm(async () => true);
  await f.execute("Approved replacement", true);
  assert.deepEqual(f.titles, ["Approved replacement"]);
  f.setConfirm(async () => { f.setName("Newer manual name"); return true; });
  await assert.rejects(f.execute("Wrong replacement", true), /newer title/);
  assert.deepEqual(f.titles, ["Approved replacement"]);
});

test("stable tool-call destinations reject cancellation, switch/fork/tree/shutdown, and stale approval", async () => {
  for (const event of ["session_before_switch", "session_before_fork", "session_before_tree", "session_shutdown"]) {
    const f = fixture(); f.emit("session_start"); f.setName("Original");
    let approve!: (value: boolean) => void;
    f.setConfirm(() => new Promise(resolve => { approve = resolve; }));
    const pending = f.execute("Stale title", true);
    assert.equal(f.waits, 1);
    f.emit(event); f.switchTo("second"); f.emit("session_start"); approve(true);
    await assert.rejects(pending, /conversation changed/); assert.deepEqual(f.titles, []); assert.equal(f.waits, 0);
  }
  const f = fixture(); f.emit("session_start");
  await assert.rejects(f.execute("Aborted title", false, AbortSignal.abort()), /cancelled/);
  await assert.rejects(f.execute("bad\ntitle"), /single-line/);
  assert.deepEqual(f.titles, []);
});

test("real vanilla Pi CLI calls axo_set_title in the main turn without a helper model or fake user message", { timeout: 15_000 }, async () => {
  const root = await mkdtemp(join(tmpdir(), "axo-title-tool-"));
  const requests: any[] = [];
  const server = createServer(async (request, response) => {
    let body = ""; for await (const chunk of request) body += chunk;
    requests.push(JSON.parse(body));
    const first = requests.length === 1;
    const delta = first ? { role: "assistant", tool_calls: [{ index: 0, id: "title-call", type: "function", function: {
      name: "axo_set_title", arguments: JSON.stringify({ title: "Workspace Sidebar Polish" }),
    } }] } : { role: "assistant", content: "First Pi reply" };
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", choices: [{ index: 0, delta, finish_reason: null }] })}\n\n` +
      `data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: first ? "tool_calls" : "stop" }] })}\n\ndata: [DONE]\n\n`);
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address() as { port: number }, sessionFile = join(root, "session.jsonl");
  const stateFile = join(root, "state.json"), runtimeGeneration = crypto.randomUUID();
  const child = spawn(process.execPath, [resolve("node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"),
    "--mode", "rpc", "--session", sessionFile, "--no-extensions", "--no-skills", "--no-context-files",
    "--extension", resolve("tests/fixtures/session-titles.ts"), "--model", "axo-title-parent/fixture"],
    { cwd: root, env: { ...process.env, PI_CODING_AGENT_DIR: join(root, "agent"), PI_OFFLINE: "1", PI_TELEMETRY: "0",
      AXO_AUTO_TITLE: "1", AXO_STATE_FILE: stateFile, AXO_MANAGED_SESSION_FILE: sessionFile,
      AXO_WORK_SESSION_ID: crypto.randomUUID(), AXO_PANE_ID: crypto.randomUUID(), AXO_RUNTIME_GENERATION: runtimeGeneration,
      AXO_TEST_MODEL_URL: `http://127.0.0.1:${address.port}/v1` }, stdio: ["pipe", "pipe", "pipe"] });
  let diagnostics = "", output = "";
  child.stderr.on("data", data => { diagnostics = (diagnostics + data).slice(-8_000); });
  child.stdout.on("data", data => { output = (output + data).slice(-16_000); });
  const exited = new Promise(resolve => child.once("exit", resolve));
  const pause = () => new Promise(resolve => setTimeout(resolve, 40));
  try {
    let state: any;
    const startup = Date.now() + 5_000;
    while (Date.now() < startup) {
      state = JSON.parse(await readFile(stateFile, "utf8").catch(() => "null"));
      if (state) break; await pause();
    }
    assert.equal(state?.state, "idle", diagnostics + output); assert.equal(requests.length, 0);
    child.stdin.write(JSON.stringify({ type: "prompt", id: "first", message: "Polish the workspace sidebar" }) + "\n");
    let entries: any[] = [];
    const deadline = Date.now() + 8_000;
    while (Date.now() < deadline) {
      const text = await readFile(sessionFile, "utf8").catch(() => "");
      entries = text.split("\n").filter(Boolean).flatMap(line => { try { return [JSON.parse(line)]; } catch { return []; } });
      state = JSON.parse(await readFile(stateFile, "utf8").catch(() => "null"));
      if (state?.state === "attention" && entries.some(entry => entry.message?.role === "toolResult")) break;
      await pause();
    }
    assert.ok(entries.some(entry => entry.type === "session_info" && entry.name === "Workspace Sidebar Polish"), diagnostics + output);
    assert.deepEqual(requests.map(request => request.model), ["fixture", "fixture"]);
    assert.ok(requests[0].tools.some((tool: any) => tool.function?.name === "axo_set_title"));
    assert.ok(JSON.stringify(requests[0].messages).includes("axo_conversation_title"));
    assert.equal(entries.filter(entry => entry.type === "message" && entry.message?.role === "user").length, 1);
    assert.equal(entries.filter(entry => entry.type === "custom_message").length, 0);
    assert.ok(entries.some(entry => entry.message?.role === "toolResult" && entry.message.toolName === "axo_set_title"));
    assert.equal(state.attentionReason, "result"); assert.equal(state.runtimeGeneration, runtimeGeneration);
    assert.ok(state.conversationID && state.attentionID);
    assert.ok(!JSON.stringify(state).includes("Polish the workspace sidebar"));
  } finally {
    child.stdin.end(); const kill = setTimeout(() => child.kill("SIGKILL"), 2_000);
    await exited; clearTimeout(kill);
    server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  }
});
