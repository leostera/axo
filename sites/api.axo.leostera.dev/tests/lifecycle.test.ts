import { test } from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import WebSocket from "ws";
import { harness, Peer } from "./harness";
import { callSchema, success, replySchema } from "@axo/protocol";

async function machine(
  h: Awaited<ReturnType<typeof harness>>,
  id = crypto.randomUUID(),
  assertion?: string,
) {
  const daemon = await Peer.connect(
    h.url,
    assertion ?? (await h.token("daemon")),
    id,
    "daemon",
  );
  await daemon.negotiate();
  const target = { machineId: id, hostGeneration: crypto.randomUUID() };
  const reply = await daemon.call("axo.machine.register", {
    protocolVersion: 1,
    ...target,
    label: "Lifecycle fixture",
  });
  assert.ok("result" in reply);
  return { daemon, target };
}

test("hibernation restores pending correlation, partial batches and delivery credits", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const a = await machine(h);
  const peer = await Peer.connect(
    h.url,
    await h.token("client"),
    a.target.machineId,
    "client",
  );
  await peer.negotiate();
  t.after(() => {
    a.daemon.close();
    peer.close();
  });
  peer.send([
    {
      jsonrpc: "2.0",
      id: "forward",
      method: "axo.runtime.list",
      params: { target: a.target },
    },
    { jsonrpc: "2.0", id: "local", method: "unknown" },
  ]);
  const forwarded = callSchema.parse(await a.daemon.next());
  const storage = await h.mf.unsafeGetDurableObjectStorage(
    "api-test",
    "MachineRelay",
    { name: a.target.machineId },
  );
  assert.equal((await storage.exec("SELECT hop_id FROM pending")).length, 1);
  await h.mf.unsafeEvictDurableObject("api-test", "MachineRelay", {
    name: a.target.machineId,
    webSockets: "hibernate",
  });
  a.daemon.send(
    success(forwarded.id!, {
      hostGeneration: a.target.hostGeneration,
      terminals: [],
      next: null,
    }),
  );
  const replies = await peer.next();
  assert.ok(Array.isArray(replies));
  assert.equal(replies.length, 2);
  assert.ok(
    replies.some((value) => {
      const reply = replySchema.parse(value);
      return reply.id === "forward" && "result" in reply;
    }),
  );
  assert.equal((await storage.exec("SELECT * FROM pending")).length, 0);
  assert.equal((await storage.exec("SELECT * FROM groups")).length, 0);
});

test("whole runtime restart keeps registration but never restores a live phantom route", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const a = await machine(h);
  const token = await h.token("client");
  await h.restart();
  a.daemon.close();
  const rows = (await h.list(token)).result.machines;
  assert.equal(rows.length, 1);
  assert.equal(rows[0].machineId, a.target.machineId);
  assert.equal(rows[0].online, false);
  assert.equal(rows[0].hostGeneration, null);
  const replacement = await machine(h, a.target.machineId);
  t.after(() => replacement.daemon.close());
  assert.equal(
    (await h.list(token)).result.machines[0].hostGeneration,
    replacement.target.hostGeneration,
  );
});

test("JWT expiry closes daemon lease by alarm and preserves offline registration", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const assertion = await h.token(
    "daemon",
    {},
    Math.floor(Date.now() / 1000) + 2,
  );
  const a = await machine(h, crypto.randomUUID(), assertion);
  t.after(() => a.daemon.close());
  await once(a.daemon.socket, "close");
  const rows = (await h.list(await h.token("client"))).result.machines;
  assert.equal(rows.length, 1);
  assert.equal(rows[0].online, false);
});

test("native-only origin guard and directory reservations bound relay creation", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const token = await h.token("daemon");
  const clientToken = await h.token("client");
  const socket = new WebSocket(
    `${h.url.replace(/^http/, "ws")}v1/machines/${crypto.randomUUID()}/daemon`,
    {
      headers: {
        "Cf-Access-Jwt-Assertion": token,
        Origin: "https://untrusted.example",
      },
    },
  );
  const [error] = await once(socket, "error");
  assert.match(String(error), /403/);
  await assert.rejects(
    Peer.connect(h.url, clientToken, crypto.randomUUID(), "client"),
    /404/,
  );
  const peers: Peer[] = [];
  t.after(() => peers.forEach((peer) => peer.close()));
  for (let index = 0; index < 16; index++)
    peers.push(await Peer.connect(h.url, token, crypto.randomUUID(), "daemon"));
  // Pending sockets reserve bounded membership but are not registered/discoverable yet.
  assert.deepEqual((await h.list(clientToken)).result.machines, []);
  await assert.rejects(
    Peer.connect(h.url, token, crypto.randomUUID(), "daemon"),
    /429/,
  );
});

test("one socket cannot rewrite its host generation during registration", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const id = crypto.randomUUID();
  const daemon = await Peer.connect(
    h.url,
    await h.token("daemon"),
    id,
    "daemon",
  );
  t.after(() => daemon.close());
  await daemon.negotiate();
  const first = crypto.randomUUID();
  const second = crypto.randomUUID();
  daemon.send({
    jsonrpc: "2.0",
    id: "first",
    method: "axo.machine.register",
    params: {
      protocolVersion: 1,
      machineId: id,
      hostGeneration: first,
      label: "First",
    },
  });
  daemon.send({
    jsonrpc: "2.0",
    id: "second",
    method: "axo.machine.register",
    params: {
      protocolVersion: 1,
      machineId: id,
      hostGeneration: second,
      label: "Second",
    },
  });
  const replies = [
    replySchema.parse(await daemon.next()),
    replySchema.parse(await daemon.next()),
  ];
  assert.ok(replies.some((reply) => reply.id === "first" && "result" in reply));
  assert.ok(replies.some((reply) => reply.id === "second" && "error" in reply));
  assert.equal(
    (await h.list(await h.token("client"))).result.machines[0].hostGeneration,
    first,
  );
});
