import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { ModelRegistry, ModelRuntime, type ExtensionAPI, type ExtensionContext, type SessionEntry } from "@earendil-works/pi-coding-agent";
import { cleanTitle, firstUserText, generateTitle, registerSessionTitles, titleModel } from "../bridge/session-title";

const user = { type: "message", id: "user-1", parentId: null, timestamp: "now", message: { role: "user", content: [{ type: "text", text: "Polish the workspace sidebar" }, { type: "image", data: "do-not-send", mimeType: "image/png" }], timestamp: 1 } } as SessionEntry;

async function registry(baseUrl = "http://127.0.0.1:1/v1") {
  const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
  runtime.registerProvider("axo-title-test", {
    api: "openai-completions", apiKey: "local-fixture", baseUrl,
    models: [{ id: "fixture-mini", name: "Title fixture", input: ["text"], reasoning: false,
      contextWindow: 32_000, maxTokens: 512, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  });
  await runtime.getAvailable("axo-title-test");
  return new ModelRegistry(runtime);
}

test("title input contains only the first user's bounded text and validates a bounded one-line title", () => {
  assert.equal(firstUserText([user, { ...user, id: "user-2" }]), "Polish the workspace sidebar");
  assert.equal(firstUserText([{ ...user, message: { role: "user", content: "x".repeat(10_000), timestamp: 1 } } as SessionEntry]), "x".repeat(4_000));
  assert.equal(firstUserText([{ type: "custom_message", customType: "axo.attachments", details: { text: "First photo prompt", files: ["private path"] } } as unknown as SessionEntry]), "First photo prompt");
  assert.equal(cleanTitle('  "Workspace Sidebar Polish"  '), "Workspace Sidebar Polish");
  for (const invalid of ["", "first\nsecond", "x".repeat(121), "bad\u0000title"]) assert.equal(cleanTitle(invalid), undefined);
});

test("small-model selection stays on the active provider unless explicitly configured", async () => {
  const modelRegistry = await registry();
  const model = modelRegistry.find("axo-title-test", "fixture-mini")!;
  assert.equal(titleModel({ modelRegistry, model })?.id, "fixture-mini");
  assert.equal(titleModel({ modelRegistry, model: { ...model, provider: "other" } }), undefined);
  assert.equal(titleModel({ modelRegistry, model }, "missing/model"), undefined);
  assert.equal(titleModel({ modelRegistry, model }, "axo-title-test/fixture-mini")?.id, "fixture-mini");
});

test("real vanilla Pi SDK title session sends no tools, history, images, or project instructions", async () => {
  const requests: Record<string, unknown>[] = [];
  const server = createServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    requests.push(JSON.parse(body));
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end('data: {"id":"title","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"Workspace Sidebar Polish"},"finish_reason":null}]}\n\n' +
      'data: {"id":"title","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  try {
    const address = server.address() as { port: number };
    const modelRegistry = await registry(`http://127.0.0.1:${address.port}/v1`);
    const model = modelRegistry.find("axo-title-test", "fixture-mini")!;
    const result = await generateTitle({ cwd: process.cwd(), modelRegistry }, model, "Polish the workspace sidebar", new AbortController().signal);
    assert.equal(result, "Workspace Sidebar Polish");
    assert.equal(requests.length, 1);
    const request = requests[0]!;
    assert.equal(request.max_tokens ?? request.max_completion_tokens, 96);
    assert.ok(!request.tools || (Array.isArray(request.tools) && request.tools.length === 0));
    const serialized = JSON.stringify(request.messages);
    assert.ok(serialized.includes("Polish the workspace sidebar"));
    assert.ok(!serialized.includes("AGENTS.md") && !serialized.includes("do-not-send"));
    assert.equal((request.messages as unknown[]).length, 2);
    assert.equal(await generateTitle({ cwd: process.cwd(), modelRegistry }, model, "Cancelled", AbortSignal.abort()), undefined);
    assert.equal(requests.length, 1);
  } finally { server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); }
});

test("real vanilla Pi extension generates a title after the first reply and persists only title metadata", { timeout: 15_000 }, async () => {
  const root = await mkdtemp(join(tmpdir(), "axo-title-parent-"));
  const requests: Record<string, unknown>[] = [];
  const server = createServer(async (request, response) => {
    let body = ""; for await (const chunk of request) body += chunk;
    const payload = JSON.parse(body); requests.push(payload);
    const title = payload.model === "fixture-mini";
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", choices: [{ index: 0, delta: { role: "assistant", content: title ? "Workspace Sidebar Polish" : "First Pi reply" }, finish_reason: null }] })}\n\n` +
      'data: {"id":"fixture","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address() as { port: number }, sessionFile = join(root, "session.jsonl");
  const child = spawn(process.execPath, [resolve("node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"),
    "--mode", "rpc", "--session", sessionFile, "--no-extensions", "--no-tools", "--no-skills", "--no-context-files",
    "--extension", resolve("tests/fixtures/session-titles.ts"), "--model", "axo-title-parent/fixture"],
    { cwd: root, env: { ...process.env, PI_CODING_AGENT_DIR: join(root, "agent"), PI_OFFLINE: "1", PI_TELEMETRY: "0",
      AXO_AUTO_TITLE: "1", AXO_TITLE_MODEL: "axo-title-parent/fixture-mini", AXO_TEST_MODEL_URL: `http://127.0.0.1:${address.port}/v1` }, stdio: ["pipe", "pipe", "pipe"] });
  let diagnostics = "", output = "";
  child.stderr.on("data", data => { diagnostics = (diagnostics + data).slice(-8_000); });
  child.stdout.on("data", data => { output = (output + data).slice(-16_000); });
  const exited = new Promise(resolve => child.once("exit", resolve));
  try {
    child.stdin.write(JSON.stringify({ type: "prompt", id: "first", message: "Polish the workspace sidebar" }) + "\n");
    let entries: { type: string; name?: string; message?: { role: string } }[] = [];
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
      const text = await readFile(sessionFile, "utf8").catch(() => "");
      entries = text.split("\n").filter(Boolean).flatMap(line => { try { return [JSON.parse(line)]; } catch { return []; } });
      if (entries.some(entry => entry.type === "session_info" && entry.name === "Workspace Sidebar Polish")) break;
      await new Promise(resolve => setTimeout(resolve, 40));
    }
    assert.ok(entries.some(entry => entry.type === "session_info" && entry.name === "Workspace Sidebar Polish"), diagnostics + output);
    assert.deepEqual(requests.map(request => request.model), ["fixture", "fixture-mini"]);
    assert.equal(entries.filter(entry => entry.type === "message" && entry.message?.role === "user").length, 1);
    assert.equal(entries.filter(entry => entry.type === "message" && entry.message?.role === "assistant").length, 1);
    const helper = JSON.stringify(requests[1]);
    assert.ok(!helper.includes("First Pi reply"));
    assert.equal(requests[1]!.max_tokens ?? requests[1]!.max_completion_tokens, 96);
  } finally {
    child.stdin.end();
    const kill = setTimeout(() => child.kill("SIGKILL"), 2_000);
    await exited; clearTimeout(kill);
    server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  }
});

test("background naming is nonblocking, attempted once, and rejects switched or manually named destinations", async () => {
  const previous = process.env.AXO_AUTO_TITLE; process.env.AXO_AUTO_TITLE = "1";
  try {
    const modelRegistry = await registry(), model = modelRegistry.find("axo-title-test", "fixture-mini")!;
    const handlers = new Map<string, ((event: any, ctx: any) => void)[]>();
    let name: string | undefined, attempts = 0, calls = 0, finish: ((title: string) => void) | undefined;
    const entries: SessionEntry[] = [user];
    const pi = {
      on: (event: string, handler: (event: any, ctx: any) => void) => handlers.set(event, [...(handlers.get(event) ?? []), handler]),
      getSessionName: () => name, setSessionName: (title: string) => { name = title; },
      appendEntry: (customType: string) => { attempts++; entries.push({ type: "custom", customType } as SessionEntry); },
    } as unknown as ExtensionAPI;
    const ctx = { cwd: process.cwd(), modelRegistry, model, sessionManager: { getSessionId: () => "first", getEntries: () => entries, getBranch: () => entries } } as unknown as ExtensionContext;
    registerSessionTitles(pi, async () => { calls++; return new Promise(resolve => { finish = resolve; }); });
    const emit = (event: string, data = {}, context = ctx) => handlers.get(event)?.forEach(handler => handler(data, context));
    emit("session_start");
    const response = { message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "Done" }] } };
    emit("message_end", response); emit("message_end", response);
    assert.equal(calls, 1); assert.equal(attempts, 1); assert.equal(name, undefined);
    name = "Manually chosen";
    finish!("Automatic title"); await new Promise(resolve => setImmediate(resolve));
    assert.equal(name, "Manually chosen");
    name = undefined; entries.splice(1);
    emit("message_end", response);
    assert.equal(calls, 2);
    emit("session_before_switch");
    finish!("Wrong destination title"); await new Promise(resolve => setImmediate(resolve));
    assert.equal(name, undefined);
    emit("session_shutdown");
  } finally { if (previous === undefined) delete process.env.AXO_AUTO_TITLE; else process.env.AXO_AUTO_TITLE = previous; }
});
