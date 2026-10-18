import assert from "node:assert/strict";
import { mkdtemp, stat } from "node:fs/promises";
import { once } from "node:events";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { connect, type Socket } from "node:net";
import test from "node:test";
import { AxoPiBridgeServer } from "../src/bridge-server.js";
import type { PiBridgeRecord, PiSessionIdentity } from "../src/protocol.js";

const bridgeToken = "11cfda23-bc7c-4812-9613-4336f44b498e";

const identity: PiSessionIdentity = {
  axoSessionId: "82cfd1e8-1cc6-4473-a16d-6f0e77476311",
  axoPaneId: "9b9e14e0-d1c6-46b8-b289-bab4fda8774f",
  piSessionId: "pi-session-1",
  sessionFile: "/tmp/axo/sessions/pi-session-1.jsonl",
  cwd: "/projects/axo",
  processId: 1234,
};

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

async function connectTo(socketPath: string): Promise<{ socket: Socket; next: () => Promise<PiBridgeRecord> }> {
  const socket = connect({ path: socketPath });
  const next = recordReader(socket);
  await once(socket, "connect");
  return { socket, next };
}

test("exchanges events and scoped commands, and deduplicates command IDs", async () => {
  const directory = await mkdtemp(join(tmpdir(), "axo-pi-bridge-"));
  const socketPath = join(directory, "bridge.sock");
  const handled: string[] = [];
  const server = new AxoPiBridgeServer(socketPath, identity.axoSessionId, bridgeToken, async command => {
    handled.push(command.requestId);
    return { accepted: true };
  });

  try {
    await server.start();
    server.bindIdentity(identity);
    const { socket, next } = await connectTo(socketPath);
    socket.write(`${JSON.stringify({ type: "authenticate", protocolVersion: 1, token: bridgeToken })}\n`);
    assert.deepEqual(await next(), { type: "authenticated", protocolVersion: 1 });
    assert.deepEqual(await next(), { type: "hello", protocolVersion: 1, identity });

    server.publish("message.end", { role: "assistant", text: "Done" });
    const firstEvent = await next();
    assert.equal(firstEvent.type, "event");
    if (firstEvent.type !== "event") throw new Error("expected a Pi event");
    assert.match(firstEvent.streamId, /^[0-9a-f-]{36}$/iu);
    assert.deepEqual(firstEvent, {
      type: "event",
      streamId: firstEvent.streamId,
      sequence: 1,
      name: "message.end",
      data: { role: "assistant", text: "Done" },
    });

    const command = {
      type: "command",
      requestId: "request-1",
      axoSessionId: identity.axoSessionId,
      action: { kind: "send", text: "Run the tests" },
    };
    socket.write(`${JSON.stringify(command)}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "request-1", result: { accepted: true } });

    socket.write(`${JSON.stringify(command)}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "request-1", result: { accepted: true } });
    socket.write(`${JSON.stringify({ ...command, action: { kind: "cancel" } })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "request-1", result: { accepted: false, reason: "invalid" } });
    assert.deepEqual(handled, ["request-1"]);

    socket.write(`${JSON.stringify({ ...command, requestId: "request-2", axoSessionId: "e1cd03bd-5fcc-4b5a-a1fa-47653e5fa822" })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "request-2", result: { accepted: false, reason: "stale" } });
    assert.deepEqual(handled, ["request-1"]);

    socket.destroy();
  } finally {
    await server.close();
  }
});

test("does not unlink a socket path owned by another Pi process", async () => {
  const directory = await mkdtemp(join(tmpdir(), "axo-pi-bridge-owner-"));
  const socketPath = join(directory, "bridge.sock");
  const owner = new AxoPiBridgeServer(socketPath, identity.axoSessionId, bridgeToken, async () => ({ accepted: true }));
  const contender = new AxoPiBridgeServer(socketPath, identity.axoSessionId, bridgeToken, async () => ({ accepted: true }));

  try {
    await owner.start();
    await assert.rejects(contender.start());
    await contender.close();
    assert.equal((await stat(socketPath)).isSocket(), true);
  } finally {
    await contender.close();
    await owner.close();
  }
});
