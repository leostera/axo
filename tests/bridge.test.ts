import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer as httpsServer } from "node:https";
import { createServer as httpServer } from "node:http";
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn, execFileSync } from "node:child_process";
import { once } from "node:events";
import { WebSocketServer, type WebSocket } from "ws";
import type { AddressInfo } from "node:net";
import { hostFrameSchema, type HostFrame } from "../shared/protocol";
import { promptDelivery } from "../bridge/delivery";
import { createHash } from "node:crypto";

test("phone prompts interrupt active work instead of becoming follow-ups", () => {
  assert.equal(promptDelivery(true), undefined);
  assert.deepEqual(promptDelivery(false), { deliverAs: "steer" });
});

// Exercises the actual interactive Pi runtime, not RPC or a mocked ExtensionAPI.
test("real Pi TUI accepts a phone prompt and shares a question/result", { timeout: 30_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "axo-bridge-"));
  const keyPath = join(directory, "key.pem");
  const certPath = join(directory, "cert.pem");
  execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", keyPath, "-out", certPath, "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"], { stdio: "ignore" });
  const relay = httpsServer({ key: await readFile(keyPath), cert: await readFile(certPath) });
  const sockets = new WebSocketServer({ server: relay });
  const frames: HostFrame[] = [];
  let host: WebSocket | undefined;
  let metadataDelay = 0;
  const imageId = "00000000-0000-4000-8000-000000000001";
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGQsAAAAASUVORK5CYII=", "base64");
  relay.on("request", (request, response) => {
    assert.equal(request.headers["cf-access-client-id"], "test-id");
    assert.equal(request.headers["cf-access-client-secret"], "test-secret");
    const sessionId = frames.find(frame => frame.type === "snapshot")?.sessionId;
    if (request.url === `/files/sessions/${sessionId}/files/${imageId}`) {
      response.setHeader("Content-Type", "application/json");
      setTimeout(() => response.end(JSON.stringify({ id: imageId, sessionId, filename: "screenshot.png", mediaType: "image/png", byteLength: png.length,
        sha256: createHash("sha256").update(png).digest("hex"), origin: "phone", createdAt: 0, state: "ready" })), metadataDelay);
    } else if (request.url === `/files/sessions/${sessionId}/files/${imageId}/content`) { response.end(png); }
    else { response.writeHead(404); response.end(); }
  });
  sockets.on("connection", (socket, request) => {
    assert.equal(request.headers["cf-access-client-id"], "test-id");
    host = socket;
    socket.on("message", raw => frames.push(hostFrameSchema.parse(JSON.parse(raw.toString()))));
  });
  relay.listen(0, "localhost");
  await once(relay, "listening");
  let modelRequests = 0;
  let receivedImage = false;
  let receivedImageOnly = false;
  const model = httpServer(async (request, response) => {
    let body = "";
    for await (const part of request) body += part;
    const payload = JSON.parse(body);
    modelRequests++;
    if (JSON.stringify(payload.messages).includes(`data:image/png;base64,${png.toString("base64")}`)) receivedImage = true;
    const hasAnswer = payload.messages.some((message: { role: string }) => message.role === "tool");
    const lastUser = [...payload.messages].reverse().find((message: { role: string }) => message.role === "user");
    const lastUserText = typeof lastUser?.content === "string" ? lastUser.content : JSON.stringify(lastUser?.content ?? "");
    if (lastUserText.includes(`data:image/png;base64,${png.toString("base64")}`) && Array.isArray(lastUser?.content)
      && !lastUser.content.some((block: { type: string }) => block.type === "text")) receivedImageOnly = true;
    const askingBeforeCancel = lastUserText.includes("Hold while I decide");
    const delta = hasAnswer && !askingBeforeCancel ? { content: "Phone answer received. Prototype loop works." } : {
      tool_calls: [{ index: 0, id: `tool-${modelRequests}`, type: "function", function: { name: "axo_ask", arguments: JSON.stringify({ title: "Choose output", options: ["JSON", "Markdown"] }) } }],
    };
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    for (const [value, finish] of [[{ role: "assistant" }, null], [delta, null], [{}, hasAnswer && !askingBeforeCancel ? "stop" : "tool_calls"]]) {
      response.write(`data: ${JSON.stringify({ id: "completion", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta: value, finish_reason: finish }] })}\n\n`);
      if (hasAnswer && !askingBeforeCancel && value === delta) await new Promise(resolve => setTimeout(resolve, lastUserText.includes("Start a longer response") ? 1500 : 150));
    }
    response.end("data: [DONE]\n\n");
  });
  model.listen(0, "127.0.0.1");
  await once(model, "listening");
  const configPath = join(directory, "relay.json");
  await writeFile(configPath, JSON.stringify({ relayURL: `https://localhost:${(relay.address() as AddressInfo).port}`, accessClientId: "test-id", accessClientSecret: "test-secret" }), { mode: 0o600 });
  const child = spawn("python3", [resolve("tests/fixtures/terminal_driver.py"), process.execPath,
    resolve("node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"),
    "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-approve",
    "--extension", resolve("tests/fixtures/provider.ts"), "--extension", resolve("bridge/extension.ts"),
    "--provider", "axo-test", "--model", "fixture", "--session", join(directory, "session.jsonl")], {
    cwd: directory, env: { ...process.env, HOME: directory, TERM: "xterm-256color", PI_CODING_AGENT_DIR: join(directory, "pi"),
      PI_OFFLINE: "1", PI_TELEMETRY: "0", PI_SKIP_VERSION_CHECK: "1", NODE_EXTRA_CA_CERTS: certPath,
      AXO_CONFIG: configPath, AXO_TEST_MODEL_URL: `http://127.0.0.1:${(model.address() as AddressInfo).port}/v1` },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const exited = once(child, "exit");
  let terminalOutput = "";
  child.stdout.on("data", chunk => { terminalOutput = (terminalOutput + chunk.toString()).slice(-20_000); });
  child.stderr.on("data", chunk => { terminalOutput += chunk.toString(); });
  async function waitFor(predicate: (frame: HostFrame) => boolean): Promise<HostFrame> {
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
      const frame = frames.find(predicate);
      if (frame) return frame;
      if (child.exitCode !== null) break;
      await new Promise(resolve => setTimeout(resolve, 30));
    }
    throw new Error(`Pi bridge timed out. TUI output:\n${terminalOutput}`);
  }
  try {
    const initial = await waitFor(frame => frame.type === "snapshot");
    assert.equal(initial.type, "snapshot");
    if (initial.type !== "snapshot") throw new Error("Expected snapshot");
    const prompt = { type: "prompt", id: "phone-prompt", sessionId: initial.sessionId, text: "Ask which output format I want." };
    host!.send(JSON.stringify(prompt));
    await waitFor(frame => frame.type === "ack" && frame.id === prompt.id);
    const waiting = await waitFor(frame => frame.type === "snapshot" && frame.question !== null);
    if (waiting.type !== "snapshot" || !waiting.question) throw new Error("Expected question");
    assert.ok(waiting.activities?.some(activity => activity.toolName === "axo_ask" && activity.status === "running"));
    assert.ok(waiting.messages.some(message => message.role === "tool" && message.toolName === "axo_ask" && message.status === "running"));
    const userMessage = waiting.messages.find(message => message.role === "user" && message.text.includes(prompt.text));
    const toolStarted = waiting.events?.find(event => event.name === "tool_execution_start");
    assert.ok(toolStarted);
    assert.equal(toolStarted.anchorMessageId, userMessage?.id);
    host!.send(JSON.stringify({ type: "answer", id: "phone-answer", sessionId: initial.sessionId, questionId: waiting.question.id, value: "JSON" }));
    const liveTextFrame = await waitFor(frame => frame.type === "snapshot" && (frame.liveText?.includes("Phone answer received.") ?? false));
    assert.ok(liveTextFrame.type === "snapshot" && liveTextFrame.events?.some(event => event.name === "assistant.text_delta"));
    const completed = await waitFor(frame => frame.type === "snapshot" && frame.state === "idle" && frame.messages.some(message => message.text.includes("Prototype loop works")));
    assert.equal(completed.type, "snapshot");
    if (completed.type === "snapshot") {
      assert.ok(completed.activities?.some(activity => activity.toolName === "axo_ask" && activity.status === "completed"));
      assert.ok(completed.messages.some(message => message.role === "tool" && message.toolName === "axo_ask" && message.status === "completed"));
      const beforeSync = frames.length;
      host!.send(JSON.stringify({ type: "sync" }));
      const deadline = Date.now() + 3_000;
      while (frames.length === beforeSync && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 30));
      const restored = frames.slice(beforeSync).find(frame => frame.type === "snapshot");
      assert.ok(restored?.type === "snapshot" && restored.messages.some(message => message.role === "tool" && message.status === "completed"));
      const tool = completed.messages.find(message => message.role === "tool")!;
      host!.send(JSON.stringify({ type: "tool_output", id: "expand-tool", sessionId: initial.sessionId, toolCallId: tool.toolCallId, offset: 0 }));
      const output = await waitFor(frame => frame.type === "tool_output" && frame.id === "expand-tool");
      assert.ok(output.type === "tool_output" && output.text.includes("JSON") && output.nextOffset === null);
      host!.send(JSON.stringify({ type: "history", id: "earlier", sessionId: initial.sessionId, viewId: initial.viewId, beforeId: completed.messages.at(-1)!.id }));
      const history = await waitFor(frame => frame.type === "history" && frame.id === "earlier");
      assert.ok(history.type === "history" && history.messages.some(message => message.role === "tool"));
    }
    const cancelPrompt = { type: "prompt", id: "cancel-test-prompt", sessionId: initial.sessionId, text: "Hold while I decide." };
    host!.send(JSON.stringify(cancelPrompt));
    await waitFor(frame => frame.type === "ack" && frame.id === cancelPrompt.id);
    const cancelQuestion = await waitFor(frame => frame.type === "snapshot" && frame.state === "waiting"
      && frame.question !== null && frame.question.id !== waiting.question!.id);
    if (cancelQuestion.type !== "snapshot" || !cancelQuestion.runId) throw new Error("Expected an active run id");
    host!.send(JSON.stringify({ type: "cancel", id: "cancel-run", sessionId: initial.sessionId, runId: cancelQuestion.runId }));
    await waitFor(frame => frame.type === "ack" && frame.id === "cancel-run" && frame.disposition === "cancelled");
    const cancelled = await waitFor(frame => frame.type === "snapshot" && frame.state === "idle" && frame.runId === null
      && frame.messages.some(message => message.role === "user" && message.text.includes("Hold while I decide")));
    assert.equal(cancelled.type, "snapshot");
    host!.send(JSON.stringify(prompt));
    await waitFor(frame => frame.type === "error" && frame.id === prompt.id && frame.message.includes("Already submitted"));
    host!.send(JSON.stringify({ ...prompt, id: "stale", sessionId: "wrong-session" }));
    await waitFor(frame => frame.type === "error" && frame.id === "stale");
    const imagePrompt = { type: "prompt", id: "screenshot-prompt", sessionId: initial.sessionId, text: "Discuss this attached screenshot.", attachmentIds: [imageId] };
    host!.send(JSON.stringify(imagePrompt));
    await waitFor(frame => frame.type === "ack" && frame.id === imagePrompt.id);
    await waitFor(frame => frame.type === "snapshot" && frame.state === "running"
      && frame.messages.some(message => message.attachments?.[0]?.id === imageId));
    const attached = await waitFor(frame => frame.type === "snapshot" && frame.state === "idle"
      && frame.messages.some(message => message.text === imagePrompt.text && message.attachments?.[0]?.id === imageId));
    assert.ok(attached.type === "snapshot" && attached.messages.some(message => message.role === "user" && message.attachments?.[0]?.id === imageId));
    // The custom Pi message stores real image content and attachment details together.
    const deadline = Date.now() + 3_000;
    while (!receivedImage && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20));
    assert.equal(receivedImage, true);
    assert.equal(modelRequests, 4);
    host!.send(JSON.stringify({ type: "prompt", id: "long-response", sessionId: initial.sessionId, text: "Start a longer response while I attach an image." }));
    await waitFor(frame => frame.type === "snapshot" && frame.state === "running"
      && frame.messages.some(message => message.text === "Start a longer response while I attach an image."));
    // Make live event contexts change while HTTP preparation is suspended.
    metadataDelay = 250;
    host!.send(JSON.stringify({ type: "prompt", id: "image-only-steering", sessionId: initial.sessionId, text: "", attachmentIds: [imageId] }));
    await waitFor(frame => frame.type === "ack" && frame.id === "image-only-steering");
    await waitFor(frame => frame.type === "snapshot" && frame.state === "idle"
      && frame.messages.some(message => message.role === "user" && message.text === "" && message.attachments?.[0]?.id === imageId));
    assert.equal(receivedImageOnly, true);
    assert.equal(modelRequests, 6);
    const persisted = await readFile(join(directory, "session.jsonl"), "utf8");
    assert.ok(persisted.includes('"customType":"axo.attachments"'));
    assert.ok(persisted.includes(imageId));
  } finally {
    child.kill("SIGTERM");
    await exited;
    for (const socket of sockets.clients) socket.terminate();
    sockets.close();
    relay.close();
    model.close();
    await rm(directory, { recursive: true, force: true });
  }
});
