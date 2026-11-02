import assert from "node:assert/strict";
import test from "node:test";
import { AxodCallError } from "../src/axod-client.js";
import { parseRemoteViewConfig, RemoteSession, type PeerSessionView, type RemoteLink } from "../src/remote-view.js";

const hostId = "2e2e7f91-3d8f-4f97-8f71-4fc7d53313c7";
const sessionId = "8f8f8f8f-0000-4000-8000-000000000001";
const config = { socket: "/tmp/axo.sock", hostId, hostLabel: "Mac Studio", sessionId };

const message = (id: string, role: string, text: string) =>
  JSON.stringify({ type: "message", id, parentId: null, timestamp: "2026-11-01T12:00:00.000Z", message: { role, content: [{ type: "text", text }] } });
const receipt = (id: string, commandId: string) =>
  JSON.stringify({ type: "custom", id, parentId: null, timestamp: "2026-11-01T12:00:00.000Z", customType: "axo.command", data: { commandId } });

function view(records: string[], change: Partial<PeerSessionView> = {}, first = 1): PeerSessionView {
  return {
    version: 1, epoch: 1, cursor: first + records.length - 1, reset: false, more: false, progress: [],
    status: "ready", hostLabel: "Mac Studio", hostOnline: true, connected: true,
    records: records.map((line, index) => ({ cursor: first + index, line })),
    ...change,
  };
}

/** Axod answering commands as the test says; what was sent is in `sent`. */
function axod(answers: Array<unknown | Error> = []) {
  const sent: Array<{ method: string; params: Record<string, unknown> }> = [];
  const link: RemoteLink = {
    command: async (method, params) => {
      sent.push({ method, params });
      const answer = answers.shift() ?? { accepted: true };
      if (answer instanceof Error) throw answer;
      return answer;
    },
  };
  return { sent, link };
}

let ids = 0;
const newId = () => `0a1b2c3d-4e5f-4a6b-8c7d-8e9f0a1b2c${String(++ids).padStart(2, "0")}`;

test("remote mode needs Axod's socket and the other Mac's ids", () => {
  assert.deepEqual(parseRemoteViewConfig({ AXO_SOCKET: "/tmp/axo.sock", AXO_REMOTE_HOST_ID: hostId.toUpperCase(), AXO_REMOTE_SESSION_ID: sessionId, AXO_REMOTE_HOST_LABEL: "Mac Studio" }), config);
  assert.equal(parseRemoteViewConfig({ AXO_SOCKET: "/tmp/axo.sock", AXO_REMOTE_HOST_ID: "studio", AXO_REMOTE_SESSION_ID: sessionId }), null);
  assert.equal(parseRemoteViewConfig({ AXO_REMOTE_HOST_ID: hostId, AXO_REMOTE_SESSION_ID: sessionId }), null, "a Session of this Mac");
});

test("the copy is drawn as Pi's messages, and what Pi does not show is skipped", () => {
  const session = new RemoteSession(config, axod().link);
  const change = session.apply(view([
    message("e1", "user", "Fix the bug"),
    JSON.stringify({ type: "model_change", id: "e2", parentId: null, provider: "x", modelId: "y" }),
    message("e3", "assistant", "On it"),
    JSON.stringify({ type: "message", id: "e4", message: { role: "toolResult", toolCallId: "c1", toolName: "bash", content: [{ type: "text", text: "ok" }], isError: false } }),
  ]));
  assert.equal(change.redraw, false);
  assert.deepEqual(change.draw.map(drawable => drawable.kind), ["user", "assistant", "toolResult"]);
  assert.deepEqual([session.epoch, session.cursor, session.lastUserEntry], [1, 4, "e1"]);
});

test("a cut after something is drawn starts the screen over; before, it just draws", () => {
  const session = new RemoteSession(config, axod().link);
  assert.equal(session.apply(view([], { reset: true, epoch: 1, cursor: 0 })).redraw, false, "nothing drawn yet");
  session.apply(view([message("e1", "user", "hi")]));
  assert.equal(session.apply(view([message("e1", "user", "hi")], { reset: true, epoch: 2 })).redraw, true);
});

test("a prompt is pending until its receipt and its user message are in the copy, never by its words", async () => {
  const { sent, link } = axod();
  const session = new RemoteSession(config, link, () => {}, 60_000, newId);
  assert.deepEqual(await session.send("yes"), { kind: "accepted" });
  const commandId = sent[0]!.params.commandId as string;
  assert.deepEqual(sent[0], { method: "axo.remote.session.prompt", params: { sessionId, text: "yes", commandId } });
  assert.equal(session.pending[0]?.state, "sent");
  session.apply(view([message("e1", "user", "yes")]));
  assert.equal(session.pending.length, 1, "the same words typed on the other Mac are not this prompt");
  session.apply(view([receipt("e2", commandId)], {}, 2));
  assert.equal(session.pending.length, 1, "the receipt alone does not show it");
  session.apply(view([message("e3", "user", "yes")], {}, 3));
  assert.equal(session.pending.length, 0);
  session.dispose();
});

test("a prompt refused on its first try comes back; an unknown one is sent again with its commandId", async () => {
  const offline = new AxodCallError("Host offline; nothing queued", -32005);
  const unknown = new AxodCallError("Outcome unknown; reconcile commandId", -32004);
  const refused = axod([offline]);
  const first = new RemoteSession(config, refused.link, () => {}, 60_000, newId);
  assert.deepEqual(await first.send("hello"), { kind: "refused", message: "Host offline; nothing queued", offline: true });
  assert.equal(first.pending.length, 0);

  // Unknown, then offline on the retry (which proves nothing), then taken.
  const { sent, link } = axod([unknown, offline, { accepted: true }]);
  const session = new RemoteSession(config, link, () => {}, 1, newId);
  assert.deepEqual(await session.send("deploy"), { kind: "uncertain" });
  for (let wait = 0; wait < 100 && sent.length < 3; wait += 1) await new Promise(resolve => setTimeout(resolve, 2));
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.equal(sent.length, 3);
  assert.equal(new Set(sent.map(call => call.params.commandId)).size, 1, "every try is one command");
  assert.equal(session.pending[0]?.state, "sent");
  session.dispose();
});

test("a prompt sent while the other Mac works is queued there", async () => {
  const session = new RemoteSession(config, axod().link, () => {}, 60_000, newId);
  session.apply(view([message("e1", "user", "go")], { status: "working" }));
  await session.send("and then this");
  assert.equal(session.pending[0]?.state, "queued");
  session.dispose();
});

test("Escape stops the turn shown running, by its user message, once", async () => {
  const { sent, link } = axod([{ stopped: true }]);
  const session = new RemoteSession(config, link);
  assert.equal(await session.stop(), false, "nothing runs");
  session.apply(view([message("e1", "user", "go"), message("e2", "assistant", "working")], { status: "working" }));
  const [stopped, again] = await Promise.all([session.stop(), session.stop()]);
  assert.deepEqual([stopped, again], [true, false]);
  assert.deepEqual(sent, [{ method: "axo.remote.session.stop", params: { sessionId, turnId: "e1" } }]);
  session.apply(view([], { status: "ready", cursor: 2 }, 3));
  assert.equal(session.stopping, false);
});
