# RFD0035 - Axo: Session records in ATXF

- Feature Name: `axo-atxf-records`
- Status: Implemented
- Author: leostera
- Start Date: 2026-11-08
- Updated: 2026-11-10
- Document Type: Proposal
- Amends: [RFD0018](RFD0018-session-sync-and-client-delivery.md), [RFD0025](RFD0025-agent-xchange-protocol.md)

## Summary

Every Session record the cloud holds gets its ATXF record beside it. The SessionDO translates each Pi line as it commits it, with ATXF's Pi converter read as a stream, and keeps the translation in new columns. Nothing it already stored changes: the line, its `pi/3` hash, the chain and the cuts stay as RFD0018 wrote them, and the wire stays `pi/3`. This moves the records to ATXF first; the wire moves when AXP does.

## Motivation

RFD0025 makes a Session's log an ATXF transcript, so that a client renders any agent's Session from ATXF alone. Today the cloud holds Pi lines and every client parses Pi. Moving the wire and the records at once would be a big bang across the Worker, axod, the web app, the phone and pi-axo. Moving the records alone touches only the SessionDO, and proves on every Session in production that the translation is lossless before anything depends on it.

## Guide-level explanation

Nothing visible changes. Behind it, each SessionDO holds two views of one log:

- the Pi lines, hashed and chained as `pi/3` (RFD0018): what axod uploads, what clients read today;
- the same records in ATXF 0.1, with integrity: a header, and one record per line, hashed as ATXF §17 says.

A line is translated when it commits. A Session stored before this change is translated, oldest record first, the next time its SessionDO is used.

## Reference-level explanation

### Reading Pi as Pi writes it

ATXF's converters read whole files, and a Session can be 250 MB (the largest on this Mac is; 1% are over 11 MB). Reconverting it for each appended batch costs 2.5 s. ATXF now streams Pi (`pi.stream()`, `@leostera/atxf` commit `7898efe`): it reads one line at a time and returns that line's record, final when returned, holding only the ids and hashes later lines refer to. Its laws hold it to the batch converter:

- Pushing a file's lines one by one returns the records `toAtxf` returns for the whole file.
- The header is `toAtxf`'s without `fidelity.nativeDigest`. A digest of the file only exists once the file is finished, and the records' hashes commit to the header, so a growing log can't carry one.
- The streamed transcript writes back the file it was read from.

All 1931 of this Mac's Pi sessions that don't carry a transcript stream to exactly the records `toAtxf` reads. A line carrying a transcript, which only `fromAtxf` writes, is refused.

axo depends on `@leostera/atxf` 0.3.0, which ships the stream and a schema validator that compiles on first use: compiling generates code, which Workers refuse, and importing the package must work in a Worker. (At first axo applied the commit as a pnpm patch to 0.2.0; `af45f01` dropped the patch for 0.3.0.)

The converter recorded in `atxf_converter` is still `@leostera/atxf@0.2.0+7898efe pi.stream` (`ATXF_CONVERTER` in `packages/axo-api-worker/src/session-atxf.ts`), although the Worker now runs 0.3.0. See Unresolved questions.

### Storage

New columns, added with defaults, so no stored row is rewritten:

| Where | Column | Holds |
| --- | --- | --- |
| `records` | `format` | The format of `line`: `pi/3` for every row today. |
| `records` | `atxf_hash` | The ATXF record's hash, once translated. |
| `records` | `atxf` | The ATXF record without `native`, or null when it is in `atxf_parts`. |
| `transcript` | `atxf_header` | The ATXF header, with its hash. |
| `transcript` | `atxf_through` | The last cursor translated. |
| `transcript` | `atxf_converter` | The converter that translated them. |
| `transcript` | `atxf_error` | Why translation stopped, if it did. |

An ATXF record's `native` is its Pi line, which `line` already holds; storing it again would double every Session. The stored record leaves it out, and reading puts it back with ATXF's own `nativeOf`, so the record read is byte for byte the one the converter returned, and its hash checks. A record longer than a SQLite value goes in `atxf_parts`, as long lines go in `record_parts`.

`atxf_converter` matters because hashes vouch for content, not identity (ATXF §17.4): another converter version may write different records for the same line. A Session keeps the converter it was translated with; translating it again with a new one is a migration of its own.

### When translation runs

`atxf_through` only moves forward, one cursor at a time, in cursor order:

- **Inline.** After an append commits, the new records are translated in the same call when the translator is already at the old count and its stream is in memory. They are a batch of at most 64 records.
- **Later.** Otherwise (a cold object, a Session stored before this change, a batch that found the translator behind) the object sets an alarm and translates in slices of 2048 records or 16 MB.
- **Resuming.** A stream lives in memory. An object that wakes reads lines 1 to `atxf_through` back through a new stream to rebuild it, and checks that each record's hash is the stored `atxf_hash`. A mismatch stops translation with `atxf_error` and touches nothing.
- **Cuts.** A truncation (RFD0018) deletes rows past `keep` with their translations, sets `atxf_through` to at most `keep`, and drops the stream; the next run rebuilds it. It also clears a stop, since the line that caused it may be gone, and so sets an alarm if records wait: the spec found that a cut otherwise left a Session behind and looking healthy until its next append. A new header on an empty transcript resets the translation.
- **Reading.** Reading a Session, or its head, sets an alarm if records wait; that is how a Session stored before this change starts.
- **Failures.** A line the stream refuses stops translation for that Session at that cursor, with `atxf_error`. The Pi records are unaffected. Nothing retries until a cut or a new header changes what is stored.

Translating never fails an append and never delays a reply on a replay.

### What does not change

The wire, `pi/3` hashes and chains, the upload handshake, truncation, and every read. `read` now takes each record's `format` from its row rather than assuming `pi/3`, which is the same value.

## Testing

- **ATXF's laws** (`atxf` repo): streaming equals batch for generated Pi files and fixtures, hashes included; the streamed transcript writes back its file; refusals.
- **Every local Pi session** (`ATXF_PI_SESSIONS`): streamed record by record against `toAtxf`.
- **The SessionDO under Miniflare** (`packages/axo-api-worker/tests/session-atxf.test.ts`): a Session's ATXF, read back with `native` restored, equals `toAtxf` of its file minus the digest; it round-trips to the file byte for byte; it verifies; it survives a cut (and the read-back after it), lines too long for one value, a refused line, and a cut that clears a stop; the Pi records and their hashes read the same before and after. Mutations that skip the read-back check or alter `native` fail it.
- **Real transcripts through the SessionDO**, by hand (`ATXF_PI_SESSIONS=~/.pi/agent/sessions`, with `ATXF_PI_MIN_MB` and `ATXF_PI_MAX_MB`): uploaded as axod uploads, translated, read back and written out. All 1924 sessions on this Mac that a stream reads (1911 under 20 MB, 13 from 20 to 250 MB) come back byte for byte; 5 empty ones and 1 carrying a transcript were skipped.
- **The Feynman spec** `specs/sessions/atxf-records.ts` (check with `--depth 22`): under appends, cuts, evictions and alarms in any order, no acknowledged Pi line is lost or changed, every stored ATXF record is the translation of the lines up to it, and translation catches up unless a line stops it. Reading back, cuts restarting the stream, and alarms when behind are each needed.

## Drawbacks

- An object holding a large Session reads all of it back once each time it wakes to translate. That's 2.5 s of CPU for the largest Session here. Every append to a cold object leaves it behind, so this is once per wake that appends: one alarm, a billed request, and the read-back. The append itself never waits for it. RFD0032's push delivery touches SessionDOs only to append, so they go cold more often. The ops-cost review (2026-11-08) put the worst case at about 32k GB-s and 1.3B rows read a month, against 400k and 25B included.
- Storage grows by about the size of each record's content again. The bytes of the line are not stored twice.

## Alternatives

- **Translate in axod.** RFD0018 put translation next to the agent, and RFD0025 has the host convert as Pi writes. That changes the wire now and translates nothing already in the cloud. When AXP moves the wire, the host can send ATXF and the cloud can check it against its own translation.
- **Convert the whole file on each append.** Quadratic: 2.5 s per batch for the largest Session.
- **Store `native` with the record.** Doubles storage for a copy of `line`.
- **A separate table of ATXF records.** The translation is one per row and goes with the row on a cut. Columns on the row keep that true without a second delete.

## Unresolved questions

- Whether `ATXF_CONVERTER` should name 0.3.0. Records translated since `af45f01` are labelled with the 0.2.0 commit that the 0.3.0 stream came from. If 0.3.0 writes the same records, the label is only stale. If it does not, Sessions translated before and after the upgrade carry different translations under one converter name, which defeats the column's purpose (ATXF §17.4). Changing it means deciding whether existing Sessions are re-translated.

- When a reader needs ATXF, Sessions no one has touched since this shipped must be translated first: a sweep over every SessionDO, or translation on first read.
- Whether to stop storing `line` once AXP carries ATXF, keeping it only as `native`.
- Whether ATXF's stream should snapshot its state (aliases, parents, tool calls and the Pi reader's state) so that a cold object resumes from SQLite instead of reading every line back. Worth it if the read-back shows up in GB-s once push delivery ships.
