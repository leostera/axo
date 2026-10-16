import assert from "node:assert/strict";
import test from "node:test";
import { RemoteAxoApi } from "../dist/index.js";

const hostId = "236dcf13-f476-48c4-a1a0-70b3755b8096";
const hostGeneration = "ccde1302-6fde-4813-a339-1c1d233c3b53";
const subscriptionId = "674f50dc-e716-4e04-8eb7-b3c6b86a35c0";
const reference = { hostId, hostGeneration };
const timestamp = "2026-10-16T12:00:00.000Z";

function snapshot(sessionId = 1, shellId = 2) {
  return {
    hostId,
    sessionId,
    shells: [{ shellId }],
    layout: { kind: "pane", shellId },
    updatedAt: timestamp,
  };
}

function host() {
  return {
    hostId,
    hostGeneration,
    label: "Test Mac",
    hostKind: "macos",
    status: "online",
    stale: false,
    lastSeenAt: timestamp,
    sessions: [snapshot()],
  };
}

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
    if (request.method === "axo.transport.ack") return;
    if (request.method === "axo.protocol.negotiate") {
      queueMicrotask(() => this.emit({
        jsonrpc: "2.0",
        id: request.id,
        result: { protocolVersion: 1, methods: [], deliveryCredits: { frames: 32, bytes: 131072 } },
      }));
    } else if (request.method === "axo.host.subscribe") {
      queueMicrotask(() => {
        this.emit({ jsonrpc: "2.0", id: request.id, result: { subscriptionId } });
        this.emit({
          jsonrpc: "2.0",
          method: "axo.host.event",
          params: {
            subscriptionId,
            event: {
              type: "host.presence",
              hostId,
              hostGeneration,
              status: "online",
              observedAt: timestamp,
            },
          },
        });
      });
    } else if (request.method === "axo.remote.session.create") {
      queueMicrotask(() => this.emit({
        jsonrpc: "2.0",
        id: request.id,
        result: { session: snapshot(3, 4) },
      }));
    } else {
      queueMicrotask(() => this.emit({
        jsonrpc: "2.0",
        id: request.id,
        error: { code: -32601, message: "Unknown method" },
      }));
    }
  }
  emit(value) {
    this.onmessage?.({ data: JSON.stringify(value) });
  }
  close(code = 1000, reason = "closed") {
    this.readyState = 3;
    this.onclose?.({ code, reason });
  }
}

test("HTTP metadata calls include browser Access credentials and validate the API shapes", async () => {
  const requests = [];
  const api = new RemoteAxoApi("https://api.example.test/", async (input, init) => {
    requests.push({ url: new URL(input), init });
    if (new URL(input).pathname === "/v1/hosts") {
      return Response.json({ hosts: [host()] });
    }
    return Response.json({ host: host(), sessions: [snapshot()] });
  });

  const hosts = await api.listHosts();
  const sessions = await api.listHostSessions(reference);
  assert.equal(hosts[0].hostId, hostId);
  assert.equal(sessions[0].sessionId, 1);
  assert.equal(requests[0].init.credentials, "include");
  assert.equal(requests[0].init.cache, "no-store");
  assert.equal(requests[0].init.method, "GET");
  assert.equal(requests[1].url.pathname, `/v1/hosts/${hostId}/sessions`);
  assert.equal(requests[1].url.searchParams.get("hostGeneration"), hostGeneration);
});

test("WebSocket negotiates, subscribes, dispatches live events, and calls session controls", async () => {
  let socket;
  const receivedEvents = [];
  const closeErrors = [];
  const api = new RemoteAxoApi(
    "https://api.example.test",
    fetch,
    (url) => {
      socket = new FakeWebSocket(url);
      return socket;
    },
  );

  const connection = await api.connectHost(
    reference,
    (event) => receivedEvents.push(event),
    (error) => closeErrors.push(error),
  );
  assert.equal(socket.url, `wss://api.example.test/v1/hosts/${hostId}/client`);
  assert.deepEqual(socket.sent
    .filter((request) => request.method !== "axo.transport.ack")
    .map((request) => request.method)
    .slice(0, 2), [
    "axo.protocol.negotiate",
    "axo.host.subscribe",
  ]);
  assert.equal(receivedEvents[0].type, "host.presence");

  const result = await connection.call("axo.remote.session.create", { target: reference });
  assert.equal(result.session.sessionId, 3);
  assert.equal(socket.sent
    .filter((request) => request.method !== "axo.transport.ack")
    .map((request) => request.method)
    .at(-1), "axo.remote.session.create");
  assert.ok(socket.sent.filter((request) => request.method === "axo.transport.ack").length >= 4);
  await connection.unsubscribe();
  socket.close(1006, "Relay disconnected");
  assert.equal(connection.active, false);
  assert.match(closeErrors[0].message, /Relay disconnected/);
  connection.close();
});
