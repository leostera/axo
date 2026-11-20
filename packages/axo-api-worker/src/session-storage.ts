import { Pi3Transcript, uuid } from "@axo/protocol";
import type { EntryRecord, TranscriptHeader } from "@leostera/atxf";
import type { SessionBinding } from "./session-store";

/**
 * A Session's records in R2 (RFD0044): write-once ATXF segments, one folder per generation and
 * epoch, under the account, host and Session the SessionDO is bound to.
 *
 * ```
 * accounts/<account>/hosts/<host>/sessions/<session>/<generation>/
 *   epoch-1/header.json
 *   epoch-1/0000000001-0000000310.atxf.jsonl
 * ```
 *
 * Every object is written once, with `If-None-Match: *`, and never overwritten or deleted. Each
 * record carries its Pi line in `native.raw`, byte for byte, so R2 alone can rebuild the Session
 * and its `pi/3` hashes and chain. A segment's custom metadata carries its range and the chain
 * after its last record, so a restore checks each segment against what the SessionDO committed.
 */

/** At most this many records, or about this many bytes of lines, go in one segment. */
export const SEGMENT_RECORDS = 2048;
export const SEGMENT_BYTES = 16 * 1_048_576;

/** The folder of one generation of a Session: everything this SessionDO writes is under it. */
export function generationPrefix(binding: SessionBinding, generation: string): string {
  // Parsed, not trusted: a key never takes a path segment from anything but a UUID.
  return `accounts/${uuid.parse(binding.accountId)}/hosts/${uuid.parse(binding.hostId)}/sessions/${uuid.parse(binding.sessionId)}/${uuid.parse(generation)}/`;
}

export const headerName = (epoch: number) => `epoch-${epoch}/header.json`;
export const segmentName = (epoch: number, from: number, to: number) =>
  `epoch-${epoch}/${String(from).padStart(10, "0")}-${String(to).padStart(10, "0")}.atxf.jsonl`;

const SEGMENT = /^epoch-(\d+)\/(\d{10})-(\d{10})\.atxf\.jsonl$/;

/** What `ext.axo` holds in an epoch's header. */
export type AxoHeaderExt = {
  accountId: string;
  hostId: string;
  sessionId: string;
  generation: string;
  epoch: number;
  /** How many records this epoch shares with `parent`; its own segments start after them. */
  keep: number;
  parent: number | null;
  /** The Pi `session` line, byte for byte: `pi/3` hashes are over it. */
  headerLine: string;
  headerHash: string;
  converter: string;
};

/** A segment's custom metadata (strings, as R2 keeps it). */
export type SegmentMeta = { epoch: string; from: string; to: string; chain: string };

/** One record as a segment line: the ATXF record with its Pi line in `native`. */
export function segmentBody(records: readonly EntryRecord[]): { body: Uint8Array<ArrayBuffer>; offsets: Array<{ offset: number; length: number }> } {
  const encoder = new TextEncoder();
  const parts = records.map((record) => encoder.encode(`${JSON.stringify(record)}\n`));
  const body = new Uint8Array(parts.reduce((total, part) => total + part.byteLength, 0));
  const offsets: Array<{ offset: number; length: number }> = [];
  let offset = 0;
  for (const part of parts) {
    body.set(part, offset);
    offsets.push({ offset, length: part.byteLength });
    offset += part.byteLength;
  }
  return { body, offsets };
}

/**
 * The Pi line a stored ATXF record carries, or null if it carries none. ATXF keeps the line's
 * bytes in `native.raw` only when re-serializing its parsed record would not give them back;
 * otherwise the line is that record as `JSON.stringify` writes it. The read-back and a restore's
 * hashes check that this is the line, byte for byte.
 */
export function nativeLine(record: EntryRecord): string | null {
  const native = (record as { native?: { raw?: unknown; records?: unknown } }).native;
  if (native?.raw !== undefined) {
    const raw = native.raw;
    if (!Array.isArray(raw) || raw.length !== 1 || typeof raw[0] !== "string" || !raw[0].endsWith("\n")) return null;
    return raw[0].slice(0, -1);
  }
  if (!Array.isArray(native?.records) || native.records.length !== 1) return null;
  return JSON.stringify(native.records[0]);
}

/** The Pi lines of a segment's bytes, in order; throws if a record is not one line with its Pi line. */
export function segmentLines(text: string): string[] {
  if (text.length > 0 && !text.endsWith("\n")) throw new RangeError("a segment ends mid-record");
  return text.split("\n").slice(0, -1).map((json, index) => {
    const line = nativeLine(JSON.parse(json) as EntryRecord);
    if (line === null) throw new RangeError(`record ${index + 1} of the segment carries no Pi line`);
    return line;
  });
}

export async function sha256Hex(bytes: Uint8Array<ArrayBuffer> | ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** What `restoreEpoch` reads R2 through: a listing of keys under a prefix, and an object's bytes. */
export type SegmentSource = {
  list(prefix: string): Promise<string[]>;
  get(key: string): Promise<{ text: string; meta: Record<string, string> } | null>;
};

/** An epoch rebuilt from R2 alone: what a SessionDO's `append` takes, checked against every hash and chain. */
export type RestoredEpoch = {
  header: string;
  headerHash: string;
  epoch: number;
  records: Array<{ id: string | null; line: string; hash: string }>;
  chain: string;
};

/**
 * Rebuilds `epoch` of one generation from R2: its parent's first `keep` records (recursively),
 * then its own segments in cursor order. Refuses a missing header, a gap, an overlap, a record
 * without its Pi line, a header whose hash is not its line's, and a segment whose chain is not
 * the one rehashing gives.
 */
export async function restoreEpoch(source: SegmentSource, prefix: string, epoch: number): Promise<RestoredEpoch> {
  const listed = await source.list(prefix);
  return restoreFrom(source, prefix, listed, epoch, Infinity);
}

async function restoreFrom(source: SegmentSource, prefix: string, listed: string[], epoch: number, upTo: number): Promise<RestoredEpoch> {
  const headerObject = await source.get(prefix + headerName(epoch));
  if (!headerObject) throw new RangeError(`epoch ${epoch} has no header`);
  const header = JSON.parse(headerObject.text) as TranscriptHeader & { ext?: { axo?: AxoHeaderExt } };
  const axo = header.ext?.axo;
  if (!axo || axo.epoch !== epoch) throw new RangeError(`epoch ${epoch}'s header is not Axo's`);

  const transcript = await Pi3Transcript.start(axo.headerLine);
  if (transcript.headerHash !== axo.headerHash) throw new RangeError(`epoch ${epoch}'s header line does not hash to its headerHash`);
  if (axo.keep > 0) {
    if (axo.parent === null) throw new RangeError(`epoch ${epoch} keeps ${axo.keep} records of no parent`);
    const parent = await restoreFrom(source, prefix, listed, axo.parent, axo.keep);
    if (parent.header !== axo.headerLine || parent.records.length < axo.keep) throw new RangeError(`epoch ${axo.parent} does not hold the ${axo.keep} records epoch ${epoch} keeps`);
    for (const record of parent.records.slice(0, axo.keep)) await transcript.push(record.line);
  }

  const segments = listed
    .map((key) => key.slice(prefix.length).match(SEGMENT))
    .filter((match): match is RegExpMatchArray => match !== null && Number(match[1]) === epoch)
    .map((match) => ({ name: match[0], from: Number(match[2]), to: Number(match[3]) }))
    .sort((a, b) => a.from - b.from);
  for (const segment of segments) {
    if (transcript.count >= upTo) break;
    if (segment.from !== transcript.count + 1) throw new RangeError(`epoch ${epoch}: ${segment.name} does not follow record ${transcript.count}`);
    const object = await source.get(prefix + segment.name);
    if (!object) throw new RangeError(`epoch ${epoch}: ${segment.name} is listed but gone`);
    const lines = segmentLines(object.text);
    if (lines.length !== segment.to - segment.from + 1) throw new RangeError(`epoch ${epoch}: ${segment.name} holds ${lines.length} records`);
    for (const line of lines) {
      if ((await transcript.push(line)) === null) throw new RangeError(`epoch ${epoch}: a line of ${segment.name} is not a Pi entry`);
    }
    if (object.meta.chain !== transcript.chain) throw new RangeError(`epoch ${epoch}: ${segment.name} does not end on the chain it was stored with`);
  }
  if (Number.isFinite(upTo) && transcript.count < upTo) throw new RangeError(`epoch ${epoch} holds ${transcript.count} of the ${upTo} records asked for`);
  const records = transcript.records.slice(0, Number.isFinite(upTo) ? upTo : undefined);
  return {
    header: axo.headerLine,
    headerHash: transcript.headerHash,
    epoch,
    records: records.map(({ id, line, hash }) => ({ id, line, hash })),
    chain: records.at(-1)?.chain ?? transcript.headerHash,
  };
}

/** A `SegmentSource` over an R2 bucket. */
export function bucketSource(bucket: R2Bucket): SegmentSource {
  return {
    async list(prefix) {
      const keys: string[] = [];
      let cursor: string | undefined;
      do {
        const page = await bucket.list({ prefix, cursor });
        keys.push(...page.objects.map((object) => object.key));
        cursor = page.truncated ? page.cursor : undefined;
      } while (cursor);
      return keys;
    },
    async get(key) {
      const object = await bucket.get(key);
      return object ? { text: await object.text(), meta: object.customMetadata ?? {} } : null;
    },
  };
}
