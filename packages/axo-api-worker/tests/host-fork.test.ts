import assert from "node:assert/strict";
import { test } from "node:test";
import { AxoRpcError } from "@axo/app";
import type { HostMethodParams } from "@axo/protocol/v1";
import { Peer } from "../testing/client";
import { connectHost, pairHost } from "./account-support";
import { TestAccountClient } from "./axod-support";
import { harness, signIn } from "./harness";

const method = "axo.remote.session.fork";
const planMethod = "axo.remote.session.fork.plan";

test("fork planning and creation are scoped to the account and destination on person and peer routes", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const account = await signIn(h);
  const otherAccount = await signIn(h);
  const source = await pairHost(h, account, "Source");
  const destination = await pairHost(h, account, "Destination");
  const foreign = await pairHost(h, otherAccount, "Foreign");
  const daemon = await connectHost(h, account, destination);
  t.after(() => daemon.close());
  const credential = (host: typeof source) => ({
    Authorization: `Bearer ${host.credential}`,
    "X-Axo-Credential-Id": host.credentialId,
  });

  await assert.rejects(
    Peer.connectPeerHostClient(h.url, account.accountId, source.hostId, destination.hostId, credential(foreign)),
    /401/,
  );
  await assert.rejects(
    Peer.connectPeerHostClient(h.url, account.accountId, source.hostId, foreign.hostId, credential(source)),
    /404/,
  );

  const target = { hostId: destination.hostId, hostGeneration: destination.hostGeneration };
  const snapshot: HostMethodParams<typeof planMethod> = {
    target, sourceHostId: source.hostId, sessionId: crypto.randomUUID(), epoch: 1, head: 42,
  };
  const params: HostMethodParams<typeof method> = {
    ...snapshot, requestId: crypto.randomUUID(), folder: "/Users/example/project", agent: "codex",
  };
  const result = { session: {
    hostId: destination.hostId, sessionId: crypto.randomUUID(), shells: [], layout: null,
    updatedAt: "2026-10-30T00:00:00Z",
  } };
  for (const [person, protocol] of [[false, 2], [false, 3], [true, 2], [true, 3]] as const) {
    const clientId = person ? `tab-${crypto.randomUUID()}` : `host-${source.hostId}`;
    const peer = person
      ? protocol === 2
        ? await Peer.connectClient(h.url, clientId, account.headers)
        : await Peer.connectHostClient(h.url, destination.hostId, clientId, account.headers)
      : protocol === 2
        ? await Peer.connectHostPeers(h.url, account.accountId, source.hostId, credential(source))
        : await Peer.connectPeerHostClient(h.url, account.accountId, source.hostId, destination.hostId, credential(source));
    t.after(() => peer.close());
    const hello = await peer.call("axo.client.hello", { protocolVersion: protocol, clientId, ...(protocol === 3 ? { connection: 1 } : {}) });
    assert.ok("result" in hello, JSON.stringify(hello));
    const command = (name: string, params: unknown, hostId = target.hostId) =>
      peer.call("axo.client.command", { hostId, method: name, params });

    for (const [name, input, extras] of [
      [method, params, [{ folder: "relative/path" }, { agent: "unknown" }]],
      [planMethod, snapshot, [{ sourceAgent: "pi" }, { historyFormat: "pi/3" }, { agent: "pi" }, { requestId: params.requestId }]],
    ] as const) {
      for (const [invalid, hostId, code] of [
        [{ ...input, sourceHostId: foreign.hostId }, target.hostId, -32602],
        [{ ...input, sourceHostId: target.hostId }, target.hostId, -32602],
        [{ ...input, target: { ...target, hostId: source.hostId } }, target.hostId, -32002],
        [{ ...input, target: { ...target, hostGeneration: crypto.randomUUID() } }, target.hostId, -32002],
        [input, foreign.hostId, -32602],
        ...extras.map(extra => [{ ...input, ...extra }, target.hostId, -32602] as const),
      ] as const) {
        const reply = await command(name, invalid, hostId);
        assert.ok("error" in reply, JSON.stringify(reply));
        assert.equal(reply.error.code, code);
      }
    }

    type ErrorPayload = { code: number; message: string; data?: unknown };
    const invoke = async (name: string, input: unknown, reply: { result: unknown } | { error: ErrorPayload }) => {
      const pending = command(name, input);
      const sent = await daemon.next() as { id: string; method: string; params: unknown };
      assert.equal(sent.method, name);
      assert.deepEqual(sent.params, input, "rejected calls did not reach the daemon");
      daemon.send({ jsonrpc: "2.0", id: sent.id, ...reply });
      return pending;
    };
    const plan = { sourceAgent: "pi", historyFormat: "pi/3", decision: { kind: "choose", agents: ["codex"] } };
    const planned = await invoke(planMethod, snapshot, { result: plan });
    assert.ok("result" in planned, JSON.stringify(planned));
    assert.deepEqual(planned.result, plan);
    const invalidPlan = await invoke(planMethod, snapshot, { result: { ...plan, decision: { kind: "keep", agent: "codex" } } });
    assert.ok("error" in invalidPlan, JSON.stringify(invalidPlan));
    assert.equal(invalidPlan.error.code, -32004);
    const unsupported = { code: -32601, message: "Method not found" };
    const oldHost = await invoke(planMethod, snapshot, { error: unsupported });
    assert.ok("error" in oldHost, JSON.stringify(oldHost));
    assert.deepEqual(oldHost.error, unsupported);

    const forked = await invoke(method, params, { result });
    assert.ok("result" in forked, JSON.stringify(forked));
    assert.deepEqual(forked.result, result);
    for (const error of [
      { code: -32602, message: "Choose a destination folder" },
      { code: -32601, message: "Method not found" },
      { code: -32602, message: "Only Pi sessions can be forked" },
    ]) {
      const refused = await invoke(method, params, { error });
      assert.ok("error" in refused, JSON.stringify(refused));
      assert.deepEqual(refused.error, error);
    }
    const rejection = { code: -32602, message: "Harness unavailable" };
    const data = { kind: "forkHarnessUnavailable", created: false };
    const unavailable = await invoke(method, params, { error: { ...rejection, data } });
    assert.ok("error" in unavailable, JSON.stringify(unavailable));
    assert.deepEqual(unavailable.error, { ...rejection, data });
    for (const [name, input, code, unsafeData] of [
      [method, params, -32004, data],
      [method, params, rejection.code, { ...data, created: true }],
      [method, params, rejection.code, { ...data, secret: "not for the wire" }],
      [planMethod, snapshot, rejection.code, data],
    ] as const) {
      const refused = await invoke(name, input, { error: { ...rejection, code, data: unsafeData } });
      assert.ok("error" in refused, JSON.stringify(refused));
      assert.deepEqual(refused.error, { ...rejection, code });
    }
    const invalid = await invoke(method, params, { result: { accepted: true } });
    assert.ok("error" in invalid, JSON.stringify(invalid));
    assert.equal(invalid.error.code, -32004);
    peer.close();
  }

  // Exercise the actual SDK's AccountConnection and JSON-RPC error decoding across the Worker.
  const app = await TestAccountClient.connect(h.url, account);
  t.after(() => app.close());
  const plan = { sourceAgent: "pi", historyFormat: "pi/3", decision: { kind: "choose", agents: ["codex"] } };
  const planning = app.connection.command(planMethod, snapshot);
  const planCall = await daemon.next() as { id: string; method: string; params: unknown };
  assert.equal(planCall.method, planMethod);
  assert.deepEqual(planCall.params, snapshot);
  daemon.send({ jsonrpc: "2.0", id: planCall.id, result: plan });
  assert.deepEqual(await planning, plan);

  const definitive = { kind: "forkHarnessUnavailable", created: false };
  for (const [code, data, expectedData] of [
    [-32602, definitive, definitive],
    [-32602, undefined, undefined],
    [-32602, { ...definitive, created: true }, undefined],
    [-32602, { ...definitive, extra: "untrusted data" }, undefined],
    [-32004, definitive, undefined],
  ] as const) {
    const pending = app.connection.command(method, params);
    const rejected = assert.rejects(pending, (error: unknown) => {
      assert.ok(error instanceof AxoRpcError);
      assert.equal(error.code, code);
      assert.deepEqual(error.data, expectedData);
      return true;
    });
    const sent = await daemon.next() as { id: string; method: string; params: unknown };
    assert.equal(sent.method, method);
    assert.deepEqual(sent.params, params);
    daemon.send({ jsonrpc: "2.0", id: sent.id, error: { code, message: "Fork refused", data } });
    await rejected;
  }
});
