/**
 * Record identity and hashing for Pi session files (`pi/3`; RFD0018, Record identity and
 * hashing). The same rules are implemented in Rust (`crates/axo-relay/src/pi3.rs`); both are
 * checked against `fixtures/pi3/`.
 *
 * A Session's transcript is its Pi session file: line 0 is the header, every later line is one
 * immutable record whose payload is the raw line, without its newline. Hashes copy the shape of
 * ATXF §17 under their own domain prefix, so a `pi/3` hash is never mistaken for an ATXF one:
 *
 * - `D(tag, text) = "sha256:" + hex(sha256("axo/pi3/" + tag + "\n" + text))`
 * - `headerHash = D("transcript", header)`
 * - `hash = D("record", JCS({ content: D("content", line), refs, transcript: headerHash }))`,
 *   where `refs` maps each reference field the entry has to the referenced record's hash. A
 *   reference to no earlier record (Pi writes a few) hashes as `null`: the content digest still
 *   covers the raw line, so nothing it says is lost.
 * - `chain` starts at `headerHash`, and each record folds in as `D("chain", chain + "\n" + hash)`.
 * - `heads` are the sorted hashes of records no other record references.
 */

export const PI3_FORMAT = "pi/3";
/** Pi's reference fields, in JCS (sorted) order. */
export const PI3_REF_FIELDS = ["firstKeptEntryId", "fromId", "parentId", "targetId"] as const;
/** The largest line a Session may hold. A larger one stops that Session's upload. */
export const PI3_MAX_LINE_BYTES = 12 * 1_048_576;

const encoder = new TextEncoder();

export async function pi3Digest(tag: string, text: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", encoder.encode(`axo/pi3/${tag}\n${text}`));
  return `sha256:${[...new Uint8Array(bytes)].map((byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

export const pi3HeaderHash = (header: string) => pi3Digest("transcript", header);
export const pi3FoldChain = (chain: string, hash: string) => pi3Digest("chain", `${chain}\n${hash}`);

/** A line parsed far enough to hash it: its id and the ids it references. */
export type Pi3Entry = {
  id: string | null;
  /** Each reference field the entry has, and the id it names (null when it names none). */
  refs: Array<[field: (typeof PI3_REF_FIELDS)[number], id: string | null]>;
};

/** Parses a record line, or returns null if it is not a JSON object. */
export function pi3Entry(line: string): Pi3Entry | null {
  let value: unknown;
  try {
    value = JSON.parse(line);
  } catch {
    return null;
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
  const entry = value as Record<string, unknown>;
  return {
    id: typeof entry.id === "string" ? entry.id : null,
    refs: PI3_REF_FIELDS.filter((field) => Object.hasOwn(entry, field)).map((field) => [
      field,
      typeof entry[field] === "string" ? (entry[field] as string) : null,
    ]),
  };
}

/** The record hash of `line`, resolving references with `hashOf` (records before it). */
export async function pi3RecordHash(
  headerHash: string,
  line: string,
  entry: Pi3Entry,
  hashOf: (id: string) => string | undefined,
): Promise<string> {
  const refs = entry.refs.map(([field, id]) => {
    const target = id === null ? undefined : hashOf(id);
    return `${JSON.stringify(field)}:${target === undefined ? "null" : JSON.stringify(target)}`;
  });
  const content = await pi3Digest("content", line);
  return pi3Digest("record", `{"content":${JSON.stringify(content)},"refs":{${refs.join(",")}},"transcript":${JSON.stringify(headerHash)}}`);
}

/** One hashed record, with what it references, for heads. */
export type Pi3Record = { position: number; id: string | null; line: string; hash: string; chain: string; references: string[] };

/**
 * A transcript hashed in file order: what Axod computes over a file and what the SessionDO keeps
 * as it commits. Positions count from 1 after the header.
 */
export class Pi3Transcript {
  readonly records: Pi3Record[] = [];
  private readonly byId = new Map<string, string>();
  readonly header: string;
  readonly headerHash: string;
  private constructor(header: string, headerHash: string) {
    this.header = header;
    this.headerHash = headerHash;
  }

  static async start(header: string): Promise<Pi3Transcript> {
    return new Pi3Transcript(header, await pi3HeaderHash(header));
  }

  get count(): number {
    return this.records.length;
  }

  get chain(): string {
    return this.records.at(-1)?.chain ?? this.headerHash;
  }

  /** The chain after `position` records; `0` is the header hash. */
  chainAt(position: number): string | undefined {
    return position === 0 ? this.headerHash : this.records[position - 1]?.chain;
  }

  /** Adds the next line, or returns null if it is not a JSON object. */
  async push(line: string): Promise<Pi3Record | null> {
    const entry = pi3Entry(line);
    if (!entry) return null;
    const hash = await pi3RecordHash(this.headerHash, line, entry, (id) => this.byId.get(id));
    const references = entry.refs.flatMap(([, id]) => (id !== null && this.byId.has(id) ? [id] : []));
    const record = { position: this.count + 1, id: entry.id, line, hash, chain: await pi3FoldChain(this.chain, hash), references };
    this.records.push(record);
    if (entry.id !== null) this.byId.set(entry.id, hash);
    return record;
  }

  get heads(): string[] {
    const referenced = new Set(this.records.flatMap((record) => record.references));
    return this.records
      .filter((record) => record.id === null || !referenced.has(record.id))
      .map((record) => record.hash)
      .sort();
  }
}
