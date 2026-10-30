import assert from "node:assert/strict";
import { test } from "node:test";
import { harness } from "./harness";

type EventRecord = {
  id: number;
  hostGeneration: string;
  piSessionId: string;
  streamId: string;
  sequence: number;
  name: string;
  data: unknown;
  receivedAt: number;
};
type AppendResult = { ok: true; eventId: number; inserted: boolean } | { ok: false; reason: "invalid" | "identityConflict" | "eventConflict" };
type ListResult = { ok: true; events: EventRecord[]; next: number | null } | { ok: false; reason: "invalid" | "identityConflict" };
type SessionHistoryStub = {
  append(input: unknown): Promise<AppendResult>;
  list(input: unknown): Promise<ListResult>;
};
type SessionHistoryNamespace = { getByName(name: string): SessionHistoryStub };

const accountId = "b0f7c9aa-9c09-49f5-9a2c-73c09b313f5b";
const hostId = "5b7cc2d0-4e6c-4693-9d2a-9d96a01bdc11";
const hostGeneration = "981d46f8-5a6c-4b22-a789-f90d981beb4d";
const piSessionId = "pi-session-1";
const streamId = "6fba62a2-e8e8-4d86-9188-7cc63dcab7a1";
const sessionId = "0000002a-0000-4000-8000-00000000002a";
const otherSessionId = "0000002b-0000-4000-8000-00000000002b";

function event(sequence: number, data: unknown = { role: "assistant", text: `message ${sequence}` }) {
  return { accountId, hostId, hostGeneration, sessionId, piSessionId, streamId, sequence, name: "message.end", data };
}

function sessionDOName(account: string, host: string, session: string): string {
  return `${account}:${host}:${session}`;
}

function plain<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

function eventPage(value: ListResult): { events: EventRecord[]; next: number | null } {
  if (value.ok) return { events: value.events, next: value.next };
  throw new Error(`Unexpected history response: ${value.reason}`);
}

async function sessionHistoryNamespace(api: Awaited<ReturnType<typeof harness>>) {
  return await api.mf.getDurableObjectNamespace("TEST_SESSION_HISTORY") as unknown as SessionHistoryNamespace;
}

test("a per-Session Durable Object stores full Pi events idempotently and pages newest first by durable cursor", async () => {
  const api = await harness();
  try {
    const namespace = await sessionHistoryNamespace(api);
    const history = namespace.getByName(sessionDOName(accountId, hostId, sessionId));
    const first = plain(await history.append(event(1, { prompt: "private input", image: { data: "full" } })));
    const duplicate = plain(await history.append(event(1, { prompt: "private input", image: { data: "full" } })));
    const second = plain(await history.append(event(2, { role: "assistant", thinking: "retained verbatim" })));

    assert.deepEqual(first, { ok: true, eventId: 1, inserted: true });
    assert.deepEqual(duplicate, { ok: true, eventId: 1, inserted: false });
    assert.deepEqual(plain(await history.append(event(1, { prompt: "different payload" }))), { ok: false, reason: "eventConflict" });
    assert.deepEqual(second, { ok: true, eventId: 2, inserted: true });

    const firstPage = eventPage(plain(await history.list({ accountId, hostId, sessionId, before: 0, limit: 1 })));
    assert.equal(firstPage.events.length, 1);
    assert.deepEqual(firstPage.events[0].data, { role: "assistant", thinking: "retained verbatim" });
    assert.equal(firstPage.next, firstPage.events[0].id);

    const secondPage = eventPage(plain(await history.list({ accountId, hostId, sessionId, before: firstPage.next, limit: 1 })));
    assert.equal(secondPage.events.length, 1);
    assert.deepEqual(secondPage.events[0].data, { prompt: "private input", image: { data: "full" } });
    assert.equal(secondPage.next, null);
  } finally {
    await api.close();
  }
});

test("event identity is fenced to the owning account, host, and Session", async () => {
  const api = await harness();
  try {
    const namespace = await sessionHistoryNamespace(api);
    const history = namespace.getByName(sessionDOName(accountId, hostId, sessionId));
    await history.append(event(1));

    assert.deepEqual(plain(await history.append({ ...event(2), hostId: "d48d1fb1-5a6c-4400-8a1a-97453f12247c" })), { ok: false, reason: "identityConflict" });
    assert.deepEqual(plain(await history.list({ accountId, hostId, sessionId: otherSessionId, before: 0, limit: 20 })), { ok: false, reason: "identityConflict" });
    assert.deepEqual(plain(await history.append({ ...event(2), accountId: "d48d1fb1-5a6c-4400-8a1a-97453f12247c" })), { ok: false, reason: "identityConflict" });
  } finally {
    await api.close();
  }
});

test("history survives Worker restart with no automatic expiry", async () => {
  const api = await harness();
  const name = sessionDOName(accountId, hostId, sessionId);
  try {
    const namespace = await sessionHistoryNamespace(api);
    await namespace.getByName(name).append(event(1, { role: "toolResult", content: "retained" }));
    await api.restart();

    const restarted = await sessionHistoryNamespace(api);
    const page = eventPage(plain(await restarted.getByName(name).list({ accountId, hostId, sessionId, before: 0, limit: 20 })));
    assert.equal(page.events.length, 1);
    assert.deepEqual(page.events[0].data, { role: "toolResult", content: "retained" });
    assert.ok(page.events[0].receivedAt > 0);

    const otherSession = plain(await restarted.getByName(sessionDOName(accountId, hostId, otherSessionId))
      .list({ accountId, hostId, sessionId: otherSessionId, before: 0, limit: 20 }));
    assert.deepEqual(otherSession, { ok: true, events: [], next: null });
  } finally {
    await api.close();
  }
});

test("Pi event payloads are bounded JSON, but event contents are not redacted", async () => {
  const api = await harness();
  try {
    const namespace = await sessionHistoryNamespace(api);
    const history = namespace.getByName(sessionDOName(accountId, hostId, sessionId));
    const secretLikeContent = { tool: { input: "private file contents" }, tokenText: "unfiltered" };
    await history.append(event(1, secretLikeContent));
    const page = eventPage(plain(await history.list({ accountId, hostId, sessionId, before: 0, limit: 20 })));
    assert.deepEqual(page.events[0].data, secretLikeContent);
    assert.deepEqual(plain(await history.append(event(2, { text: "x".repeat(60_001) }))), { ok: false, reason: "invalid" });
  } finally {
    await api.close();
  }
});
