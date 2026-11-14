import assert from "node:assert/strict";
import { test } from "node:test";
import { AI_METHOD, BASH_METHOD, COMPUTER_METHOD, COMPUTER_STATUS_METHOD, APPS_ERRORS, appsResults } from "@axo/protocol";
import { harness, signIn } from "./harness";
import { GEMMA } from "./ai-fixtures";
const AI_MODEL = GEMMA.model;
import { connectHost, pairHost } from "./account-support";

/**
 * RFD0016: a Session's `axo.apps.*` calls cross its Mac's socket to the account, and a
 * script's `bash.run` or `computer.run` (RFD0028) crosses the target Mac's socket back. Scripts
 * run in a Dynamic Worker.
 */

type Sent = { id: string; method: string; params: Record<string, unknown> };
type Reply = { result: unknown } | { error: { code: number; message: string } };

async function fixture(t: { after(fn: () => unknown): void }) {
  const h = await harness();
  t.after(() => h.close());
  const session = await signIn(h);
  const laptop = await pairHost(h, session, "Leo's Laptop");
  const studio = await pairHost(h, session, "Studio");
  const laptopDaemon = await connectHost(h, session, laptop);
  t.after(() => laptopDaemon.close());
  const sessionId = crypto.randomUUID();
  const call = (method: string, params: Record<string, unknown> = {}) =>
    laptopDaemon.call(method, { sessionId, ...params }) as Promise<Reply>;
  return { h, session, laptop, studio, laptopDaemon, sessionId, call };
}

function result(reply: Reply): unknown {
  assert.ok("result" in reply, JSON.stringify(reply));
  return reply.result;
}

function error(reply: Reply): { code: number; message: string } {
  assert.ok("error" in reply, JSON.stringify(reply));
  return reply.error;
}

test("every paired Mac is a host connection, named after its label, online while connected", async (t) => {
  const { laptop, studio, call } = await fixture(t);
  const listed = appsResults["axo.apps.list"].parse(result(await call("axo.apps.list")));
  assert.deepEqual(listed.apps.filter((c) => c.kind === "host"), [
    { kind: "host", name: "leo_s_laptop", hostId: laptop.hostId, state: "online" },
    { kind: "host", name: "studio", hostId: studio.hostId, state: "offline" },
  ]);
});

test("a script runs a command on another Mac, through that Mac's socket, and the call is logged", async (t) => {
  const { h, session, studio, laptop, sessionId, call } = await fixture(t);
  const studioDaemon = await connectHost(h, session, studio);
  t.after(() => studioDaemon.close());

  const running = call("axo.apps.run", {
    code: `async () => {
      console.log("asking the studio");
      const r = await codemode.bash.run({ host: "studio", command: "uptime", cwd: "/tmp" });
      return { out: r.stdout, code: r.exitCode };
    }`,
  });
  const sent = (await studioDaemon.next()) as Sent;
  assert.equal(sent.method, BASH_METHOD);
  assert.deepEqual(
    { ...sent.params, callId: typeof sent.params.callId },
    { accountId: session.accountId, callId: "string", command: "uptime", cwd: "/tmp", timeoutMs: 60_000 },
  );
  studioDaemon.send({
    jsonrpc: "2.0",
    id: sent.id,
    result: { exitCode: 0, signal: null, stdout: "up 3 days\n", stderr: "", stdoutTruncated: false, stderrTruncated: false, timedOut: false, durationMs: 12 },
  });
  assert.deepEqual(result(await running), { result: { out: "up 3 days\n", code: 0 }, logs: ["asking the studio"] });

  const log = appsResults["axo.apps.log"].parse(result(await call("axo.apps.log")));
  assert.equal(log.records.length, 1);
  const [record] = log.records;
  assert.equal(record!.callId, sent.params.callId);
  assert.deepEqual(
    { sessionId: record!.sessionId, hostId: record!.hostId, service: record!.service, tool: record!.tool, target: record!.targetHostId, outcome: record!.outcome, input: record!.input },
    { sessionId, hostId: laptop.hostId, service: "bash", tool: "run", target: studio.hostId, outcome: "ok", input: { host: "studio", command: "uptime", cwd: "/tmp", timeoutMs: 60_000 } },
  );
});

test("a command on an offline Mac fails naming the online ones, with nothing sent or logged", async (t) => {
  const { call } = await fixture(t);
  const failed = error(await call("axo.apps.run", { code: `async () => codemode.bash.run({ host: "studio", command: "true" })` }));
  assert.equal(failed.code, APPS_ERRORS.scriptFailed);
  assert.match(failed.message, /studio is offline; online now: leo_s_laptop/);
  const unknown = error(await call("axo.apps.run", { code: `async () => codemode.computer.run({ host: "workbench", tool: "click" })` }));
  assert.match(unknown.message, /no Mac named workbench; the account's Macs: leo_s_laptop, studio/);
  const log = appsResults["axo.apps.log"].parse(result(await call("axo.apps.log")));
  assert.deepEqual(log.records, []);
});

test("hosts.list names every Mac, says which one the script runs from, and asks online Macs about computer use", async (t) => {
  const { h, session, studio, laptopDaemon, call } = await fixture(t);
  const studioDaemon = await connectHost(h, session, studio);
  t.after(() => studioDaemon.close());
  const listing = call("axo.apps.run", { code: `async () => codemode.hosts.list()` });
  // Both Macs are online; the laptop (an older Axo) says nothing, the studio answers.
  const asked = (await studioDaemon.next()) as Sent;
  assert.equal(asked.method, COMPUTER_STATUS_METHOD);
  // A locked Mac says so: its computer calls are refused until the person unlocks it.
  studioDaemon.send({ jsonrpc: "2.0", id: asked.id, result: { available: true, accessibility: true, screenRecording: true, locked: true } });
  const ignored = (await laptopDaemon.next()) as Sent;
  assert.equal(ignored.method, COMPUTER_STATUS_METHOD);
  laptopDaemon.send({ jsonrpc: "2.0", id: ignored.id, error: { code: -32601, message: "Method not found" } });
  assert.deepEqual(result(await listing), {
    result: [
      { name: "leo_s_laptop", label: "Leo's Laptop", online: true, kind: "macos", self: true, computerUse: null },
      { name: "studio", label: "Studio", online: true, kind: "macos", self: false, computerUse: { available: true, accessibility: true, screenRecording: true, locked: true } },
    ],
    logs: [],
  });
});

test("computer.run drives another Mac: the Mac gets the tool, the calling Session and Mac, and its images come back as assets", async (t) => {
  const { h, session, studio, laptop, sessionId, call } = await fixture(t);
  const studioDaemon = await connectHost(h, session, studio);
  t.after(() => studioDaemon.close());
  const running = call("axo.apps.run", {
    code: `async () => codemode.computer.run({ host: "studio", tool: "click", args: { pid: 7, element_token: "s1:4" }, confirm: true })`,
  });
  const sent = (await studioDaemon.next()) as Sent;
  assert.equal(sent.method, COMPUTER_METHOD);
  assert.deepEqual(
    { ...sent.params, callId: typeof sent.params.callId, timeoutMs: typeof sent.params.timeoutMs },
    { accountId: session.accountId, callId: "string", tool: "click", args: { pid: 7, element_token: "s1:4" }, confirm: true, sessionId, from: "Leo's Laptop", timeoutMs: "number" },
  );
  const image = { type: "image", attachment: { asset: `sha256:${"a".repeat(64)}`, name: "click-1.png", mimeType: "image/png", size: 1234 } };
  studioDaemon.send({ jsonrpc: "2.0", id: sent.id, result: { content: [{ type: "text", text: "clicked" }, image] } });
  assert.deepEqual((result(await running) as { result: unknown }).result, { content: [{ type: "text", text: "clicked" }, image] });
  const log = appsResults["axo.apps.log"].parse(result(await call("axo.apps.log")));
  assert.deepEqual(
    log.records.map((r) => ({ service: r.service, tool: r.tool, hostId: r.hostId, target: r.targetHostId, outcome: r.outcome, input: r.input })),
    [{ service: "computer", tool: "click", hostId: laptop.hostId, target: studio.hostId, outcome: "ok", input: { host: "studio", tool: "click", args: { pid: 7, element_token: "s1:4" }, confirm: true } }],
  );
});

test("a Mac's name is no longer a service, and the namespaces are reserved", async (t) => {
  const { call } = await fixture(t);
  const old = error(await call("axo.apps.run", { code: `async () => codemode.studio.bash({ command: "true" })` }));
  assert.match(old.message, /studio is a Mac: call codemode.bash.run/);
  for (const name of ["hosts", "computer", "bash", "apps", "ai"]) {
    assert.equal(error(await call("axo.apps.add", { name, url: "https://mcp.example.com/mcp" })).code, APPS_ERRORS.nameTaken, name);
  }
});

test("a command whose Mac drops mid-run fails as may-have-run and is not sent again", async (t) => {
  const { h, session, studio, call } = await fixture(t);
  const studioDaemon = await connectHost(h, session, studio);
  const running = call("axo.apps.run", { code: `async () => codemode.bash.run({ host: "studio", command: "sleep 5" })` });
  await studioDaemon.next();
  studioDaemon.close();
  const failed = error(await running);
  assert.match(failed.message, /may have run/);
  const log = appsResults["axo.apps.log"].parse(result(await call("axo.apps.log")));
  assert.deepEqual(log.records.map((r) => r.outcome), ["unknown"]);
});

test("a search reads every tool's definition and calls none", async (t) => {
  const { call } = await fixture(t);
  assert.deepEqual(
    result(await call("axo.apps.search", { code: `async () => codemode.tools().filter((t) => !t.service.startsWith("apps.")).map((t) => t.service + "." + t.name)` })),
    { result: ["hosts.list", "bash.run", "computer.run", "ai.capabilities", "ai.list", "ai.info", "ai.install", "ai.load", "ai.unload", "ai.run", "assets.list", "assets.get", "assets.read", "assets.save"] },
  );
  const refused = error(await call("axo.apps.search", { code: `async () => codemode.bash.run({ host: "studio", command: "true" })` }));
  assert.match(refused.message, /cannot call tools/);
});

const gemmaSource = GEMMA.source;

test("ai.run targets a Mac and never persists the prompt or generated output in its call log", async (t) => {
  const { h, session, studio, call } = await fixture(t);
  const daemon = await connectHost(h, session, studio);
  t.after(() => daemon.close());
  const running = call("axo.apps.run", { code: `async () => codemode.ai.run({ host: "studio", model: ${JSON.stringify(AI_MODEL)}, prompt: "private prompt" })` });
  const sent = await daemon.next() as Sent;
  assert.equal(sent.method, AI_METHOD);
  assert.deepEqual(sent.params.request, { op: "run", model: AI_MODEL, task: "generate", input: "private prompt", maxTokens: 512 });
  assert.equal(sent.params.accountId, session.accountId);
  assert.ok(Number(sent.params.timeoutMs) > 0 && Number(sent.params.timeoutMs) <= 240_000);
  const answer = { model: AI_MODEL, task: "generate", text: "private output", finishReason: "stop", source: gemmaSource };
  daemon.send({ jsonrpc: "2.0", id: sent.id, result: answer });
  assert.deepEqual(result(await running), { result: answer, logs: [] });
  const log = appsResults["axo.apps.log"].parse(result(await call("axo.apps.log")));
  assert.deepEqual(log.records.map(r => [r.service, r.tool, r.input, r.outcome]), [["ai", "run", { host: "studio", model: AI_MODEL, task: "generate" }, "ok"]]);
  assert.doesNotMatch(JSON.stringify(log), /private prompt|private output/);
});

test("ai lifecycle defaults to self, validates receipts and sends one operation at a time from a script", async (t) => {
  const { laptopDaemon, call } = await fixture(t);
  for (const tool of ["install", "load", "unload"] as const) {
    const running = call("axo.apps.run", { code: `async () => codemode.ai.${tool}({ model: ${JSON.stringify(AI_MODEL)} })` });
    const sent = await laptopDaemon.next() as Sent;
    assert.equal(sent.method, AI_METHOD);
    assert.deepEqual(sent.params.request, { op: tool, model: AI_MODEL, ...(tool === "load" ? { task: "generate" } : {}) });
    const answer = tool === "unload" ? { model: AI_MODEL, status: "stopped" }
      : { model: AI_MODEL, source: gemmaSource, ...(tool === "install" ? { installed: true } : { status: "loaded", task: "generate" }) };
    laptopDaemon.send({ jsonrpc: "2.0", id: sent.id, result: answer });
    assert.deepEqual(result(await running), { result: answer, logs: [] });
  }
});

test("ai rejects malformed references, unknown fields and oversized UTF-8 prompts before routing or logging", async (t) => {
  const { call } = await fixture(t);
  for (const args of [
    { model: "https://unknown/model", input: "x" },
    { model: AI_MODEL, prompt: "x", url: "https://example.com" },
    { model: AI_MODEL, prompt: "x", maxTokens: 4097 },
  ]) {
    assert.equal(error(await call("axo.apps.run", { code: `async () => codemode.ai.run(${JSON.stringify(args)})` })).code, APPS_ERRORS.scriptFailed);
  }
  assert.match(error(await call("axo.apps.run", { code: `async () => codemode.ai.run({model:${JSON.stringify(AI_MODEL)},prompt:"💛".repeat(9000)})` })).message, /UTF-8/);
  const log = appsResults["axo.apps.log"].parse(result(await call("axo.apps.log")));
  assert.deepEqual(log.records, []);
});

test("ai rejects a malformed model result and records unknown rather than accepting false provenance", async (t) => {
  const { laptopDaemon, call } = await fixture(t);
  const running = call("axo.apps.run", { code: `async () => codemode.ai.run({model:${JSON.stringify(AI_MODEL)},prompt:"x"})` });
  const sent = await laptopDaemon.next() as Sent;
  laptopDaemon.send({ jsonrpc: "2.0", id: sent.id, result: { model: AI_MODEL, task: "generate", text: "x", finishReason: "stop", source: { ...gemmaSource, revision: "main" } } });
  assert.match(error(await running).message, /invalid AI result/);
  const log = appsResults["axo.apps.log"].parse(result(await call("axo.apps.log")));
  assert.equal(log.records[0]?.outcome, "unknown");
});

test("ai accepts arbitrary HF model names and forwards real image attachments for typed classification", async (t) => {
  const { laptopDaemon, call } = await fixture(t);
  const model = "hf:someone/new-decision-model:Q4_K_M";
  const image = { asset: `sha256:${"b".repeat(64)}`, name: "photo.png", mimeType: "image/png", size: 128 };
  const input = { state: { task: "private photo" }, images: [image], questions: { portrait: { type: "noul", instructions: "Is this a portrait?" } } };
  const running = call("axo.apps.run", { code: `async () => codemode.ai.run({ model:${JSON.stringify(model)},task:"classify",input:${JSON.stringify(input)} })` });
  const sent = await laptopDaemon.next() as Sent;
  assert.deepEqual(sent.params.request, { op: "run", model, task: "classify", input });
  const answer = { model, task: "classify", answers: { portrait: { type: "noul", noul: 0.97 } }, source: { ...gemmaSource, repo: "someone/new-decision-model" } };
  laptopDaemon.send({ jsonrpc: "2.0", id: sent.id, result: answer });
  assert.deepEqual(result(await running), { result: answer, logs: [] });
  const log = JSON.stringify(result(await call("axo.apps.log")));
  assert.doesNotMatch(log, /private photo|Is this a portrait|photo.png|bbbbbbbb/);
});

test("ai routes native MLX explicitly, validates the returned backend and logs no prompt/output", async (t) => {
  const { laptopDaemon, call } = await fixture(t);
  const model = "hf:any-owner/a-new-model";
  const sha256 = "a".repeat(64);
  const source = { backend: "mlx", repo: "any-owner/a-new-model", revision: "b".repeat(40), file: "model.safetensors", sha256,
    files: [{ path: "model.safetensors", bytes: 1024, sha256, role: "model" }] };
  for (const backend of ["mlx", "llama.cpp"]) {
    const running = call("axo.apps.run", { code: `async () => codemode.ai.run({model:${JSON.stringify(model)},backend:"mlx",input:"private native input"})` });
    const sent = await laptopDaemon.next() as Sent;
    assert.deepEqual(sent.params.request, { op: "run", model, backend: "mlx", task: "generate", input: "private native input", maxTokens: 512 });
    laptopDaemon.send({ jsonrpc: "2.0", id: sent.id, result: { model, task: "generate", text: "private native output", finishReason: "stop", source: { ...source, backend } } });
    const response = await running;
    if (backend === "mlx") assert.ok("result" in response);
    else assert.match(error(response).message, /invalid AI result/);
  }
  const log = JSON.stringify(result(await call("axo.apps.log")));
  assert.match(log, /"backend":"mlx"/);
  assert.doesNotMatch(log, /private native input|private native output/);
});

test("a native backend request to an old host gives an API 3 update instruction", async (t) => {
  const { laptopDaemon, call } = await fixture(t);
  const running = call("axo.apps.run", { code: `async () => codemode.ai.info({model:"hf:any-owner/a-new-model",backend:"mlx"})` });
  const sent = await laptopDaemon.next() as Sent;
  laptopDaemon.send({ jsonrpc: "2.0", id: sent.id, error: { code: -32602, message: "unknown ai request field" } });
  assert.match(error(await running).message, /update Axo.*version 3/);
});

test("ai.info explains an MLX candidate instead of rejecting its model name", async (t) => {
  const { laptopDaemon, call } = await fixture(t);
  const model = "hf:mlx-community/clef-omni-4bit";
  const running = call("axo.apps.run", { code: `async () => codemode.ai.info({model:${JSON.stringify(model)}})` });
  const sent = await laptopDaemon.next() as Sent;
  assert.deepEqual(sent.params.request, { op: "info", model });
  const answer = { info: { model, compatibility: { status: "unsupported", reasons: ["Requires an MLX backend and reviewed decision-head adapter"] }, formats: ["mlx", "safetensors"], architecture: "qwen3_omni_moe", taskHints: ["classify"], candidates: [], resolved: null }, installed: false };
  laptopDaemon.send({ jsonrpc: "2.0", id: sent.id, result: answer });
  assert.deepEqual(result(await running), { result: answer, logs: [] });
});

test("an ai call is not retried when its Mac disconnects", async (t) => {
  const { h, session, studio, call } = await fixture(t);
  const daemon = await connectHost(h, session, studio);
  const running = call("axo.apps.run", { code: `async () => codemode.ai.load({host:"studio",model:${JSON.stringify(AI_MODEL)}})` });
  await daemon.next();
  daemon.close();
  assert.match(error(await running).message, /may have run/);
  const log = appsResults["axo.apps.log"].parse(result(await call("axo.apps.log")));
  assert.deepEqual(log.records.map(r => r.outcome), ["unknown"]);
});

test("a script has no network of its own, and names only its own account's apps", async (t) => {
  const { call } = await fixture(t);
  const fetched = error(await call("axo.apps.run", { code: `async () => (await fetch("https://example.com")).status` }));
  assert.equal(fetched.code, APPS_ERRORS.scriptFailed);
  const unknown = error(await call("axo.apps.run", { code: `async () => codemode.workbench.list_issues({})` }));
  assert.match(unknown.message, /no app named workbench/);
  const notAFunction = error(await call("axo.apps.run", { code: `42` }));
  assert.match(notAFunction.message, /must be a function/);
});

test("another account's Mac is not a connection, and its daemon never hears the command", async (t) => {
  const { h, call } = await fixture(t);
  const other = await signIn(h, "someone-else");
  const theirs = await pairHost(h, other, "Workbench");
  const theirDaemon = await connectHost(h, other, theirs);
  t.after(() => theirDaemon.close());
  const failed = error(await call("axo.apps.run", { code: `async () => codemode.bash.run({ host: "workbench", command: "true" })` }));
  assert.match(failed.message, /no Mac named workbench/);
  const heard = await Promise.race([theirDaemon.next().then(() => true), new Promise((r) => setTimeout(() => r(false), 300))]);
  assert.equal(heard, false);
});

test("bad params, unknown methods and unknown apps are refused", async (t) => {
  const { call } = await fixture(t);
  assert.equal(error(await call("axo.apps.run", { code: "" })).code, -32602);
  assert.equal(error(await call("axo.apps.add", { name: "linear", url: "http://mcp.linear.app/mcp" })).code, -32602);
  assert.equal(error(await call("axo.apps.remove", { name: "linear" })).code, APPS_ERRORS.notFound);
});

test("a script error longer than a reply may carry reaches the Session cut short, not as a lost reply", async (t) => {
  const { call } = await fixture(t);
  const failed = error(await call("axo.apps.run", { code: `async () => { throw new Error("x".repeat(2000)); }` }));
  assert.equal(failed.code, APPS_ERRORS.scriptFailed);
  assert.equal(failed.message.length, 256);
  assert.match(failed.message, /^Error: x+$/);
});

test("1Password runs op on the Mac a call names, through that Mac's socket, logged once as the app's call", async (t) => {
  const { h, session, studio, laptop, sessionId, call } = await fixture(t);
  const studioDaemon = await connectHost(h, session, studio);
  t.after(() => studioDaemon.close());
  const listed = appsResults["axo.apps.list"].parse(result(await call("axo.apps.list")));
  const onepassword = listed.apps.find((c) => c.name === "apps.onepassword");
  assert.ok(onepassword?.kind === "app");
  assert.deepEqual(onepassword.accounts.map((a) => a.account), ["leo_s_laptop", "studio"]);

  const running = call("axo.apps.run", { code: `async () => codemode.apps.onepassword.list_vaults({ account: "studio" })` });
  const sent = (await studioDaemon.next()) as Sent;
  assert.equal(sent.method, BASH_METHOD);
  assert.equal(sent.params.command, `'op' 'vault' 'list' '--format' 'json'`);
  studioDaemon.send({
    jsonrpc: "2.0",
    id: sent.id,
    result: { exitCode: 0, signal: null, stdout: `[{"id":"v1","name":"Private"}]`, stderr: "", stdoutTruncated: false, stderrTruncated: false, timedOut: false, durationMs: 40 },
  });
  assert.deepEqual(result(await running), { result: [{ id: "v1", name: "Private" }], logs: [] });
  const log = appsResults["axo.apps.log"].parse(result(await call("axo.apps.log")));
  assert.deepEqual(log.records.map((r) => [r.service, r.tool, r.outcome, r.sessionId, r.hostId]), [["apps.onepassword", "list_vaults", "ok", sessionId, laptop.hostId]]);
});
