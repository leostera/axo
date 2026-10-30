import test from "node:test";
import assert from "node:assert/strict";
import { splitMessage } from "@axo/protocol";
import { harness, Peer } from "./harness";

// RFD0016, Transport: a daemon may send a message larger than a frame as fragments; the relay
// reassembles it before parsing, and closes the socket on a fragment that breaks the rules.

test("a fragmented call from a daemon is reassembled and answered", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const daemon = await Peer.connectHost(h.url, await h.token("daemon"), crypto.randomUUID(), "daemon");
  await daemon.negotiate();

  // A heartbeat with a large field: the relay must parse it whole to refuse it as invalid params.
  const raw = JSON.stringify({ jsonrpc: "2.0", id: "big-1", method: "axo.host.heartbeat", params: { padding: "x".repeat(200_000) } });
  const frames = splitMessage(raw, "big-1")!;
  assert.ok(frames.length > 1);
  for (const frame of frames) daemon.send(frame);
  const reply = (await daemon.next()) as { id: string; error?: { code: number } };
  assert.equal(reply.id, "big-1");
  assert.equal(reply.error?.code, -32602);

  // The socket still serves ordinary calls.
  const negotiated = await daemon.call("axo.protocol.negotiate", { protocolVersion: 2 });
  assert.ok("result" in negotiated);
  // A Mac on protocol 1 (integer Session IDs) is refused with a reason it can show (RFD0017).
  const outdated = await daemon.call("axo.protocol.negotiate", { protocolVersion: 1 }) as { error?: { code: number; message: string } };
  assert.equal(outdated.error?.code, -32010);
  assert.match(outdated.error?.message ?? "", /protocol 2/);
  daemon.close();
});

test("a fragment that breaks the rules closes the socket", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const daemon = await Peer.connectHost(h.url, await h.token("daemon"), crypto.randomUUID(), "daemon");
  await daemon.negotiate();
  daemon.send({ jsonrpc: "2.0", method: "axo.transport.fragment", params: { messageId: "m", index: 0, count: 500, data: "" } });
  await assert.rejects(daemon.next(), /Disconnected/);
});

test("a discard notice drops a partial message and the socket stays open", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const daemon = await Peer.connectHost(h.url, await h.token("daemon"), crypto.randomUUID(), "daemon");
  await daemon.negotiate();
  const raw = JSON.stringify({ jsonrpc: "2.0", id: "big-2", method: "axo.host.heartbeat", params: { padding: "x".repeat(200_000) } });
  const frames = splitMessage(raw, "big-2")!;
  daemon.send(frames[0]!);
  daemon.send({ jsonrpc: "2.0", method: "axo.transport.discard", params: { messageId: "big-2" } });
  // The rest arrives late and is ignored: no reply comes for the dropped message.
  for (const frame of frames.slice(1)) daemon.send(frame);
  const negotiated = await daemon.call("axo.protocol.negotiate", { protocolVersion: 2 });
  assert.ok("result" in negotiated);
  daemon.send({ jsonrpc: "2.0", id: "after", method: "axo.host.heartbeat", params: {} });
  const reply = (await daemon.next()) as { id: string };
  assert.equal(reply.id, "after", "nothing answered the dropped message");
  daemon.close();
});
