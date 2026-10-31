import assert from "node:assert/strict";
import { test } from "node:test";
import type { CallHostRequest, HostCommandOutcome } from "../src/host-do";
import { harness, signIn } from "./harness";
import { connectClient, connectHost, pairHost } from "./account-support";

/** The account's view of a HostDO: the RPC methods the account calls on it (RFD0016, Connections). */
type HostStub = { callHost(request: CallHostRequest): Promise<HostCommandOutcome>; disconnect(): Promise<void> };

async function fixture(t: { after(fn: () => unknown): void }) {
  const h = await harness();
  t.after(() => h.close());
  const session = await signIn(h);
  const host = await pairHost(h, session);
  const namespace = (await h.mf.getDurableObjectNamespace("TEST_HOST_DO")) as unknown as {
    idFromName(name: string): unknown;
    get(id: unknown): unknown;
  };
  const raw = namespace.get(namespace.idFromName(`${session.accountId}:${host.hostId}`)) as unknown as HostStub;
  // Miniflare hands RPC results back as proxies; the test compares plain values.
  const stub: HostStub = {
    callHost: async (request) => {
      const outcome = await raw.callHost(request);
      const plain = JSON.parse(JSON.stringify(outcome)) as HostCommandOutcome;
      (outcome as Partial<Disposable>)[Symbol.dispose]?.();
      return plain;
    },
    disconnect: async () => {
      const done = await raw.disconnect();
      (done as Partial<Disposable> | undefined)?.[Symbol.dispose]?.();
    },
  };
  return { h, session, host, stub };
}

type Sent = { id: string; method: string; params: unknown };

test("callHost sends once, returns the daemon's reply, and refuses an offline host", async (t) => {
  const { h, session, host, stub } = await fixture(t);
  assert.deepEqual(await stub.callHost({ method: "axo.connections.bash", params: {}, deadlineMs: 1_000 }), {
    error: { code: -32005, message: "Host offline; nothing sent" },
  });

  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  const params = { connectionId: "c1", sessionId: crypto.randomUUID(), command: "ls" };
  const pending = stub.callHost({ method: "axo.connections.bash", params, deadlineMs: 5_000 });
  const sent = (await daemon.next()) as Sent;
  assert.equal(sent.method, "axo.connections.bash");
  assert.deepEqual(sent.params, params);
  // A reply large enough to cross as fragments.
  const output = "x".repeat(300_000);
  daemon.send({ jsonrpc: "2.0", id: sent.id, result: { output } });
  assert.deepEqual(await pending, { result: { output } });

  const refused = stub.callHost({ method: "axo.connections.bash", params, deadlineMs: 5_000 });
  const second = (await daemon.next()) as Sent;
  daemon.send({ jsonrpc: "2.0", id: second.id, error: { code: -32003, message: "Not allowed" } });
  assert.deepEqual(await refused, { error: { code: -32003, message: "Not allowed" } });
});

test("callHost fails as may-have-run when the deadline passes or the socket goes, and ignores a later socket's reply", async (t) => {
  const { h, session, host, stub } = await fixture(t);
  const daemon = await connectHost(h, session, host);
  const late = stub.callHost({ method: "axo.connections.bash", params: {}, deadlineMs: 200 });
  await daemon.next();
  assert.deepEqual(await late, { error: { code: -32004, message: "No answer in time; the call may have run" } });

  const dropped = stub.callHost({ method: "axo.connections.bash", params: {}, deadlineMs: 10_000 });
  const sent = (await daemon.next()) as Sent;
  daemon.close();
  assert.deepEqual(await dropped, { error: { code: -32004, message: "Host disconnected; the call may have run" } });

  const again = await connectHost(h, session, host);
  t.after(() => again.close());
  again.send({ jsonrpc: "2.0", id: sent.id, result: { stale: true } });
  const fresh = stub.callHost({ method: "axo.connections.bash", params: {}, deadlineMs: 5_000 });
  const next = (await again.next()) as Sent;
  again.send({ jsonrpc: "2.0", id: next.id, result: { fresh: true } });
  assert.deepEqual(await fresh, { result: { fresh: true } });
});

test("a daemon's axo.connections call goes to the account and its answer comes back on the socket", async (t) => {
  const { h, session, host } = await fixture(t);
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  const reply = await daemon.call("axo.connections.list", { sessionId: crypto.randomUUID() });
  assert.ok("result" in reply, JSON.stringify(reply));
  const { connections } = reply.result as { connections: Array<{ kind: string }> };
  assert.deepEqual(connections.filter((c) => c.kind === "host"), [{ kind: "host", name: "test_mac", hostId: host.hostId, state: "online" }]);
  // A call the account refuses comes back as its error, not dropped.
  const refused = await daemon.call("axo.connections.execute", { connectionId: "c1", code: "1" });
  assert.ok("error" in refused);
  assert.equal(refused.error.code, -32602);
  // The socket still serves everything else.
  const beat = await daemon.call("axo.host.heartbeat", { hostId: host.hostId, hostGeneration: host.hostGeneration });
  assert.ok("result" in beat, JSON.stringify(beat));
});

test("a revoked host's socket closes with 4003, and a callHost waiting on it fails as disconnected", async (t) => {
  const { h, session, host, stub } = await fixture(t);
  const daemon = await connectHost(h, session, host);
  const waiting = stub.callHost({ method: "axo.connections.bash", params: {}, deadlineMs: 10_000 });
  await daemon.next();
  await stub.disconnect();
  assert.equal(await daemon.closed, 4003);
  assert.deepEqual(await waiting, { error: { code: -32004, message: "Host disconnected; the call may have run" } });
});

test("a Mac reconnects after a restart that dropped its socket, as a deploy does", async (t) => {
  const { h, session, host } = await fixture(t);
  const before = await connectHost(h, session, host);
  // A deploy restarts the HostDO without closing the socket in storage: its route outlives it.
  await h.restart();
  before.close();
  // Starting again fences the dead route, which reports the host offline while the HostDO is
  // still being constructed; that must not stop it from starting.
  const after = await connectHost(h, session, host);
  t.after(() => after.close());
  const { client } = await connectClient(h, session);
  t.after(() => client.close());
});
