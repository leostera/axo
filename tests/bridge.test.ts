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
  sockets.on("connection", (socket, request) => {
    assert.equal(request.headers["cf-access-client-id"], "test-id");
    host = socket;
    socket.on("message", raw => frames.push(hostFrameSchema.parse(JSON.parse(raw.toString()))));
  });
  relay.listen(0, "localhost");
  await once(relay, "listening");
  let modelRequests = 0;
  const model = httpServer(async (request, response) => {
    let body = "";
    for await (const part of request) body += part;
    const payload = JSON.parse(body);
    modelRequests++;
    const hasAnswer = payload.messages.some((message: { role: string }) => message.role === "tool");
    const delta = hasAnswer ? { content: "Phone answer received. Prototype loop works." } : {
      tool_calls: [{ index: 0, id: "tool-1", type: "function", function: { name: "axo_ask", arguments: JSON.stringify({ title: "Choose output", options: ["JSON", "Markdown"] }) } }],
    };
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    for (const [value, finish] of [[{ role: "assistant" }, null], [delta, null], [{}, hasAnswer ? "stop" : "tool_calls"]]) {
      response.write(`data: ${JSON.stringify({ id: "completion", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta: value, finish_reason: finish }] })}\n\n`);
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
    host!.send(JSON.stringify({ type: "answer", id: "phone-answer", sessionId: initial.sessionId, questionId: waiting.question.id, value: "JSON" }));
    const completed = await waitFor(frame => frame.type === "snapshot" && frame.state === "idle" && frame.messages.some(message => message.text.includes("Prototype loop works")));
    assert.equal(completed.type, "snapshot");
    host!.send(JSON.stringify(prompt));
    await waitFor(frame => frame.type === "error" && frame.id === prompt.id && frame.message.includes("Already submitted"));
    host!.send(JSON.stringify({ ...prompt, id: "stale", sessionId: "wrong-session" }));
    await waitFor(frame => frame.type === "error" && frame.id === "stale");
    assert.equal(modelRequests, 2);
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
