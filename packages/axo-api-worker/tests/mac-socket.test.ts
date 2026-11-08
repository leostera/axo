import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { callSchema, decode, replySchema, splitMessage } from "@axo/protocol";
import { Peer } from "../testing/client";
import { harness, root, signIn, type AccountSession, type Harness } from "./harness";
import { connectHost, pairHost, type PairedHost } from "./account-support";

/**
 * The Mac's socket to its HostDO, on the route axod uses: framing, fragments (RFD0016,
 * Transport), negotiation, registration and the frame budget.
 */

function code(reply: unknown): number {
  const parsed = replySchema.parse(reply);
  assert.ok("error" in parsed, JSON.stringify(reply));
  return parsed.error.code;
}

async function paired(t: { after(fn: () => unknown): void }) {
  const h = await harness();
  t.after(() => h.close());
  const session = await signIn(h);
  const host = await pairHost(h, session);
  return { h, session, host };
}

/** The host's socket, negotiated but not registered. */
async function negotiated(h: Harness, session: AccountSession, host: PairedHost): Promise<Peer> {
  const daemon = await Peer.connectHostDaemon(h.url, session.accountId, host.hostId, {
    Authorization: `Bearer ${host.credential}`,
    "X-Axo-Credential-Id": host.credentialId,
  });
  await daemon.negotiate();
  return daemon;
}

const heartbeat = (host: PairedHost, hostGeneration = host.hostGeneration) =>
  ({ hostId: host.hostId, hostGeneration });

test("the JSON-RPC envelope fixtures shared with Rust decode to the same errors", async () => {
  const fixtures = JSON.parse(await readFile(`${root}packages/axo-api/fixtures/envelopes.json`, "utf8")) as Array<{ raw: string; errors: number[]; name: string }>;
  for (const fixture of fixtures) {
    const result = decode(fixture.raw);
    const codes = "error" in result
      ? [code(result.error)]
      : result.entries.flatMap((value) => (callSchema.safeParse(value).success ? [] : [-32600]));
    assert.deepEqual(codes, fixture.errors, fixture.name);
  }
});

test("a frame is measured in encoded bytes, and an oversized batch gets one bounded error", () => {
  for (const raw of [
    "x".repeat(65537),
    JSON.stringify({ jsonrpc: "2.0", id: 1, method: "unknown", params: { data: "字".repeat(22000) } }),
    JSON.stringify(Array.from({ length: 9 }, () => ({ jsonrpc: "2.0", id: 1, method: "unknown" }))),
  ]) {
    const result = decode(raw);
    assert.ok("error" in result);
    assert.equal(code(result.error), -32600);
  }
});

test("a Mac negotiates protocol 2, and one on protocol 1 is refused with a reason it can show", async (t) => {
  const { h, session, host } = await paired(t);
  const daemon = await negotiated(h, session, host);
  t.after(() => daemon.close());
  assert.equal(code(await daemon.call("axo.host.heartbeat", heartbeat(host))), -32602, "nothing is registered yet");
  const outdated = (await daemon.call("axo.protocol.negotiate", { protocolVersion: 1 })) as { error?: { code: number; message: string } };
  assert.equal(outdated.error?.code, -32010);
  assert.match(outdated.error?.message ?? "", /protocol 2/);
});

test("a Mac's socket refuses calls until it negotiates", async (t) => {
  const { h, session, host } = await paired(t);
  const daemon = await Peer.connectHostDaemon(h.url, session.accountId, host.hostId, {
    Authorization: `Bearer ${host.credential}`,
    "X-Axo-Credential-Id": host.credentialId,
  });
  t.after(() => daemon.close());
  assert.equal(code(await daemon.call("axo.host.heartbeat", heartbeat(host))), -32001);
});

test("one socket cannot change its host generation while it registers", async (t) => {
  const { h, session, host } = await paired(t);
  const daemon = await negotiated(h, session, host);
  t.after(() => daemon.close());
  const register = (id: string, hostGeneration: string) => daemon.send({
    jsonrpc: "2.0", id, method: "axo.host.register",
    params: { protocolVersion: 2, hostId: host.hostId, hostGeneration, label: host.label, hostKind: "macos", sessions: [] },
  });
  const second = crypto.randomUUID();
  register("first", host.hostGeneration);
  register("second", second);
  const replies = [replySchema.parse(await daemon.next()), replySchema.parse(await daemon.next())];
  assert.ok(replies.some((reply) => reply.id === "first" && "result" in reply));
  assert.ok(replies.some((reply) => reply.id === "second" && "error" in reply));
  assert.ok("result" in (await daemon.call("axo.host.heartbeat", heartbeat(host))), "the first generation holds the lease");
  assert.equal(code(await daemon.call("axo.host.heartbeat", heartbeat(host, second))), -32602);
});

test("a fragmented call from a Mac is reassembled and answered", async (t) => {
  const { h, session, host } = await paired(t);
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  // A heartbeat with a large field: the relay must parse it whole to refuse it as invalid params.
  const raw = JSON.stringify({ jsonrpc: "2.0", id: "big-1", method: "axo.host.heartbeat", params: { ...heartbeat(host), padding: "x".repeat(200_000) } });
  const frames = splitMessage(raw, "big-1")!;
  assert.ok(frames.length > 1);
  for (const frame of frames) daemon.send(frame);
  const reply = (await daemon.next()) as { id: string; error?: { code: number } };
  assert.equal(reply.id, "big-1");
  assert.equal(reply.error?.code, -32602);
  assert.ok("result" in (await daemon.call("axo.host.heartbeat", heartbeat(host))), "the socket still serves ordinary calls");
});

test("a fragment that breaks the rules closes the Mac's socket", async (t) => {
  const { h, session, host } = await paired(t);
  const daemon = await connectHost(h, session, host);
  daemon.send({ jsonrpc: "2.0", method: "axo.transport.fragment", params: { messageId: "m", index: 0, count: 500, data: "" } });
  await assert.rejects(daemon.next(), /Disconnected/);
});

test("a discard notice drops a partial message, and the socket stays open", async (t) => {
  const { h, session, host } = await paired(t);
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  const raw = JSON.stringify({ jsonrpc: "2.0", id: "big-2", method: "axo.host.heartbeat", params: { ...heartbeat(host), padding: "x".repeat(200_000) } });
  const frames = splitMessage(raw, "big-2")!;
  daemon.send(frames[0]!);
  daemon.send({ jsonrpc: "2.0", method: "axo.transport.discard", params: { messageId: "big-2" } });
  // The rest arrives late and is ignored: no reply comes for the dropped message.
  for (const frame of frames.slice(1)) daemon.send(frame);
  daemon.send({ jsonrpc: "2.0", id: "after", method: "axo.host.heartbeat", params: heartbeat(host) });
  const reply = (await daemon.next()) as { id: string };
  assert.equal(reply.id, "after", "nothing answered the dropped message");
});

test("a Mac may send hundreds of frames a second, and is dropped past its budget", async (t) => {
  const { h, session, host } = await paired(t);
  const daemon = await connectHost(h, session, host);
  // A burst a shell printing output would produce: 200 frames inside one budget window.
  const started = Date.now();
  for (let round = 0; round < 8; round += 1)
    await Promise.all(Array.from({ length: 25 }, () => daemon.call("axo.host.heartbeat", heartbeat(host))));
  assert.ok(Date.now() - started < 1_000, "the burst must land inside one budget window to mean anything");
  assert.equal(daemon.socket.readyState, daemon.socket.OPEN, "a busy Mac keeps its socket");

  const closed = new Promise<string>((resolve) =>
    daemon.socket.once("close", (closeCode, reason) => resolve(`${closeCode} ${reason.toString()}`)));
  for (let index = 0; index < 700; index += 1)
    daemon.send({ jsonrpc: "2.0", method: "axo.host.session.progress", params: {} });
  assert.equal(await closed, "1008 Rate limit");
});
