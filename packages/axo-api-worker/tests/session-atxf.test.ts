import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { Pi3Transcript, type AppendParams, type ClientRecord } from "@axo/protocol";
import { addIntegrity, canonicalJson, verifyIntegrity, type Transcript } from "@leostera/atxf";
import { pi } from "@leostera/atxf/pi";
import type { AtxfRead, ReadRequest, ReadResult, SessionBinding, StoreAppendResult, StoreTruncateResult } from "../src/session-store";
import { harness, type Harness } from "./harness";
import { objectRows } from "./storage";

/**
 * RFD0035: the SessionDO keeps each Pi line's ATXF record beside it, and never changes the line.
 * Driven through its RPC methods under Miniflare, alarms included.
 */

type Stub = {
  append(binding: SessionBinding, params: AppendParams): Promise<StoreAppendResult>;
  truncate(binding: SessionBinding, keep: number, chain: string): Promise<StoreTruncateResult>;
  read(binding: SessionBinding, request: ReadRequest): Promise<ReadResult>;
  atxf(binding: SessionBinding, from?: number, limit?: number): Promise<AtxfRead>;
};

/** Miniflare hands RPC results back as proxies; tests compare plain values, and dispose of the proxy. */
const plain = <T>(value: T): T => {
  const copy = JSON.parse(JSON.stringify(value)) as T;
  (value as Partial<Disposable> | undefined)?.[Symbol.dispose]?.();
  return copy;
};

async function sessionObject(h: Harness, binding: SessionBinding = { accountId: crypto.randomUUID(), hostId: crypto.randomUUID(), sessionId: crypto.randomUUID() }): Promise<{ stub: Stub; binding: SessionBinding }> {
  const namespace = (await h.mf.getDurableObjectNamespace("TEST_SESSION_HISTORY")) as unknown as { idFromName(name: string): unknown; get(id: unknown): Stub };
  const raw = namespace.get(namespace.idFromName(`${binding.accountId}:${binding.hostId}:${binding.sessionId}`));
  const stub: Stub = {
    append: async (b, p) => plain(await raw.append(b, p)),
    truncate: async (b, k, c) => plain(await raw.truncate(b, k, c)),
    read: async (b, r) => plain(await raw.read(b, r)),
    atxf: async (b, f, l) => plain(await raw.atxf(b, f, l)),
  };
  return { stub, binding };
}

const header = (sessionId: string) => JSON.stringify({ type: "session", version: 3, id: sessionId, timestamp: "2026-11-08T10:00:00.000Z", cwd: "/w" });

/** A Pi session of most entry kinds: messages, a tool call and its result, settings, a label, a branch, a compaction. */
function piLines(count: number, prefix = "e"): string[] {
  const lines: string[] = [];
  let parent: string | null = null;
  const at = (n: number) => `2026-11-08T10:${String(Math.floor(n / 60) % 60).padStart(2, "0")}:${String(n % 60).padStart(2, "0")}.000Z`;
  for (let n = 0; lines.length < count; n++) {
    const id = `${prefix}${n}`;
    const kind = n % 7;
    let entry: Record<string, unknown>;
    if (kind === 0) entry = { type: "message", message: { role: "user", content: [{ type: "text", text: `question ${n}` }], timestamp: n } };
    else if (kind === 1) entry = { type: "message", message: { role: "assistant", content: [{ type: "text", text: `let me look ${n}` }, { type: "toolCall", id: `call-${n}`, name: "bash", arguments: { command: "ls" } }], provider: "anthropic", model: "claude", usage: { input: 10, output: 5, cacheRead: 0, cacheWrite: 0, totalTokens: 15, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "toolUse", timestamp: n } };
    else if (kind === 2) entry = { type: "message", message: { role: "toolResult", toolCallId: `call-${n - 1}`, toolName: "bash", content: [{ type: "text", text: `file-${n}.txt` }], isError: false, timestamp: n } };
    else if (kind === 3) entry = { type: "model_change", provider: "anthropic", modelId: "claude-opus" };
    else if (kind === 4) entry = { type: "label", targetId: parent, label: `mark ${n}` };
    else if (kind === 5) entry = { type: "thinking_level_change", thinkingLevel: "high" };
    else entry = { type: "compaction", summary: `so far ${n}`, firstKeptEntryId: parent, tokensBefore: 1000 };
    const line = JSON.stringify({ type: entry.type, id, parentId: parent, timestamp: at(n), ...entry });
    lines.push(line);
    if (entry.type !== "label") parent = id;
  }
  return lines;
}

/** What the cloud should hold: the stream's records for the file, as toAtxf reads them, without the file's digest. */
function expected(file: string): Transcript {
  const whole = pi.toAtxf(file, { integrity: false });
  const { nativeDigest: _, ...fidelity } = whole.header.fidelity ?? {};
  return addIntegrity({ header: { ...whole.header, fidelity }, records: whole.records });
}

class Uploader {
  readonly transcript: Pi3Transcript;
  readonly headerLine: string;
  private constructor(transcript: Pi3Transcript, headerLine: string) {
    this.transcript = transcript;
    this.headerLine = headerLine;
  }
  static async start(sessionId: string, headerLine = header(sessionId)) {
    return new Uploader(await Pi3Transcript.start(headerLine), headerLine);
  }
  async push(lines: string[]) {
    for (const line of lines) assert.ok(await this.transcript.push(line), `pi/3 refused ${line.slice(0, 80)}`);
  }
  /** Appends records `from`.. in batches of 64, as axod does. */
  async upload(stub: Stub, binding: SessionBinding, from: number, epoch = 1) {
    for (let start = from; start <= this.transcript.count; start += 64) {
      const records = this.transcript.records.slice(start - 1, start - 1 + 64).map(({ id, line, hash }) => ({ id, line, hash }));
      const result = await stub.append(binding, { sessionId: binding.sessionId, epoch, from: start, header: start === 1 ? this.headerLine : undefined, records });
      assert.equal(result.outcome, "committed", JSON.stringify(result));
    }
  }
  file(): string {
    return [this.headerLine, ...this.transcript.records.map((record) => record.line)].map((line) => `${line}\n`).join("");
  }
}

/** The ATXF once translation has caught up with every stored record. */
async function caughtUp(stub: Stub, binding: SessionBinding): Promise<Transcript & { read: AtxfRead }> {
  const deadline = Date.now() + 20_000;
  for (;;) {
    const head = await stub.atxf(binding, 1, 0);
    if (head.error !== null) assert.fail(`translation stopped: ${head.error}`);
    if (head.through === head.count) break;
    if (Date.now() > deadline) assert.fail(`translation stuck at ${head.through} of ${head.count}`);
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const records = [];
  let read: AtxfRead;
  do {
    read = await stub.atxf(binding, records.length + 1, 500);
    records.push(...read.records);
  } while (read.records.length > 0 && records.length < read.through);
  return { header: read.header!, records, read };
}

const same = (a: unknown, b: unknown) => assert.equal(canonicalJson(a), canonicalJson(b));

async function piRecords(stub: Stub, binding: SessionBinding): Promise<ClientRecord[]> {
  const records: ClientRecord[] = [];
  for (;;) {
    const read = await stub.read(binding, { epoch: null, after: records.length, limit: 256 });
    assert.equal(read.kind, "records");
    if (read.kind !== "records" || read.records.length === 0) return records;
    records.push(...read.records);
  }
}

test("a Session's ATXF is its Pi file read whole, verifies, and writes back the file byte for byte", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const { stub, binding } = await sessionObject(h);
  const uploader = await Uploader.start(binding.sessionId);
  await uploader.push(piLines(150));
  await uploader.upload(stub, binding, 1);

  const atxf = await caughtUp(stub, binding);
  const want = expected(uploader.file());
  same(atxf.header, want.header);
  assert.equal(atxf.records.length, 150);
  same(atxf.records, want.records);
  assert.deepEqual(verifyIntegrity(atxf), []);
  assert.equal(pi.fromAtxf(atxf), uploader.file());
  assert.match(atxf.read.converter!, /^@leostera\/atxf@0\.2\.0/);
});

test("translating changes no Pi record: lines, hashes, ids and formats read the same", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const { stub, binding } = await sessionObject(h);
  const uploader = await Uploader.start(binding.sessionId);
  await uploader.push(piLines(70));
  await uploader.upload(stub, binding, 1);
  await caughtUp(stub, binding);

  const records = await piRecords(stub, binding);
  assert.deepEqual(
    records.map(({ cursor, id, format, line, hash }) => ({ cursor, id, format, line, hash })),
    uploader.transcript.records.map((record, index) => ({ cursor: index + 1, id: record.id, format: "pi/3", line: record.line, hash: record.hash })),
  );
});

test("after a cut, the stream is read back from the kept records and the new branch translates as a fresh file would", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const { stub, binding } = await sessionObject(h);
  const first = await Uploader.start(binding.sessionId);
  const lines = piLines(40);
  await first.push(lines);
  await first.upload(stub, binding, 1);
  await caughtUp(stub, binding);

  // The host rewrote its file after record 25: the cloud cuts back to it, and the host appends its own.
  const cut = await stub.truncate(binding, 25, first.transcript.chainAt(25)!);
  assert.equal(cut.outcome, "truncated");
  const second = await Uploader.start(binding.sessionId);
  await second.push([...lines.slice(0, 25), ...piLines(30, "b").map((line) => line.replace('"parentId":null', '"parentId":"e24"'))]);
  await second.upload(stub, binding, 26, 2);

  const atxf = await caughtUp(stub, binding);
  assert.equal(atxf.records.length, 55);
  same(atxf.records, expected(second.file()).records);
  assert.equal(pi.fromAtxf(atxf), second.file());
});

test("a Session stored before RFD0035 is translated, oldest first, once it is read", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const { stub, binding } = await sessionObject(h);
  const uploader = await Uploader.start(binding.sessionId);
  await uploader.push(piLines(90));
  await uploader.upload(stub, binding, 1);
  await caughtUp(stub, binding);
  const before = await piRecords(stub, binding);

  // As it was stored before: no translations at all.
  await h.restart(() => {
    objectRows(h, "AxoSessionDO", `UPDATE records SET atxf_hash = NULL, atxf = NULL;
      UPDATE transcript SET atxf_header = NULL, atxf_through = 0, atxf_converter = NULL, atxf_error = NULL;
      DELETE FROM atxf_parts;`, true);
  });
  const { stub: cold } = await sessionObject(h, binding);
  assert.equal((await cold.atxf(binding, 1, 0)).through, 0);
  assert.deepEqual(await piRecords(cold, binding), before, "reading it changes none of its records");

  const atxf = await caughtUp(cold, binding);
  same(atxf.records, expected(uploader.file()).records);
  assert.equal(pi.fromAtxf(atxf), uploader.file());
});

test("a record too long for one SQLite value is kept in parts and reads back whole", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const { stub, binding } = await sessionObject(h);
  const uploader = await Uploader.start(binding.sessionId);
  const long = JSON.stringify({ type: "message", id: "big", parentId: null, timestamp: "2026-11-08T10:00:01.000Z", message: { role: "user", content: [{ type: "text", text: "é".repeat(700_000) }], timestamp: 1 } });
  await uploader.push([long, ...piLines(3).map((line) => line.replace('"parentId":null', '"parentId":"big"'))]);
  await uploader.upload(stub, binding, 1);

  const atxf = await caughtUp(stub, binding);
  same(atxf.records, expected(uploader.file()).records);
  assert.equal(pi.fromAtxf(atxf), uploader.file());
});

test("a header that carries a transcript stops translation for that Session and nothing else", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const { stub, binding } = await sessionObject(h);
  const carrying = JSON.stringify({ ...JSON.parse(header(binding.sessionId)), atxf: { id: null, transcript: { header: {}, records: [] } } });
  const uploader = await Uploader.start(binding.sessionId, carrying);
  await uploader.push(piLines(5));
  await uploader.upload(stub, binding, 1);

  const deadline = Date.now() + 10_000;
  let read = await stub.atxf(binding, 1, 10);
  while (read.error === null && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
    read = await stub.atxf(binding, 1, 10);
  }
  assert.match(read.error ?? "", /^record 0: .*carrying a transcript/);
  assert.equal(read.through, 0);
  assert.deepEqual(read.records, []);
  assert.equal((await piRecords(stub, binding)).length, 5);

  // Appending goes on; translation stays stopped.
  await uploader.push(piLines(2, "z").map((line) => line.replace('"parentId":null', '"parentId":"e4"')));
  await uploader.upload(stub, binding, 6);
  assert.equal((await piRecords(stub, binding)).length, 7);
  assert.equal((await stub.atxf(binding, 1, 0)).through, 0);
});

test("a cut that clears a stop tries again at once, rather than waiting for the next append", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const { stub, binding } = await sessionObject(h);
  const carrying = JSON.stringify({ ...JSON.parse(header(binding.sessionId)), atxf: { id: null, transcript: { header: {}, records: [] } } });
  const uploader = await Uploader.start(binding.sessionId, carrying);
  await uploader.push(piLines(5));
  await uploader.upload(stub, binding, 1);
  const stoppedAt = async () => {
    const deadline = Date.now() + 10_000;
    for (;;) {
      const read = await stub.atxf(binding, 1, 0);
      if (read.error !== null || Date.now() > deadline) return read;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  };
  assert.notEqual((await stoppedAt()).error, null);

  assert.equal((await stub.truncate(binding, 3, uploader.transcript.chainAt(3)!)).outcome, "truncated");
  // The header still carries a transcript: trying again stops again, and says so.
  const after = await stoppedAt();
  assert.match(after.error ?? "", /^record 0: /);
  assert.equal(after.count, 3);
});

/**
 * Real transcripts, by hand: `ATXF_PI_SESSIONS=~/.pi/agent/sessions` uploads each Pi session there
 * (up to `ATXF_PI_LIMIT`, each between `ATXF_PI_MIN_MB` and `ATXF_PI_MAX_MB`, default 0 and 20) and checks what the SessionDO
 * translated against the file. Skipped otherwise, so the suite stays hermetic.
 */
const sessions = process.env.ATXF_PI_SESSIONS;
test("every local Pi session translates to its file read whole, and back", { skip: !sessions }, async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const maxBytes = Number(process.env.ATXF_PI_MAX_MB ?? 20) * 1_048_576;
  const minBytes = Number(process.env.ATXF_PI_MIN_MB ?? 0) * 1_048_576;
  const files = readdirSync(sessions!).flatMap((dir) => {
    const path = join(sessions!, dir);
    return statSync(path).isDirectory() ? readdirSync(path).filter((name) => name.endsWith(".jsonl")).map((name) => join(path, name)) : [];
  }).filter((file) => statSync(file).size >= minBytes && statSync(file).size <= maxBytes).slice(0, Number(process.env.ATXF_PI_LIMIT ?? Infinity));
  let checked = 0;
  const skipped: Record<string, number> = {};
  const skip = (why: string) => void (skipped[why] = (skipped[why] ?? 0) + 1);
  for (const file of files) {
    const text = readFileSync(file, "utf8");
    const lines = text.split("\n");
    if (!text.endsWith("\n") || lines.slice(0, -1).some((line) => line.trim() === "")) { skip("not whole lines"); continue; }
    if (lines.some((line) => line.includes('"atxf"') && /"transcript"\s*:/.test(line))) { skip("carries a transcript"); continue; }
    let headerLine: string;
    try {
      const first = JSON.parse(lines[0]!) as { type?: unknown; id?: unknown };
      if (first.type !== "session") throw new Error();
      headerLine = lines[0]!;
    } catch { skip("no session header"); continue; }
    const { stub, binding } = await sessionObject(h);
    const uploader = await Uploader.start(binding.sessionId, headerLine);
    let refused = false;
    for (const line of lines.slice(1, -1)) if (!(await uploader.transcript.push(line))) { refused = true; break; }
    if (refused) { skip("a line pi/3 refuses"); continue; }
    if (uploader.transcript.count === 0) { skip("empty"); continue; }
    await uploader.upload(stub, binding, 1);
    const atxf = await caughtUp(stub, binding);
    assert.equal(uploader.file(), text);
    same(atxf.header, expected(text).header);
    same(atxf.records, expected(text).records);
    assert.equal(pi.fromAtxf(atxf), text, file);
    checked += 1;
  }
  t.diagnostic(`checked ${checked} sessions; skipped ${JSON.stringify(skipped)}`);
  assert.ok(checked > 0);
});
