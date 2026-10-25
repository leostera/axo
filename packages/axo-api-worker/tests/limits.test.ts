import { test } from "node:test";
import assert from "node:assert/strict";
import { harness, Peer } from "./harness";
import { LIMITS, results, remoteMethods, callSchema, decode, success, replySchema } from "@axo/protocol";

async function connected() {
  const h = await harness();
  const machineId = crypto.randomUUID();
  const hostGeneration = crypto.randomUUID();
  const daemon = await Peer.connect(
    h.url,
    await h.token("daemon"),
    machineId,
    "daemon",
  );
  await daemon.negotiate();
  await daemon.call("axo.machine.register", {
    protocolVersion: 1,
    machineId,
    hostGeneration,
    label: "Limit fixture",
  });
  const peer = await Peer.connect(
    h.url,
    await h.token("client"),
    machineId,
    "client",
  );
  await peer.negotiate();
  return {
    h,
    daemon,
    peer,
    target: { machineId, hostGeneration },
    async close() {
      daemon.close();
      peer.close();
      await h.close();
    },
  };
}
function code(value: unknown) {
  const reply = replySchema.parse(value);
  assert.ok("error" in reply);
  return reply.error.code;
}

test("frame size is encoded bytes; overly large batches have one bounded error", () => {
  for (const raw of [
    "x".repeat(65537),
    JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "unknown",
      params: { data: "字".repeat(22000) },
    }),
    JSON.stringify(
      Array.from({ length: 9 }, () => ({
        jsonrpc: "2.0",
        id: 1,
        method: "unknown",
      })),
    ),
  ]) {
    const result = decode(raw);
    assert.ok("error" in result);
    assert.equal(code(result.error), -32600);
  }
});

test(
  "forwarded call deadline produces unknown outcome and releases durable correlation",
  { timeout: 16000 },
  async (t) => {
    const state = await connected();
    t.after(() => state.close());
    const pending = state.peer.call("axo.runtime.list", {
      target: state.target,
    });
    const forwarded = callSchema.parse(await state.daemon.next()); // Deliberately no reply.
    assert.equal(code(await pending), -32004);
    const storage = await state.h.mf.unsafeGetDurableObjectStorage(
      "api-test",
      "AxoHostRelay",
      { name: state.target.machineId },
    );
    assert.equal((await storage.exec("SELECT * FROM pending")).length, 0);
    // A late otherwise-valid response cannot resurrect the expired request.
    state.daemon.send(
      success(forwarded.id!, {
        hostGeneration: state.target.hostGeneration,
        terminals: [],
        next: null,
      }),
    );
    assert.equal(
      (await state.h.list(await state.h.token("client"))).result.machines[0]
        .online,
      true,
    );
  },
);

test("expired mutation correlation ignores late success and never replays the command", { timeout: 16000 }, async (t) => {
  const state = await connected();
  t.after(() => state.close());
  const commandId = crypto.randomUUID();
  const target = { ...state.target, sessionId: crypto.randomUUID(), paneId: crypto.randomUUID() };
  state.peer.send({ jsonrpc: "2.0", id: "mutation", method: "axo.runtime.startApproved", params: { target, commandId, profileId: "fixture" } });
  const forwarded = callSchema.parse(await state.daemon.next());
  assert.equal(forwarded.method, "axo.runtime.startApproved");
  assert.equal(remoteMethods["axo.runtime.startApproved"].parse(forwarded.params).commandId, commandId);
  const expired = replySchema.parse(await state.peer.next());
  assert.equal(expired.id, "mutation");
  assert.equal(code(expired), -32004);
  const storage = await state.h.mf.unsafeGetDurableObjectStorage("api-test", "AxoHostRelay", { name: state.target.machineId });
  assert.equal((await storage.exec("SELECT * FROM pending")).length, 0);
  assert.equal((await storage.exec("SELECT * FROM groups")).length, 0);
  // Valid synthetic metadata, not process or execution evidence. The old hop has expired.
  const outcome = { hostGeneration: state.target.hostGeneration, terminal: { runtime: { host_generation: target.hostGeneration, target: { session_id: target.sessionId, pane_id: target.paneId }, runtime_generation: crypto.randomUUID() }, process: { kind: "exited", wait_status: 0 }, attached: false, backlog_bytes: 0 } };
  assert.ok(results["axo.runtime.startApproved"].safeParse(outcome).success);
  state.daemon.send(success(forwarded.id!, outcome));
  state.peer.send({ jsonrpc: "2.0", id: "after-expiry", method: "axo.runtime.list", params: { target: state.target } });
  const fresh = callSchema.parse(await state.daemon.next());
  assert.equal(fresh.method, "axo.runtime.list", "The expired mutation was replayed");
  assert.notEqual(fresh.id, forwarded.id);
  state.daemon.send(success(fresh.id!, { hostGeneration: state.target.hostGeneration, terminals: [], next: null }));
  const reply = replySchema.parse(await state.peer.next());
  assert.equal(reply.id, "after-expiry", "Late success resurrected an expired correlation");
  assert.ok("result" in reply);
  assert.equal((await storage.exec("SELECT * FROM pending")).length, 0);
  assert.equal((await storage.exec("SELECT * FROM groups")).length, 0);
});

test("oversized aggregate replies preserve every ID as bounded outcomes without dropping either route", async (t) => {
  const state = await connected();
  t.after(() => state.close());
  state.peer.send(
    Array.from({ length: 8 }, (_, index) => ({
      jsonrpc: "2.0",
      id: index,
      method: "axo.runtime.list",
      params: { target: state.target },
    })),
  );
  const forwarded = [];
  for (let index = 0; index < 8; index++)
    forwarded.push(callSchema.parse(await state.daemon.next()));
  // Valid synthetic metadata only; this is an API capacity test, not process evidence.
  const terminals = Array.from({ length: 50 }, () => ({
    runtime: {
      host_generation: state.target.hostGeneration,
      target: { session_id: crypto.randomUUID(), pane_id: crypto.randomUUID() },
      runtime_generation: crypto.randomUUID(),
    },
    process: { kind: "exited", wait_status: 0 },
    attached: false,
    backlog_bytes: 0,
  }));
  const next = state.peer.next();
  for (const call of forwarded)
    state.daemon.send(
      success(call.id!, {
        hostGeneration: state.target.hostGeneration,
        terminals,
        next: null,
      }),
    );
  const replies = await next;
  assert.ok(Array.isArray(replies));
  assert.equal(replies.length, 8);
  assert.deepEqual(replies.map(reply => replySchema.parse(reply).id).sort(), Array.from({ length: 8 }, (_, index) => index));
  assert.ok(replies.some(reply => code(reply) === -32004));
  assert.ok(new TextEncoder().encode(JSON.stringify(replies)).byteLength <= LIMITS.frameBytes);
  for (const reply of replies) {
    const parsed = replySchema.parse(reply);
    if ("error" in parsed) assert.equal(parsed.error.code, -32004);
    else assert.ok(results["axo.runtime.list"].safeParse(parsed.result).success);
  }
  const fresh = state.peer.call("axo.runtime.list", { target: state.target });
  const read = callSchema.parse(await state.daemon.next());
  state.daemon.send(success(read.id!, { hostGeneration: state.target.hostGeneration, terminals: [], next: null }));
  assert.ok("result" in replySchema.parse(await fresh));
  const storage = await state.h.mf.unsafeGetDurableObjectStorage("api-test", "AxoHostRelay", { name: state.target.machineId });
  assert.equal((await storage.exec("SELECT * FROM pending")).length, 0);
  assert.equal((await storage.exec("SELECT * FROM groups")).length, 0);
  assert.equal(
    (await state.h.list(await state.h.token("client"))).result.machines[0]
      .online,
    true,
  );
});

test("hosts may stream far more frames per second than clients may send", async (t) => {
  const fixture = await connected();
  t.after(() => fixture.close());
  const heartbeat = { machineId: fixture.target.machineId, hostGeneration: fixture.target.hostGeneration };
  // A burst well above the client budget, as a shell printing output would produce.
  const started = Date.now();
  for (let round = 0; round < 8; round += 1) {
    await Promise.all(Array.from({ length: 25 }, () => fixture.daemon.call("axo.machine.heartbeat", heartbeat)));
  }
  assert.ok(Date.now() - started < 1_000, "the burst must land inside one budget window to mean anything");
  assert.equal(fixture.daemon.socket.readyState, fixture.daemon.socket.OPEN, "a busy host keeps its relay");

  const closed = new Promise<string>((resolveClose) =>
    fixture.peer.socket.once("close", (closeCode, reason) => resolveClose(`${closeCode} ${reason.toString()}`)));
  for (let index = 0; index < 40; index += 1) {
    fixture.peer.send({ jsonrpc: "2.0", id: `burst-${index}`, method: "axo.machine.list", params: {} });
  }
  assert.equal(await closed, "1008 Rate limit", "a client over its budget is dropped");
});
