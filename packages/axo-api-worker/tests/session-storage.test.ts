import assert from "node:assert/strict";
import { resolve } from "node:path";
import { test } from "node:test";
import { Pi3Transcript, type AppendParams } from "@axo/protocol";
import type { ReadRequest, ReadResult, SessionBinding, StorageStatus, StoreAppendResult, StoreTruncateResult } from "../src/session-store";
import { bucketSource, generationPrefix, restoreEpoch, segmentName, type RestoredEpoch } from "../src/session-storage";
import type { SegmentFaults } from "./fixtures/faulty-segments";
import { harness, root, type Harness } from "./harness";

/**
 * RFD0044, release 1 (Store): a SessionDO stores its records in R2 as write-once ATXF segments,
 * reads each one back, and keeps every line. Driven through its RPC methods under Miniflare, with
 * synthetic transcripts and an R2 that fails when a test asks.
 */

const FAULTY = resolve(root, "packages/axo-api-worker/tests/fixtures/faulty-segments.ts");

type RawStub = {
  append(binding: SessionBinding, params: AppendParams, fence: number): Promise<StoreAppendResult>;
  truncate(binding: SessionBinding, keep: number, chain: string, fence: number): Promise<StoreTruncateResult>;
  read(binding: SessionBinding, request: ReadRequest): Promise<ReadResult>;
  armStorage(binding: SessionBinding): Promise<StorageStatus>;
  storage(binding: SessionBinding): Promise<StorageStatus>;
  injectFaults?(faults: Partial<SegmentFaults>): Promise<void>;
};

const plain = <T>(value: T): T => {
  const copy = JSON.parse(JSON.stringify(value)) as T;
  (value as Partial<Disposable> | undefined)?.[Symbol.dispose]?.();
  return copy;
};

type Session = {
  binding: SessionBinding;
  append(params: AppendParams): Promise<StoreAppendResult>;
  truncate(keep: number, chain: string): Promise<StoreTruncateResult>;
  read(request: ReadRequest): Promise<ReadResult>;
  arm(): Promise<StorageStatus>;
  status(): Promise<StorageStatus>;
  faults(faults: Partial<SegmentFaults>): Promise<void>;
};

const newBinding = (): SessionBinding => ({ accountId: crypto.randomUUID(), hostId: crypto.randomUUID(), sessionId: crypto.randomUUID() });

/** The SessionDO for `binding`; `name` stands for another object of the same Session (one rebuilt after losing its storage). */
async function session(h: Harness, binding: SessionBinding = newBinding(), name = `${binding.accountId}:${binding.hostId}:${binding.sessionId}`): Promise<Session> {
  const namespace = (await h.mf.getDurableObjectNamespace("TEST_SESSION_HISTORY")) as unknown as { idFromName(name: string): unknown; get(id: unknown): RawStub };
  const raw = namespace.get(namespace.idFromName(name));
  return {
    binding,
    append: async (p) => plain(await raw.append(binding, p, 0)),
    truncate: async (k, c) => plain(await raw.truncate(binding, k, c, 0)),
    read: async (r) => plain(await raw.read(binding, r)),
    arm: async () => plain(await raw.armStorage(binding)),
    status: async () => plain(await raw.storage(binding)),
    faults: async (f) => {
      await raw.injectFaults!(f);
    },
  };
}

const header = (sessionId: string) => JSON.stringify({ type: "session", version: 3, id: sessionId, timestamp: "2026-11-08T10:00:00.000Z", cwd: "/w" });

/** Synthetic Pi lines: messages, a tool call and its result, settings, a label, a compaction. */
function piLines(count: number, prefix = "e", parentOfFirst: string | null = null): string[] {
  const lines: string[] = [];
  let parent = parentOfFirst;
  for (let n = 0; lines.length < count; n++) {
    const id = `${prefix}${n}`;
    const kind = n % 6;
    let entry: Record<string, unknown>;
    if (kind === 0) entry = { type: "message", message: { role: "user", content: [{ type: "text", text: `question ${n} ünïcødé 🦀` }], timestamp: n } };
    else if (kind === 1) entry = { type: "message", message: { role: "assistant", content: [{ type: "toolCall", id: `call-${n}`, name: "bash", arguments: { command: "ls" } }], provider: "anthropic", model: "claude", stopReason: "toolUse", timestamp: n } };
    else if (kind === 2) entry = { type: "message", message: { role: "toolResult", toolCallId: `call-${n - 1}`, toolName: "bash", content: [{ type: "text", text: `file-${n}.txt` }], isError: false, timestamp: n } };
    else if (kind === 3) entry = { type: "model_change", provider: "anthropic", modelId: "claude-opus" };
    else if (kind === 4) entry = { type: "label", targetId: parent, label: `mark ${n}` };
    else entry = { type: "compaction", summary: `so far ${n}`, firstKeptEntryId: parent, tokensBefore: 1000 };
    lines.push(JSON.stringify({ type: entry.type, id, parentId: parent, timestamp: "2026-11-08T10:00:00.000Z", ...entry }));
    if (entry.type !== "label") parent = id;
  }
  return lines;
}

/** A host's file, hashed as axod hashes it, uploaded in batches of 64 as axod does. */
async function file(binding: SessionBinding, lines: string[]): Promise<Pi3Transcript> {
  const transcript = await Pi3Transcript.start(header(binding.sessionId));
  for (const line of lines) assert.ok(await transcript.push(line));
  return transcript;
}

async function upload(s: Session, transcript: Pi3Transcript, from: number, epoch = 1): Promise<void> {
  for (let start = from; start <= transcript.count; start += 64) {
    const records = transcript.records.slice(start - 1, start - 1 + 64).map(({ id, line, hash }) => ({ id, line, hash }));
    const result = await s.append({ sessionId: s.binding.sessionId, epoch, from: start, header: start === 1 ? transcript.header : undefined, records });
    assert.equal(result.outcome, "committed", JSON.stringify(result));
  }
}

async function until(s: Session, done: (status: StorageStatus) => boolean, what: string, ms = 30_000): Promise<StorageStatus> {
  const deadline = Date.now() + ms;
  for (;;) {
    const status = await s.status();
    if (done(status)) return status;
    if (Date.now() > deadline) assert.fail(`${what}: ${JSON.stringify(status)}`);
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

/** R2 gave back every record the SessionDO could store, and nothing waits. */
const settled = (status: StorageStatus) => status.pending === null && status.dueAt === null && status.epochs.every((e) => e.verified >= e.translated && (e.last <= e.keep || e.headerSaved));

const bucket = async (h: Harness) => (await h.mf.getR2Bucket("SESSIONS")) as unknown as R2Bucket;

const sorted = (keys: string[]) => [...keys].sort();

async function keys(h: Harness, prefix: string): Promise<string[]> {
  return (await bucketSource(await bucket(h)).list(prefix)).map((key) => key.slice(prefix.length)).sort();
}

async function restored(h: Harness, s: Session, generation: string, epoch: number): Promise<RestoredEpoch> {
  return restoreEpoch(bucketSource(await bucket(h)), generationPrefix(s.binding, generation), epoch);
}

function sameAs(restore: RestoredEpoch, transcript: Pi3Transcript): void {
  assert.equal(restore.header, transcript.header);
  assert.equal(restore.records.length, transcript.count);
  assert.deepEqual(restore.records, transcript.records.map(({ id, line, hash }) => ({ id, line, hash })));
  assert.equal(restore.chain, transcript.chain);
}

async function lines(s: Session): Promise<string[]> {
  const got: string[] = [];
  for (;;) {
    const read = await s.read({ epoch: null, after: got.length, limit: 256 });
    if (read.kind !== "records" || read.records.length === 0) return got;
    got.push(...read.records.map((record) => record.line));
  }
}

test("without the SESSIONS bucket, a SessionDO arms nothing and stores nothing", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const s = await session(h);
  const transcript = await file(s.binding, piLines(10));
  await upload(s, transcript, 1);
  const status = await s.arm();
  assert.equal(status.enabled, false);
  assert.equal(status.dueAt, null);
  assert.equal(status.stored, 0);
  // A cut keeps what it deletes, for R2 to take once a bucket is bound; nothing is armed.
  assert.equal((await s.truncate(4, transcript.chainAt(4)!)).outcome, "truncated");
  const cut = await s.status();
  assert.equal(cut.cutRecords, 6);
  assert.equal(cut.dueAt, null);
  assert.equal(cut.count, 4);
  assert.deepEqual(cut.epochs.map((e) => [e.epoch, e.keep, e.last]), [[1, 0, 10], [2, 4, 4]]);
});

test("a commit arms storing for an hour later; R2 gets one header and one segment, read back equal, and every line stays", async (t) => {
  const h = await harness({ r2: ["SESSIONS"] });
  t.after(() => h.close());
  const s = await session(h);
  const transcript = await file(s.binding, piLines(150));
  const before = Date.now();
  await upload(s, transcript, 1);

  const armed = await s.status();
  assert.ok(armed.dueAt !== null && armed.dueAt >= before + 59 * 60_000, `due an hour after the first commit: ${armed.dueAt}`);
  assert.equal(armed.stored, 0);

  await s.arm();
  const status = await until(s, settled, "stored");
  assert.equal(status.stored, 150);
  assert.equal(status.count, 150);
  assert.equal(status.refused, null);
  assert.deepEqual(await keys(h, generationPrefix(s.binding, status.generation)), sorted(["epoch-1/header.json", segmentName(1, 1, 150)]));
  sameAs(await restored(h, s, status.generation, 1), transcript);
  // Release 1 keeps every line in the SessionDO.
  assert.deepEqual(await lines(s), transcript.records.map((record) => record.line));

  // New records go in a segment of their own, after the first.
  const more = await file(s.binding, [...piLines(150), ...piLines(10, "x", "e149")]);
  await upload(s, more, 151);
  await s.arm();
  const after = await until(s, (st) => settled(st) && st.stored === 160, "stored the tail");
  assert.deepEqual(await keys(h, generationPrefix(s.binding, after.generation)), sorted(["epoch-1/header.json", segmentName(1, 1, 150), segmentName(1, 151, 160)]));
  sameAs(await restored(h, s, after.generation, 1), more);
});

test("a backlog of 5,000 records is stored in segments of at most 2,048, oldest first", async (t) => {
  const h = await harness({ r2: ["SESSIONS"] });
  t.after(() => h.close());
  const s = await session(h);
  const transcript = await file(s.binding, piLines(5000));
  await upload(s, transcript, 1);
  await s.arm();
  const status = await until(s, (st) => settled(st) && st.stored === 5000, "stored the backlog", 120_000);
  assert.deepEqual(await keys(h, generationPrefix(s.binding, status.generation)), sorted([
    "epoch-1/header.json", segmentName(1, 1, 2048), segmentName(1, 2049, 4096), segmentName(1, 4097, 5000),
  ]));
  sameAs(await restored(h, s, status.generation, 1), transcript);
});

test("offline, R2 calls fail and back off; back online, the retry stores the same keys", async (t) => {
  const h = await harness({ r2: ["SESSIONS"], entry: FAULTY });
  t.after(() => h.close());
  const s = await session(h);
  const transcript = await file(s.binding, piLines(40));
  await upload(s, transcript, 1);
  await s.faults({ offline: true });
  await s.arm();
  const failed = await until(s, (st) => st.failures >= 1, "a failure recorded");
  assert.ok(failed.dueAt !== null && failed.dueAt > Date.now() + 60_000, "backs off for minutes");
  assert.equal(failed.stored, 0);
  assert.deepEqual(await keys(h, generationPrefix(s.binding, failed.generation)), []);

  // Still offline: the next try fails too, and waits longer.
  await s.arm();
  const twice = await until(s, (st) => st.failures >= 2, "a second failure");
  assert.ok(twice.dueAt! > Date.now() + 3 * 60_000);
  // The host keeps writing while R2 is away; nothing is lost.
  const more = await file(s.binding, [...piLines(40), ...piLines(5, "x", "e39")]);
  await upload(s, more, 41);

  await s.faults({ offline: false });
  await s.arm();
  const status = await until(s, (st) => settled(st) && st.stored === 45, "stored once back online");
  assert.equal(status.failures, 0);
  const stored = await keys(h, generationPrefix(s.binding, status.generation));
  assert.ok(stored.includes("epoch-1/header.json"));
  assert.ok(stored.every((key) => key.startsWith("epoch-1/")));
  sameAs(await restored(h, s, status.generation, 1), more);
});

test("a PUT whose answer was lost is retried with the same range, finds the same bytes, and moves on", async (t) => {
  const h = await harness({ r2: ["SESSIONS"], entry: FAULTY });
  t.after(() => h.close());
  const s = await session(h);
  const transcript = await file(s.binding, piLines(20));
  await upload(s, transcript, 1);
  // The header's PUT lands; its answer is lost.
  await s.faults({ loseAnswer: 1 });
  await s.arm();
  const lost = await until(s, (st) => st.failures === 1, "the lost answer counted as a failure");
  assert.deepEqual(lost.pending, { kind: "header", epoch: 1, from: null, to: null, stored: 0 });
  // More lines come before the retry: the pending header is sent again, as it was.
  const more = await file(s.binding, [...piLines(20), ...piLines(3, "x", "e19")]);
  await upload(s, more, 21);
  await s.arm();
  const status = await until(s, (st) => settled(st) && st.stored === 23, "stored after the retry");
  assert.equal(status.refused, null);
  sameAs(await restored(h, s, status.generation, 1), more);
});

test("a segment R2 gives back with other bytes stops storing for the Session, and nothing is counted as given back", async (t) => {
  const h = await harness({ r2: ["SESSIONS"], entry: FAULTY });
  t.after(() => h.close());
  const s = await session(h);
  const transcript = await file(s.binding, piLines(12));
  await upload(s, transcript, 1);
  // The header goes through; the segment's PUT stores other bytes.
  await s.faults({ corruptPut: 1 });
  await s.arm();
  const status = await until(s, (st) => st.refused !== null, "refused");
  assert.match(status.refused!, /came back with other (bytes|lines)/);
  assert.equal(status.stored, 0);
  assert.equal(status.dueAt, null);
  assert.deepEqual(await lines(s), transcript.records.map((record) => record.line));
  // Arming again changes nothing: a refused Session waits for a person.
  assert.equal((await s.arm()).dueAt, null);
});

test("a cut before R2 has the lines keeps them; both epochs restore from R2 alone", async (t) => {
  const h = await harness({ r2: ["SESSIONS"] });
  t.after(() => h.close());
  const s = await session(h);
  const first = await file(s.binding, piLines(40));
  await upload(s, first, 1);

  // The host rewrote its file after record 25 before anything reached R2.
  const cut = await s.truncate(25, first.chainAt(25)!);
  assert.equal(cut.outcome, "truncated");
  const kept = await s.status();
  assert.equal(kept.cutRecords, 15, "every record the cut deleted is kept aside; the 25 it kept stay where they are");
  const second = await file(s.binding, [...piLines(40).slice(0, 25), ...piLines(30, "b", "e24")]);
  await upload(s, second, 26, 2);

  await s.arm();
  const status = await until(s, (st) => settled(st) && st.stored === 55, "both epochs stored");
  assert.equal(status.cutRecords, 0, "the side table empties once R2 gave its records back");
  assert.deepEqual(await keys(h, generationPrefix(s.binding, status.generation)), sorted([
    "epoch-1/header.json", segmentName(1, 1, 40), "epoch-2/header.json", segmentName(2, 26, 55),
  ]));
  sameAs(await restored(h, s, status.generation, 1), first);
  sameAs(await restored(h, s, status.generation, 2), second);
});

test("a cut between a segment's store and its read-back keeps the lines until R2 gives them back", async (t) => {
  const h = await harness({ r2: ["SESSIONS"], entry: FAULTY });
  t.after(() => h.close());
  const s = await session(h);
  const first = await file(s.binding, piLines(30));
  await upload(s, first, 1);
  // The header goes through; the segment's PUT lands, and its read-back fails.
  await s.faults({ failGet: 1 });
  await s.arm();
  const between = await until(s, (st) => st.pending?.stored === 1 && st.failures === 1, "stored, not read back");
  assert.equal(between.stored, 0);

  const cut = await s.truncate(10, first.chainAt(10)!);
  assert.equal(cut.outcome, "truncated");
  assert.equal((await s.status()).cutRecords, 20);
  const second = await file(s.binding, [...piLines(30).slice(0, 10), ...piLines(5, "b", "e9")]);
  await upload(s, second, 11, 2);

  await s.arm();
  const status = await until(s, (st) => settled(st) && st.stored === 15, "both epochs stored");
  assert.equal(status.cutRecords, 0);
  sameAs(await restored(h, s, status.generation, 1), first);
  sameAs(await restored(h, s, status.generation, 2), second);
});

test("a SessionDO that lost its storage is rebuilt exactly from R2, and writes under a new generation beside the old", async (t) => {
  const h = await harness({ r2: ["SESSIONS"] });
  t.after(() => h.close());
  const binding = newBinding();
  const lostObject = await session(h, binding);
  const transcript = await file(binding, piLines(300));
  await upload(lostObject, transcript, 1);
  await lostObject.arm();
  const old = await until(lostObject, (st) => settled(st) && st.stored === 300, "stored");
  const oldPrefix = generationPrefix(binding, old.generation);
  const oldObjects = await Promise.all((await keys(h, oldPrefix)).map(async (key) => [key, await (await (await bucket(h)).get(oldPrefix + key))!.text()]));

  // A new object stands for the wiped one: it holds nothing, and R2 alone rebuilds it.
  const rebuilt = await session(h, binding, `wiped:${crypto.randomUUID()}`);
  assert.equal((await rebuilt.status()).count, 0);
  const restore = await restored(h, lostObject, old.generation, 1);
  sameAs(restore, transcript);
  for (let start = 1; start <= restore.records.length; start += 64) {
    const result = await rebuilt.append({ sessionId: binding.sessionId, epoch: 1, from: start, header: start === 1 ? restore.header : undefined, records: restore.records.slice(start - 1, start + 63) });
    assert.equal(result.outcome, "committed");
    if (start + 63 >= restore.records.length) assert.equal(result.outcome === "committed" && result.chain, transcript.chain);
  }
  assert.deepEqual(await lines(rebuilt), transcript.records.map((record) => record.line));

  await rebuilt.arm();
  const fresh = await until(rebuilt, (st) => settled(st) && st.stored === 300, "the rebuilt object stored");
  assert.notEqual(fresh.generation, old.generation);
  // The old generation is untouched, byte for byte.
  for (const [key, text] of oldObjects) assert.equal(await (await (await bucket(h)).get(oldPrefix + key!))!.text(), text);
  sameAs(await restored(h, rebuilt, fresh.generation, 1), transcript);
});

test("keys come from the object's own binding: one account's listing never holds another's Session", async (t) => {
  const h = await harness({ r2: ["SESSIONS"] });
  t.after(() => h.close());
  const a = await session(h);
  const b = await session(h);
  await upload(a, await file(a.binding, piLines(5)), 1);
  await upload(b, await file(b.binding, piLines(5)), 1);
  await a.arm();
  await b.arm();
  await until(a, settled, "a stored");
  await until(b, settled, "b stored");
  const all = await bucketSource(await bucket(h)).list(`accounts/${a.binding.accountId}/`);
  assert.ok(all.length > 0);
  assert.ok(all.every((key) => key.startsWith(`accounts/${a.binding.accountId}/hosts/${a.binding.hostId}/sessions/${a.binding.sessionId}/`)));
  // A binding that is not the object's is refused before anything is read.
  await assert.rejects(session(h, { ...b.binding, sessionId: a.binding.sessionId }, `${a.binding.accountId}:${a.binding.hostId}:${a.binding.sessionId}`).then((other) => other.status()));
  assert.throws(() => generationPrefix({ ...a.binding, accountId: "../other" }, crypto.randomUUID()));
});

test("a restore refuses a gap, a changed line and a header that is not its line", async (t) => {
  const h = await harness({ r2: ["SESSIONS"] });
  t.after(() => h.close());
  const s = await session(h);
  const transcript = await file(s.binding, piLines(70));
  await upload(s, transcript, 1);
  await s.arm();
  const status = await until(s, (st) => settled(st) && st.stored === 70, "stored");
  const r2 = await bucket(h);
  const prefix = generationPrefix(s.binding, status.generation);
  const source = bucketSource(r2);
  const objects = new Map<string, { text: string; meta: Record<string, string> }>();
  for (const key of await source.list(prefix)) objects.set(key, (await source.get(key))!);
  const tampered = (change: (objects: Map<string, { text: string; meta: Record<string, string> }>) => void) => {
    const copy = new Map([...objects].map(([key, value]) => [key, { ...value }]));
    change(copy);
    return { list: async () => [...copy.keys()], get: async (key: string) => copy.get(key) ?? null };
  };
  const segment = prefix + segmentName(1, 1, 70);
  await assert.rejects(restoreEpoch(tampered((o) => {
    const text = o.get(segment)!.text;
    o.delete(segment);
    o.set(prefix + segmentName(1, 2, 71), { text, meta: o.get(prefix + "epoch-1/header.json")!.meta });
  }), prefix, 1), /does not follow/);
  await assert.rejects(restoreEpoch(tampered((o) => {
    o.get(segment)!.text = o.get(segment)!.text.replaceAll("question 6 ", "question 7 ");
  }), prefix, 1), /chain/);
  await assert.rejects(restoreEpoch(tampered((o) => {
    const h = o.get(prefix + "epoch-1/header.json")!;
    h.text = h.text.replace('\\"cwd\\":\\"/w\\"', '\\"cwd\\":\\"/x\\"');
  }), prefix, 1), /headerHash/);
});

test("a cut below an earlier cut keeps each deleted record for the epoch that stores it, and all three epochs restore", async (t) => {
  const h = await harness({ r2: ["SESSIONS"] });
  t.after(() => h.close());
  const s = await session(h);
  const first = await file(s.binding, piLines(40));
  await upload(s, first, 1);
  assert.equal((await s.truncate(25, first.chainAt(25)!)).outcome, "truncated");
  const second = await file(s.binding, [...piLines(40).slice(0, 25), ...piLines(10, "b", "e24")]);
  await upload(s, second, 26, 2);
  // Below the first cut: records 11-25 belong to epoch 1, 26-35 to epoch 2.
  assert.equal((await s.truncate(10, second.chainAt(10)!)).outcome, "truncated");
  assert.equal((await s.status()).cutRecords, 15 + 15 + 10);
  const third = await file(s.binding, [...piLines(40).slice(0, 10), ...piLines(5, "c", "e9")]);
  await upload(s, third, 11, 3);

  await s.arm();
  const status = await until(s, (st) => settled(st) && st.stored === 15, "all three epochs stored");
  assert.equal(status.cutRecords, 0);
  sameAs(await restored(h, s, status.generation, 1), first);
  sameAs(await restored(h, s, status.generation, 2), second);
  sameAs(await restored(h, s, status.generation, 3), third);
});

test("a cut that would keep more than the limit is refused and deletes nothing", async (t) => {
  const h = await harness({ entry: FAULTY });
  t.after(() => h.close());
  const s = await session(h);
  const transcript = await file(s.binding, piLines(20));
  await upload(s, transcript, 1);
  const bytes = transcript.records.slice(10).reduce((total, record) => total + new TextEncoder().encode(record.line).byteLength, 0);
  await s.faults({ cutLimit: bytes - 1 });
  await assert.rejects(s.truncate(10, transcript.chainAt(10)!));
  const refused = await s.status();
  assert.equal(refused.count, 20);
  assert.equal(refused.epoch, 1);
  assert.equal(refused.cutRecords, 0);
  assert.deepEqual(await lines(s), transcript.records.map((record) => record.line));
  // At the limit exactly, it goes.
  await s.faults({ cutLimit: bytes });
  assert.equal((await s.truncate(10, transcript.chainAt(10)!)).outcome, "truncated");
  assert.equal((await s.status()).cutRecords, 10);
});
