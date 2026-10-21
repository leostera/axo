import assert from "node:assert/strict";
import { mkdtemp, lstat } from "node:fs/promises";
import { once } from "node:events";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { connect, type Socket } from "node:net";
import test from "node:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { installAxoPiExtension } from "../src/extension.js";
import type { PiBridgeRecord } from "../src/protocol.js";

const axoSessionId = "82cfd1e8-1cc6-4473-a16d-6f0e77476311";
const axoPaneId = "9b9e14e0-d1c6-46b8-b289-bab4fda8774f";
const bridgeToken = "11cfda23-bc7c-4812-9613-4336f44b498e";

function recordReader(socket: Socket): () => Promise<PiBridgeRecord> {
  let buffer = Buffer.alloc(0);
  const records: PiBridgeRecord[] = [];
  const waiting: Array<(record: PiBridgeRecord) => void> = [];
  socket.on("data", data => {
    buffer = Buffer.concat([buffer, data]);
    let newline = buffer.indexOf(0x0a);
    while (newline >= 0) {
      const line = buffer.subarray(0, newline);
      buffer = buffer.subarray(newline + 1);
      const record = JSON.parse(line.toString("utf8")) as PiBridgeRecord;
      const next = waiting.shift();
      if (next) next(record);
      else records.push(record);
      newline = buffer.indexOf(0x0a);
    }
  });
  return () => {
    const record = records.shift();
    if (record) return Promise.resolve(record);
    return new Promise(resolve => waiting.push(resolve));
  };
}

test("bridges Pi events and remote commands without owning the Pi process", async () => {
  const directory = await mkdtemp(join(tmpdir(), "axo-pi-extension-"));
  const socketPath = join(directory, "bridge.sock");
  const registered = new Map<string, (event: never, context: never) => unknown>();
  const sentMessages: Array<{ text: string; options?: unknown }> = [];
  let aborted = 0;
  let shutdowns = 0;
  let idle = true;

  const pi = {
    on(name: string, handler: (event: never, context: never) => unknown) {
      const previous = registered.get(name);
      registered.set(name, previous === undefined
        ? handler
        : async (event, context) => {
          await previous(event, context);
          return handler(event, context);
        });
      return () => registered.delete(name);
    },
    registerTool() {},
    sendUserMessage(text: string, options?: unknown) {
      sentMessages.push({ text, options });
    },
  } as unknown as ExtensionAPI;
  const context = {
    cwd: "/projects/axo",
    hasUI: false,
    isIdle: () => idle,
    abort: () => { aborted += 1; },
    shutdown: () => { shutdowns += 1; },
    sessionManager: {
      getSessionId: () => "pi-session-1",
      getSessionFile: () => "/private/axo/pi-session-1.jsonl",
      getSessionName: () => undefined,
      getBranch: () => [],
    },
  } as unknown as ExtensionContext;

  await installAxoPiExtension(pi, {
    socketPath,
    piSessionFile: "/private/axo/pi-session-1.jsonl",
    axoSessionId,
    axoPaneId,
    bridgeToken,
  });
  try {
    const start = registered.get("session_start");
    assert.ok(start);
    await start({ reason: "startup" } as never, context as never);

    const socket = connect({ path: socketPath });
    const next = recordReader(socket);
    await once(socket, "connect");
    socket.write(`${JSON.stringify({ type: "authenticate", protocolVersion: 1, token: bridgeToken })}\n`);
    assert.deepEqual(await next(), { type: "authenticated", protocolVersion: 1 });
    const hello = await next();
    assert.equal(hello.type, "hello");
    if (hello.type !== "hello") throw new Error("expected Pi bridge identity");
    assert.equal(hello.identity.axoSessionId, axoSessionId);
    assert.equal(hello.identity.axoPaneId, axoPaneId);
    assert.equal(hello.identity.piSessionId, "pi-session-1");
    assert.equal(hello.identity.sessionFile, "/private/axo/pi-session-1.jsonl");

    const messageEnd = registered.get("message_end");
    assert.ok(messageEnd);
    messageEnd({ type: "message_end", message: { role: "assistant", content: "hello" } } as never, context as never);
    const event = await next();
    assert.equal(event.type, "event");
    if (event.type !== "event") throw new Error("expected a Pi event");
    assert.equal(event.name, "message.end");
    assert.deepEqual(event.data, { type: "message_end", message: { role: "assistant", content: "hello" } });

    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "ask-1",
      axoSessionId,
      action: { kind: "send", text: "Check the build" },
    })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "ask-1", result: { accepted: true } });
    assert.deepEqual(sentMessages, [{ text: "Check the build", options: undefined }]);

    idle = false;
    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "steer-1",
      axoSessionId,
      action: { kind: "send", text: "Take this alternate path", delivery: "steer" },
    })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "steer-1", result: { accepted: true } });
    assert.deepEqual(sentMessages[1], { text: "Take this alternate path", options: { deliverAs: "steer" } });

    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "ask-2",
      axoSessionId,
      action: { kind: "send", text: "Interrupt with new direction" },
    })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "ask-2", result: { accepted: false, reason: "busy" } });

    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "cancel-1",
      axoSessionId,
      action: { kind: "cancel" },
    })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "cancel-1", result: { accepted: true } });
    assert.equal(aborted, 1);

    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "automatic-takeover-busy",
      axoSessionId,
      action: { kind: "shutdownIfIdle" },
    })}\n`);
    assert.deepEqual(await next(), {
      type: "commandResult",
      requestId: "automatic-takeover-busy",
      result: { accepted: false, reason: "busy" },
    });
    assert.equal(aborted, 1);
    assert.equal(shutdowns, 0);

    idle = true;
    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "automatic-takeover-idle",
      axoSessionId,
      action: { kind: "shutdownIfIdle" },
    })}\n`);
    assert.deepEqual(await next(), {
      type: "commandResult",
      requestId: "automatic-takeover-idle",
      result: { accepted: true },
    });
    await new Promise<void>(resolve => setImmediate(resolve));
    assert.equal(aborted, 1);
    assert.equal(shutdowns, 1);

    idle = false;
    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "takeover-1",
      axoSessionId,
      action: { kind: "shutdown" },
    })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "takeover-1", result: { accepted: true } });
    await new Promise<void>(resolve => setImmediate(resolve));
    assert.equal(aborted, 2);
    assert.equal(shutdowns, 2);

    const beforeSwitch = registered.get("session_before_switch");
    assert.ok(beforeSwitch);
    assert.deepEqual(
      await beforeSwitch(
        { reason: "resume", targetSessionFile: "/private/axo/archived-session.jsonl" } as never,
        context as never,
      ),
      { cancel: true },
    );
    const resumeRequest = await next();
    assert.equal(resumeRequest.type, "event");
    if (resumeRequest.type !== "event") throw new Error("expected a resume request");
    assert.equal(resumeRequest.name, "session.resume.requested");
    assert.deepEqual(resumeRequest.data, {
      targetSessionFile: "/private/axo/archived-session.jsonl",
    });
    assert.deepEqual(await beforeSwitch({ reason: "new" } as never, context as never), { cancel: true });
    socket.destroy();

    const shutdown = registered.get("session_shutdown");
    assert.ok(shutdown);
    await shutdown({ reason: "quit" } as never, context as never);
    await assert.rejects(lstat(socketPath), { code: "ENOENT" });
  } finally {
    const shutdown = registered.get("session_shutdown");
    if (shutdown) await shutdown({ reason: "quit" } as never, context as never);
  }
});
