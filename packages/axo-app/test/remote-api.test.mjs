import assert from "node:assert/strict";
import test from "node:test";
import { splitMessage } from "@axo/protocol";
import { RemoteAxoApi } from "../src/index.ts";

const hostId = "236dcf13-f476-48c4-a1a0-70b3755b8096";
const hostGeneration = "ccde1302-6fde-4813-a339-1c1d233c3b53";
const reference = { hostId, hostGeneration };
const timestamp = "2026-10-16T12:00:00.000Z";
const clientId = "tab-client-0001";

const sid = (n) => `${n.toString(16).padStart(8, "0")}-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;

const clientHost = { hostId, hostGeneration, label: "Test Mac", hostKind: "macos", online: true, lastSeenAt: timestamp };
const metadata = { name: "Chat", emoji: null, workspaceId: null, workspaceName: null, hasAgent: true, createdAt: null, lastMessageAt: null, archived: false };

function record(cursor, line = JSON.stringify({ type: "message", id: `e${cursor}`, parentId: null, message: { role: "user", content: "hi" } })) {
  return { cursor, id: `e${cursor}`, format: "pi/3", line, hash: `sha256:${"0".repeat(64)}` };
}

/** The ClientDO's end of the account socket. */
class FakeWebSocket {
  readyState = 0;
  onopen = null;
  onmessage = null;
  onerror = null;
  onclose = null;
  sent = [];
  constructor(url) {
    this.url = url;
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.({});
    });
  }
  send(raw) {
    const request = JSON.parse(raw);
    this.sent.push(request);
    const reply = (result) => queueMicrotask(() => this.emit({ jsonrpc: "2.0", id: request.id, result }));
    switch (request.method) {
      case "axo.client.hello":
        return reply({ hosts: [clientHost], sessions: [{ hostId, sessionId: sid(1), metadata, epoch: 1, head: 2, status: "ready" }] });
      case "axo.client.session.open":
        return reply({ epoch: 1, records: [record(1), record(2)], cursor: 2, older: null, progress: [{ slot: "message", snapshot: { message: { role: "assistant", content: "Wo" } } }] });
      case "axo.client.command":
        if (request.params.method === "axo.remote.session.prompt") {
          return queueMicrotask(() => this.emit({ jsonrpc: "2.0", id: request.id, error: { code: -32005, message: "Host offline; nothing queued" } }));
        }
        if (request.params.method === "axo.remote.session.stop") {
          return queueMicrotask(() => this.emit({ jsonrpc: "2.0", id: request.id, result: { stopped: true } }));
        }
        return reply({ session: { hostId, sessionId: sid(3), shells: [], layout: null, updatedAt: timestamp } });
    }
  }
  emit(value) {
    this.onmessage?.({ data: typeof value === "string" ? value : JSON.stringify(value) });
  }
  close(code = 1000, reason = "closed") {
    this.readyState = 3;
    this.onclose?.({ code, reason });
  }
}

/** Protocol 2: the account socket carries everything (RFD0018). */
function connect(events = {}) {
  let socket;
  const api = new RemoteAxoApi("https://api.example.test/", (url) => {
    socket = new FakeWebSocket(url);
    return socket;
  }, { protocol: 2 });
  return api.connect(clientId, events).then((connection) => ({ connection, socket: () => socket }));
}

test("the account socket says hello as this client and lists every host and Session", async () => {
  const { connection, socket } = await connect();
  assert.equal(socket().url, `wss://api.example.test/api/v1/account/client?clientId=${clientId}`);
  assert.deepEqual(socket().sent[0].params, { protocolVersion: 2, clientId });
  assert.equal(connection.hello.hosts[0].label, "Test Mac");
  assert.equal(connection.hello.sessions[0].sessionId, sid(1));
  connection.close();
});

test("an open returns its window and progress; records that follow are acknowledged once handled", async () => {
  const received = [];
  const { connection, socket } = await connect({ records: (sessionId, epoch, records) => received.push({ sessionId, epoch, cursors: records.map((r) => r.cursor) }) });
  const opened = await connection.open({ hostId, sessionId: sid(1), window: { last: 20 } });
  assert.deepEqual(opened.records.map((r) => r.cursor), [1, 2]);
  assert.equal(opened.progress[0].slot, "message");
  socket().emit({ jsonrpc: "2.0", method: "axo.client.session.records", params: { sessionId: sid(1), epoch: 1, records: [record(3), record(4)], cursor: 4 } });
  assert.deepEqual(received, [{ sessionId: sid(1), epoch: 1, cursors: [3, 4] }]);
  assert.deepEqual(socket().sent.at(-1), { jsonrpc: "2.0", method: "axo.client.session.ack", params: { sessionId: sid(1), cursor: 4 } });
  connection.closeSession(sid(1));
  assert.equal(socket().sent.at(-1).method, "axo.client.session.close");
  connection.close();
});

test("a message larger than a frame arrives in fragments and is put back together", async () => {
  const received = [];
  const { connection, socket } = await connect({ records: (_sessionId, _epoch, records) => received.push(...records) });
  const big = JSON.stringify({ type: "message", id: "e1", parentId: null, message: { role: "assistant", content: "x".repeat(200_000) } });
  const frames = splitMessage(JSON.stringify({ jsonrpc: "2.0", method: "axo.client.session.records", params: { sessionId: sid(1), epoch: 1, records: [record(1, big)], cursor: 1 } }), "m".repeat(32));
  assert.ok(frames.length > 1);
  for (const frame of frames) socket().emit(frame);
  assert.equal(received[0].line, big);
  connection.close();
});

test("commands go to the named host, results are checked, and an offline host fails at once", async () => {
  const { connection, socket } = await connect();
  const created = await connection.command("axo.remote.session.create", { target: reference });
  assert.equal(created.session.sessionId, sid(3));
  assert.deepEqual(socket().sent.at(-1).params, { hostId, method: "axo.remote.session.create", params: { target: reference } });
  await assert.rejects(
    connection.command("axo.remote.session.prompt", { target: reference, sessionId: sid(1), text: "hi" }),
    (error) => error.code === -32005,
  );
  connection.close();
});

test("stopping a turn reads the host's answer, as every remote method's is", async () => {
  const { connection, socket } = await connect();
  const stopped = await connection.command("axo.remote.session.stop", { target: reference, sessionId: sid(1), turnId: "e1" });
  assert.deepEqual(stopped, { stopped: true });
  assert.equal(socket().sent.at(-1).params.method, "axo.remote.session.stop");
  connection.close();
});

test("host, Session, progress and reset notices reach the app, and a close says why", async () => {
  const seen = [];
  const { connection, socket } = await connect({
    hosts: (hosts) => seen.push(["hosts", hosts.length]),
    sessions: (host, sessions) => seen.push(["sessions", host, sessions.length]),
    progress: (sessionId, slot, snapshot) => seen.push(["progress", slot, snapshot]),
    reset: (sessionId, epoch, keep) => seen.push(["reset", epoch, keep]),
    closed: (error) => seen.push(["closed", error.message]),
  });
  socket().emit({ jsonrpc: "2.0", method: "axo.client.hosts", params: { hosts: [{ ...clientHost, online: false }] } });
  socket().emit({ jsonrpc: "2.0", method: "axo.client.sessions", params: { hostId, sessions: [{ hostId, sessionId: sid(1), metadata, epoch: 1, head: 3, status: "working" }] } });
  socket().emit({ jsonrpc: "2.0", method: "axo.client.session.progress", params: { sessionId: sid(1), slot: "question", snapshot: null } });
  socket().emit({ jsonrpc: "2.0", method: "axo.client.session.reset", params: { sessionId: sid(1), epoch: 2, keep: 1 } });
  socket().close(4000, "Replaced");
  assert.deepEqual(seen, [["hosts", 1], ["sessions", hostId, 1], ["progress", "question", null], ["reset", 2, 1], ["closed", "Replaced"]]);
  assert.equal(connection.active, false);
});

/**
 * Protocol 3 (RFD0032): the ClientDO's account socket lists hosts; each host's socket carries its
 * index, records and commands. `accountRefuses` plays a cloud that only speaks protocol 2.
 */
class FakeCloud {
  sockets = [];
  constructor({ accountRefuses = false, hostRefuses = false } = {}) {
    this.accountRefuses = accountRefuses;
    this.hostRefuses = hostRefuses;
  }
  make = (url) => {
    const socket = new FakeWebSocket(url);
    const host = /\/hosts\/([^/]+)\/client/.exec(url)?.[1];
    socket.send = (raw) => {
      const request = JSON.parse(raw);
      socket.sent.push(request);
      const reply = (result) => queueMicrotask(() => socket.emit({ jsonrpc: "2.0", id: request.id, result }));
      const refuse = (code, message) => queueMicrotask(() => socket.emit({ jsonrpc: "2.0", id: request.id, error: { code, message } }));
      if (request.method === "axo.client.hello" && !host) {
        if (request.params.protocolVersion === 3 && this.accountRefuses) return refuse(-32602, "Invalid params");
        if (request.params.protocolVersion === 2) return reply({ hosts: [clientHost], sessions: [{ hostId, sessionId: sid(1), metadata, epoch: 1, head: 2, status: "ready" }] });
        return reply({ hosts: [{ ...clientHost, online: false }], sessions: [] });
      }
      if (request.method === "axo.client.hello") {
        if (this.hostRefuses) return queueMicrotask(() => socket.close(4010, "Protocol not served"));
        reply({ online: true, hostGeneration, sessions: [{ hostId, sessionId: sid(1), metadata, epoch: 1, head: 2, status: "ready" }] });
        return queueMicrotask(() => socket.emit({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: { hostId, elicitation: { id: sid(9), sessionId: sid(1), kind: "confirm", askedBy: "computerUse", message: "Go?", createdAt: 1, expiresAt: 2 } } }));
      }
      if (request.method === "axo.client.session.open") return reply({ epoch: 1, records: [], cursor: 2, older: null, progress: [] });
    };
    this.sockets.push(socket);
    return socket;
  };
  account() {
    return this.sockets.find((socket) => socket.url.includes("/account/client"));
  }
  hostSockets() {
    return this.sockets.filter((socket) => socket.url.includes("/hosts/"));
  }
}

test("protocol 3 lists hosts from the account, Sessions and presence from each host's socket, and routes opens to it", async () => {
  const cloud = new FakeCloud();
  const asked = [];
  const connection = await new RemoteAxoApi("https://api.example.test/", cloud.make).connect(clientId, { elicitationRequested: (from, elicitation) => asked.push([from, elicitation.id]) });
  assert.deepEqual(cloud.account().sent[0].params, { protocolVersion: 3, clientId });
  const [host] = cloud.hostSockets();
  assert.equal(host.url, `wss://api.example.test/api/v1/account/hosts/${hostId}/client?clientId=${clientId}`);
  assert.equal(host.sent[0].params.protocolVersion, 3);
  assert.ok(host.sent[0].params.connection > 0);
  assert.equal(connection.hello.hosts[0].online, true, "presence comes from the host's socket");
  assert.equal(connection.hello.sessions[0].sessionId, sid(1));
  assert.deepEqual(asked, [[hostId, sid(9)]], "what the host asks follows the listing");

  await connection.open({ hostId, sessionId: sid(1), have: { epoch: 1, cursor: 2 } });
  assert.equal(host.sent.at(-1).method, "axo.client.session.open");
  host.emit({ jsonrpc: "2.0", method: "axo.client.session.records", params: { sessionId: sid(1), epoch: 1, records: [record(3)], cursor: 3 } });
  assert.deepEqual(host.sent.at(-1), { jsonrpc: "2.0", method: "axo.client.session.ack", params: { sessionId: sid(1), cursor: 3 } }, "acknowledged on the socket it came from");
  connection.closeSession(sid(1));
  assert.equal(host.sent.at(-1).method, "axo.client.session.close");
  connection.close();
});

test("protocol 3 merges a host's presence and name into the host list as they change, and a host socket that closes closes the connection", async () => {
  const cloud = new FakeCloud();
  const seen = [];
  const connection = await new RemoteAxoApi("https://api.example.test/", cloud.make).connect(clientId, {
    hosts: (hosts) => seen.push(["hosts", hosts[0].online, hosts[0].label]),
    closed: (error) => seen.push(["closed", error.message]),
  });
  const [host] = cloud.hostSockets();
  host.emit({ jsonrpc: "2.0", method: "axo.client.host.presence", params: { online: false, hostGeneration: null } });
  host.emit({ jsonrpc: "2.0", method: "axo.client.host.label", params: { label: "Studio" } });
  host.close(4000, "Replaced");
  assert.deepEqual(seen, [["hosts", false, "Test Mac"], ["hosts", false, "Studio"], ["closed", "Replaced"]]);
  assert.equal(connection.active, false);
});

test("protocol 3 refuses a command for a host it has no socket on as offline, and sends it nowhere", async () => {
  const cloud = new FakeCloud();
  const connection = await new RemoteAxoApi("https://api.example.test/", cloud.make).connect(clientId, {});
  const sent = () => cloud.sockets.reduce((count, socket) => count + socket.sent.length, 0);
  const before = sent();
  const stranger = { hostId: "0b0b0b0b-0000-4000-8000-00000000000b", hostGeneration };
  // -32602 would read as "this Mac is too old for these fields", and the app would try again without them.
  await assert.rejects(
    connection.command("axo.remote.session.prompt", { target: stranger, sessionId: sid(1), text: "hi" }),
    (error) => error.code === -32005,
  );
  assert.equal(sent(), before);
  connection.close();
});

test("protocol 3 falls back to protocol 2 when the account socket or a host socket refuses it", async () => {
  for (const refusal of [{ accountRefuses: true }, { hostRefuses: true }]) {
    const cloud = new FakeCloud(refusal);
    const connection = await new RemoteAxoApi("https://api.example.test/", cloud.make).connect(clientId, {});
    const accounts = cloud.sockets.filter((socket) => socket.url.includes("/account/client"));
    assert.equal(accounts.length, 2, JSON.stringify(refusal));
    assert.equal(accounts[1].sent[0].params.protocolVersion, 2);
    assert.equal(connection.hello.sessions[0].sessionId, sid(1), "protocol 2's hello lists the Sessions");
    connection.close();
  }
});
