import { test } from "node:test";
import assert from "node:assert/strict";
import { harness, Peer } from "./harness";
import { callSchema, decode, success, replySchema } from "@axo/protocol";

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
      "MachineRelay",
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

test("oversized aggregate metadata batches close the client, not the machine route", async (t) => {
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
  await assert.rejects(next, /Disconnected/);
  assert.equal(
    (await state.h.list(await state.h.token("client"))).result.machines[0]
      .online,
    true,
  );
});
