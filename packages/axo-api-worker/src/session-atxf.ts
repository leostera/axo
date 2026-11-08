import { jsonl, nativeOf, type EntryRecord, type TranscriptHeader, type TranscriptStream } from "@leostera/atxf";
import { AGENT, FORMAT, pi } from "@leostera/atxf/pi";

/**
 * A Session's records in ATXF (RFD0035), translated from its Pi lines one at a time with ATXF's Pi
 * stream. A stored record leaves out `native`, which is its Pi line; `withNative` puts it back.
 */

/** The converter a Session's records were translated with; another may write different records (ATXF §17.4). */
export const ATXF_CONVERTER = "@leostera/atxf@0.2.0+7898efe pi.stream";

/** Reads a Session's lines, in order, into ATXF records. */
export class AtxfTranslator {
  private readonly stream: TranscriptStream = pi.stream!();

  /** Reads the transcript's header line, the Pi `session` entry. */
  start(headerLine: string): TranscriptHeader {
    const records = this.stream.push(headerLine);
    if (records.length !== 0 || this.stream.header === undefined) throw new RangeError("the header line is not a Pi session");
    return this.stream.header;
  }

  /** The record for the next line. Throws a `RangeError` for a line ATXF reads only as part of a whole file. */
  next(line: string): EntryRecord & { hash: string } {
    const [record, ...rest] = this.stream.push(line);
    if (record === undefined || rest.length !== 0 || record.hash === undefined) throw new RangeError("a Pi line did not become one record");
    return record as EntryRecord & { hash: string };
  }
}

/** The record as stored: everything but `native`, which is the line. */
export function storedForm(record: EntryRecord): string {
  const { native: _, ...rest } = record;
  return JSON.stringify(rest);
}

/** The record the stream returned for `line`, from its stored form. */
export function withNative(stored: string, line: string): EntryRecord {
  const { hash, ...rest } = JSON.parse(stored) as EntryRecord & { hash?: string };
  const native = nativeOf(jsonl.parse(`${line}\n`), AGENT, FORMAT);
  // The stream builds `{ ...record, native }`, then hashes it into `{ ...that, hash }`: the same key order.
  return (hash === undefined ? { ...rest, native } : { ...rest, native, hash }) as EntryRecord;
}
