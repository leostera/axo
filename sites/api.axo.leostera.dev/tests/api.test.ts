import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { once } from "node:events";
import WebSocket from "ws";
import { harness, Peer, root } from "./harness";
import {
  decode,
  callSchema,
  failure,
  replySchema,
  success,
} from "@axo/protocol";

async function registered(
  h: Awaited<ReturnType<typeof harness>>,
  machineId = crypto.randomUUID(),
  assertion?: string,
) {
  const daemon = await Peer.connect(
    h.url,
    assertion ?? (await h.token("daemon")),
    machineId,
    "daemon",
  );
  await daemon.negotiate();
  const hostGeneration = crypto.randomUUID();
  const reply = await daemon.call("axo.machine.register", {
    protocolVersion: 1,
    machineId,
    hostGeneration,
    label: "Isolated fixture",
  });
  assert.ok("result" in reply);
  return { daemon, target: { machineId, hostGeneration } };
}
async function client(
  h: Awaited<ReturnType<typeof harness>>,
  machine: string,
  credits = true,
) {
  const peer = await Peer.connect(
    h.url,
    await h.token("client"),
    machine,
    "client",
    credits,
  );
  await peer.negotiate();
  return peer;
}
function code(reply: unknown) {
  const parsed = replySchema.parse(reply);
  assert.ok("error" in parsed);
  return parsed.error.code;
}

test("shared JSON-RPC envelope fixtures agree with Rust", async () => {
  const fixtures = JSON.parse(
    await readFile(`${root}packages/axo-api/fixtures/envelopes.json`, "utf8"),
  ) as Array<{ raw: string; errors: number[]; name: string }>;
  for (const fixture of fixtures) {
    const result = decode(fixture.raw);
    const codes =
      "error" in result
        ? [code(result.error)]
        : result.entries.flatMap((value) =>
            callSchema.safeParse(value).success ? [] : [-32600],
          );
    assert.deepEqual(codes, fixture.errors, fixture.name);
  }
});

test("Worker does not require or validate Access JWTs", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const body = JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "axo.machine.list",
    params: {},
  });
  const direct = await fetch(`${h.url}v1/rpc`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
  });
  assert.equal(direct.status, 200);

  for (const token of [
    "forged",
    await h.token("daemon"),
    await h.token("client", { email: "wrong@example.com" }),
    await h.token("client", { common_name: "daemon.access" }),
    await h.token("client", {}, Math.floor(Date.now() / 1000) - 1),
  ]) {
    const response = await fetch(`${h.url}v1/rpc`, {
      method: "POST",
      headers: { "Cf-Access-Jwt-Assertion": token, "Content-Type": "application/json" },
      body,
    });
    assert.equal(response.status, 200);
  }
  assert.deepEqual((await h.list(await h.token("client"))).result.machines, []);
});

test("daemon WebSocket connections reach the Worker without Access JWT headers", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const socket = new WebSocket(
    `${h.url.replace(/^http/, "ws")}v1/machines/${crypto.randomUUID()}/daemon`,
    { followRedirects: false },
  );
  await once(socket, "open");
  socket.terminate();
});

test("automatic registration, two machines and independent colliding client IDs", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const a = await registered(h);
  const b = await registered(h);
  t.after(() => {
    a.daemon.close();
    b.daemon.close();
  });
  const machines = (await h.list(await h.token("client"))).result.machines;
  assert.equal(machines.length, 2);
  assert.ok(machines.every((machine) => machine.online));
  const first = await client(h, a.target.machineId);
  const second = await client(h, a.target.machineId);
  t.after(() => {
    first.close();
    second.close();
  });
  const one = first.call("axo.runtime.list", { target: a.target }, "same-id");
  const two = second.call("axo.runtime.list", { target: a.target }, "same-id");
  const forwarded = [
    callSchema.parse(await a.daemon.next()),
    callSchema.parse(await a.daemon.next()),
  ];
  assert.notEqual(forwarded[0].id, forwarded[1].id);
  a.daemon.send(
    success(forwarded[1].id!, {
      hostGeneration: a.target.hostGeneration,
      terminals: [],
      next: null,
    }),
  );
  a.daemon.send(
    success(forwarded[0].id!, {
      hostGeneration: a.target.hostGeneration,
      terminals: [],
      next: null,
    }),
  );
  const replies = await Promise.all([one, two]);
  assert.ok(
    replies.every((reply) => reply.id === "same-id" && "result" in reply),
  );
  assert.equal(
    code(await first.call("axo.runtime.list", { target: b.target })),
    -32002,
  );
  assert.equal(
    code(
      await first.call("axo.runtime.list", {
        target: { ...a.target, hostGeneration: crypto.randomUUID() },
      }),
    ),
    -32002,
  );
});

test("duplicate live machine admission and malformed IDs fail closed", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const a = await registered(h);
  t.after(() => a.daemon.close());
  await assert.rejects(
    Peer.connect(h.url, await h.token("daemon"), a.target.machineId, "daemon"),
    /409/,
  );
  await assert.rejects(
    Peer.connect(
      h.url,
      await h.token("daemon"),
      a.target.machineId.toUpperCase(),
      "daemon",
    ),
    /409/,
  );
});

test("bounded batch replies, null ID and notification mutations never execute", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const a = await registered(h);
  const peer = await client(h, a.target.machineId);
  t.after(() => {
    a.daemon.close();
    peer.close();
  });
  let forwardedMutations = 0;
  a.daemon.socket.on("message", (raw) => {
    if (JSON.parse(raw.toString()).method === "axo.runtime.startApproved")
      forwardedMutations++;
  });
  peer.send([
    { jsonrpc: "2.0", id: null, method: "unknown" },
    {
      jsonrpc: "2.0",
      method: "axo.runtime.startApproved",
      params: { target: a.target },
    },
    {
      jsonrpc: "2.0",
      id: 2,
      method: "axo.runtime.list",
      params: { target: a.target },
    },
    3,
  ]);
  const forwarded = callSchema.parse(await a.daemon.next());
  a.daemon.send(
    success(forwarded.id!, {
      hostGeneration: a.target.hostGeneration,
      terminals: [],
      next: null,
    }),
  );
  const replies = await peer.next();
  assert.ok(Array.isArray(replies));
  assert.equal(replies.length, 3);
  assert.equal(forwardedMutations, 0);
  assert.equal(
    replies.filter((reply) => codeOrZero(reply) === -32600).length,
    1,
  );
  peer.send("{");
  assert.equal(code(await peer.next()), -32700);
  peer.send([]);
  assert.equal(code(await peer.next()), -32600);
  assert.equal(
    code(
      await peer.call("axo.runtime.startApproved", {
        target: a.target,
        argv: ["/bin/sh"],
      }),
    ),
    -32602,
  );
});
function codeOrZero(value: unknown) {
  const reply = replySchema.parse(value);
  return "error" in reply ? reply.error.code : 0;
}

test("disconnect after forwarding reports unknown and never binds old calls to a replacement", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const a = await registered(h);
  const peer = await client(h, a.target.machineId);
  t.after(() => peer.close());
  const pending = peer.call("axo.runtime.list", { target: a.target });
  await a.daemon.next();
  a.daemon.close();
  assert.equal(code(await pending), -32004);
  const machines = (await h.list(await h.token("client"))).result.machines;
  assert.equal(machines[0].online, false);
  assert.equal(
    code(await peer.call("axo.runtime.list", { target: a.target })),
    -32005,
  );
  const replacement = await registered(h, a.target.machineId);
  t.after(() => replacement.daemon.close());
  assert.equal(
    code(await peer.call("axo.runtime.list", { target: a.target })),
    -32002,
  );
});

test("forged replies and raw byte responses do not confirm execution", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const a = await registered(h);
  const b = await registered(h);
  const peer = await client(h, a.target.machineId);
  t.after(() => {
    a.daemon.close();
    b.daemon.close();
    peer.close();
  });
  const pending = peer.call("axo.runtime.list", { target: a.target });
  const forwarded = callSchema.parse(await a.daemon.next());
  b.daemon.send(
    success(forwarded.id!, {
      hostGeneration: b.target.hostGeneration,
      terminals: [],
      next: null,
    }),
  );
  a.daemon.send(success(forwarded.id!, { data: [1, 2, 3] }));
  assert.equal(code(await pending), -32004);
});

test("slow clients exhaust delivery credits without stopping daemon connectivity", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const a = await registered(h);
  const peer = await client(h, a.target.machineId, false);
  t.after(() => {
    a.daemon.close();
    peer.close();
  });
  const closed = once(peer.socket, "close");
  for (let i = 0; i < 33; i++) {
    if (i === 20) await new Promise((resolve) => setTimeout(resolve, 1050));
    if (peer.socket.readyState !== 1) break;
    peer.send({ jsonrpc: "2.0", id: i, method: "unknown" });
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  await closed;
  assert.equal(
    (await h.list(await h.token("client"))).result.machines[0].online,
    true,
  );
});
