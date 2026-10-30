import assert from "node:assert/strict";
import test from "node:test";
import { RemoteAxoApi } from "../dist/index.js";

const hostId = "236dcf13-f476-48c4-a1a0-70b3755b8096";
const hostGeneration = "ccde1302-6fde-4813-a339-1c1d233c3b53";
const subscriptionId = "674f50dc-e716-4e04-8eb7-b3c6b86a35c0";
const reference = { hostId, hostGeneration };
const timestamp = "2026-10-16T12:00:00.000Z";

const sid = (n) => `${n.toString(16).padStart(8, "0")}-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;

function snapshot(sessionId = sid(1), shellId = 2) {
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
        result: { protocolVersion: 2, methods: [], deliveryCredits: { frames: 32, bytes: 131072 } },
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
        result: { session: snapshot(sid(3), 4) },
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
    if (new URL(input).pathname === "/api/v1/account/hosts") {
      return Response.json({ hosts: [host()] });
    }
    return Response.json({ host: host(), sessions: [snapshot()] });
  });

  const hosts = await api.listHosts();
  const sessions = await api.listHostSessions(reference);
  assert.equal(hosts[0].hostId, hostId);
  assert.equal(sessions[0].sessionId, sid(1));
  assert.equal(requests[0].init.credentials, "include");
  assert.equal(requests[0].init.cache, "no-store");
  assert.equal(requests[0].init.method, "GET");
  assert.equal(requests[1].url.pathname, `/api/v1/account/hosts/${hostId}/sessions`);
  assert.equal(requests[1].url.searchParams.get("hostGeneration"), hostGeneration);
});

test("Pi event history uses the account-private cursor API and validates each event", async () => {
  const streamId = "fca4eff5-13aa-4b1b-a4d0-e2b17a860fdd";
  const requests = [];
  const api = new RemoteAxoApi("https://api.example.test", async (input, init) => {
    requests.push({ url: new URL(input), init });
    return Response.json({
      events: [{
        id: 4,
        hostGeneration,
        piSessionId: "pi-session-1",
        streamId,
        sequence: 2,
        name: "message.end",
        data: { message: { role: "assistant", content: [{ type: "text", text: "Hello" }] } },
        receivedAt: 1_797_600_000_000,
      }],
      next: null,
    });
  });

  const page = await api.listPiEvents(reference, sid(9), 0, 50);
  assert.equal(page.events[0].name, "message.end");
  assert.equal(requests[0].url.pathname, `/api/v1/account/hosts/${hostId}/sessions/${sid(9)}/events`);
  assert.equal(requests[0].url.searchParams.get("before"), "0");
  assert.equal(requests[0].url.searchParams.get("limit"), "50");
  assert.equal(requests[0].init.credentials, "include");
  assert.equal(requests[0].init.cache, "no-store");
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
  assert.equal(socket.url, `wss://api.example.test/api/v1/account/hosts/${hostId}/client`);
  assert.deepEqual(socket.sent
    .filter((request) => request.method !== "axo.transport.ack")
    .map((request) => request.method)
    .slice(0, 2), [
    "axo.protocol.negotiate",
    "axo.host.subscribe",
  ]);
  assert.equal(receivedEvents[0].type, "host.presence");

  const result = await connection.call("axo.remote.session.create", { target: reference });
  assert.equal(result.session.sessionId, sid(3));
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
