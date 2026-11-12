import assert from "node:assert/strict";
import { test } from "node:test";
import { harness, signInNative, signIn, type NativeSession } from "./harness";
import { FakeTranscript, assistantMessage, connectHost, pairHost, userMessage } from "./account-support";

type Page = { frames: Array<{ sequence: number; frame: string }> };
class HTTPPeer {
  readonly connectionId = crypto.randomUUID();
  cursor = 0;
  readonly messages: Array<Record<string, any>> = [];
  constructor(readonly base: string, readonly session: NativeSession, readonly clientId = `watch-${crypto.randomUUID()}`) {}
  async request(action: string, extra: Record<string, unknown> = {}, headers = this.session.headers) {
    return fetch(new URL(`api/v1/account/client/http?clientId=${this.clientId}`, this.base), {
      method: "POST", headers: { ...headers, "Content-Type": "application/json" },
      body: JSON.stringify({ connectionId: this.connectionId, action, after: this.cursor, ...extra }),
    });
  }
  async exchange(action: string, extra: Record<string, unknown> = {}): Promise<Page> {
    const r = await this.request(action, extra);
    assert.equal(r.status, 200, await r.clone().text());
    const page = await r.json() as Page;
    for (const item of page.frames) {
      if (item.sequence <= this.cursor) continue;
      assert.equal(item.sequence, this.cursor + 1);
      this.cursor = item.sequence;
      this.messages.push(JSON.parse(item.frame));
    }
    return page;
  }
  async send(method: string, params: unknown, id?: number) {
    return this.exchange("send", { frame: JSON.stringify({ jsonrpc: "2.0", method, params, ...(id === undefined ? {} : { id }) }) });
  }
  async take(predicate: (m: Record<string, any>) => boolean): Promise<Record<string, any>> {
    for (let n = 0; n < 5; n++) {
      const index = this.messages.findIndex(predicate);
      if (index >= 0) return this.messages.splice(index, 1)[0]!;
      await this.exchange("poll");
    }
    throw new Error("Expected HTTP client message did not arrive");
  }
}

test("watch HTTPS transport lists hosts, sends a command, and receives live records without any client WebSocket", async t => {
  const h = await harness(); t.after(() => h.close());
  const session = await signInNative(h);
  const host = await pairHost(h, session);
  const daemon = await connectHost(h, session, host); t.after(() => daemon.close());
  const transcript = await FakeTranscript.create();
  await transcript.write(userMessage("first message"));
  await daemon.call("axo.host.sync", { hostId: host.hostId, hostGeneration: host.hostGeneration, round: 1, sessions: [transcript.manifestRow()] });
  await daemon.call("axo.host.session.append", { sessionId: transcript.sessionId, epoch: 1, from: 1, header: transcript.transcript.header, records: transcript.records(1) });

  const watch = new HTTPPeer(h.url, session);
  await watch.exchange("connect");
  await watch.send("axo.client.hello", { protocolVersion: 2, clientId: watch.clientId }, 1);
  const hello = await watch.take(m => m.id === 1);
  assert.equal(hello.result.hosts[0].hostId, host.hostId);
  assert.equal(hello.result.sessions[0].sessionId, transcript.sessionId);
  await watch.send("axo.client.session.open", { hostId: host.hostId, sessionId: transcript.sessionId, window: { last: 10 } }, 2);
  const opened = await watch.take(m => m.id === 2);
  assert.equal(opened.result.records[0].line, transcript.transcript.records[0]!.line);

  // An outstanding HTTPS poll wakes on a new host append, not just on a periodic full reload.
  const waiting = watch.exchange("poll");
  await transcript.write(assistantMessage("a streamed answer"));
  await daemon.call("axo.host.session.append", { sessionId: transcript.sessionId, epoch: 1, from: 2, records: transcript.records(2) });
  await waiting;
  const live = await watch.take(m => m.method === "axo.client.session.records");
  assert.equal(live.params.records[0].cursor, 2);
  assert.ok(live.params.records[0].line.includes("a streamed answer"));
  await watch.send("axo.client.session.ack", { sessionId: transcript.sessionId, cursor: 2 });

  const commandId = crypto.randomUUID();
  const forwarded = (async () => {
    for (;;) {
      const call = await daemon.next() as Record<string, any>;
      if (call.method !== "axo.remote.session.prompt") continue;
      assert.equal(call.params.text, "dictated on Watch");
      assert.equal(call.params.commandId, commandId);
      daemon.send({ jsonrpc: "2.0", id: call.id, result: { accepted: true } });
      return;
    }
  })();
  await watch.send("axo.client.command", { hostId: host.hostId, method: "axo.remote.session.prompt", params: {
    target: { hostId: host.hostId, hostGeneration: host.hostGeneration }, sessionId: transcript.sessionId,
    text: "dictated on Watch", commandId,
  } }, 3);
  await forwarded;
  assert.equal((await watch.take(m => m.id === 3)).result.accepted, true);
  await watch.exchange("close");
  assert.equal((await watch.request("poll")).status, 409);
});

test("HTTP client requests are authenticated, origin checked, replayable until acked, fenced on reconnect and revoked with the phone sign-in", async t => {
  const h = await harness(); t.after(() => h.close());
  const session = await signInNative(h);
  const watch = new HTTPPeer(h.url, session);
  assert.equal((await watch.request("connect", {}, {})).status, 401);
  const cookie = await signIn(h);
  assert.equal((await watch.request("connect", {}, { ...cookie.headers, Origin: "https://evil.test" })).status, 403);
  await watch.exchange("connect");
  const frame = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "axo.client.hello", params: { protocolVersion: 2, clientId: watch.clientId } });
  const response = await watch.request("send", { frame });
  assert.equal(response.status, 200);
  const first = await response.json() as Page;
  assert.ok(first.frames.length);
  const replay = await watch.request("poll");
  assert.deepEqual(await replay.json(), first, "a lost response can be redelivered until its sequence is acknowledged");
  const stranger = await signInNative(h);
  assert.equal((await watch.request("poll", {}, stranger.headers)).status, 409, "a different account has a different DO and no connection");
  assert.equal((await watch.request("send", { frame: "x".repeat(210_000) })).status, 400);

  watch.cursor = first.frames.at(-1)!.sequence;
  const oldPoll = watch.request("poll");
  await new Promise(resolve => setTimeout(resolve, 30));
  const replacement = new HTTPPeer(h.url, session, watch.clientId);
  await replacement.exchange("connect");
  assert.equal((await oldPoll).status, 409, "a replaced long poll must not clear its successor");
  assert.equal((await watch.request("send", { frame })).status, 409, "an old connection cannot write into its replacement");
  await replacement.send("axo.client.hello", { protocolVersion: 2, clientId: replacement.clientId }, 1);
  assert.ok((await replacement.take(m => m.id === 1)).result);
  const signedOut = await fetch(new URL("api/auth/logout", h.url), { method: "POST", headers: session.headers });
  assert.equal(signedOut.status, 204);
  assert.equal((await replacement.request("poll")).status, 401, "every HTTP request checks current authorization");
});
