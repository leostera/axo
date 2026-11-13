# RFD0044 - Axo: Sessions live in R2

- Feature Name: `sessions-in-r2`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-12
- Updated: 2026-11-12
- Document Type: Proposal
- Amends: [RFD0018](RFD0018-session-sync-and-client-delivery.md) (where the SessionDO keeps lines, and what a cut keeps), [RFD0027](RFD0027-archived-sessions-live-in-the-cloud.md) (eviction waits for R2), [RFD0035](RFD0035-session-records-in-atxf.md) (ATXF becomes the stored form)

## Summary

A Session's records live in R2, in the `axo-sessions` bucket, as write-once ATXF segments. The SessionDO stops being where they are kept. It orders appends, keeps every record's hash, chain and refs, and holds the lines R2 does not have yet. About an hour after the first line R2 lacks, its alarm stores the next segment, reads it back, and only then drops those lines.

Each ATXF record carries its Pi line in `native`, so nothing is lost while ATXF on its own still drops data. A cut never deletes a line R2 has not given back: those lines go to a side table first. Keys carry a generation, so a SessionDO rebuilt after losing its storage writes beside the old one, never over it.

This ships in three releases: store segments, then read from them, then drop lines. The design is modelled in [`specs/sessions/storage-in-r2.ts`](../../specs/sessions/storage-in-r2.ts).

## Motivation

- **The cloud holds the only copy of some Sessions, in a store that is not meant to keep them.** [RFD0027](RFD0027-archived-sessions-live-in-the-cloud.md) deletes an archived Session's file on the Mac once the SessionDO holds it all (`evict_next`, `crates/axo-relay/src/sync/uploader.rs`). A Durable Object's storage can be lost to a storage bug, a bad schema step, a deleted namespace or a mistaken release. Nothing could rebuild it.
- **A cut deletes records.** `SessionStore.truncate` runs `DELETE FROM records WHERE cursor > ?`. A Mac restored from an old backup cuts the cloud back to it, and for an archived Session those records are gone everywhere. [RFD0043](RFD0043-axo-on-axp.md) removes truncation only in its phase 3d.
- **The SessionDO pays SQLite prices for bulk.** $0.20/GB-month, against $0.015/GB-month in R2. Bulk bytes belong in durable object storage; the coordinator keeps the small metadata.
- **ATXF is what Axo shares and serves** (RFD0035, RFD0043). Storing it is storing the thing every reader wants, and with `@leostera/atxf` 0.4.0 it keeps everything Pi wrote.

What the cloud holds, from the three Macs' `~/.axo/sessions` on 2026-11-12 (each Mac follows the others, so each holds the account's Sessions):

| | Measured |
|---|---|
| Sessions | 202 (432 files on the Studio, counting sub-agents) |
| Pi lines | 1.0–2.3 GB per Mac |
| Largest Session file | 117.8 MB |
| Records written per day | 4,600–38,000, last 14 days |
| Busiest hour | 4,782 records |
| Sessions written in an hour | 7.5 on average, 107 at most (an initial sync) |
| Hours with any writes | 288 of the last 336 |

## Goals

- Every record a SessionDO commits is in R2 within about an hour, and stays there unchanged.
- Once R2 has given a segment back, the SessionDO no longer holds its lines.
- No cut, eviction, retry, restart, corrupted segment or lost storage leaves a committed record that neither the SessionDO nor R2 can give back, except records the SessionDO lost before R2 had them.
- Readers get every record as it was committed, from whichever holds it.
- A Session can be rebuilt from R2 alone, and the rebuild is checked against its hashes and chain.
- About one R2 write per Session per active hour, not one per record.

## Non-goals

- The rest of the account (identity, apps and their call log, assets, WhatsApp, shares). It gets its own RFD.
- Dropping `native` from the stored ATXF. `@leostera/atxf` 0.4.0 makes Pi → ATXF → Pi lossless without it: on 2,146 local Session files, all 195,046 entries come back equal as JSON. But Axo's record hash is over a Pi line's exact bytes (`pi3RecordHash`), and the rebuilt lines are equal only as JSON. Served `pi/3` records and Sessions restored to a Mac (RFD0027) would then fail their hashes and chain. `native` goes once Axo's chain is over ATXF records ([RFD0043](RFD0043-axo-on-axp.md) phase 3), in a new generation.
- Changing the wire. Clients and axod see the same `pi/3` records; the SessionDO takes lines out of `native` to serve them.
- A restore command for production. This RFD gives the restore function and its tests.

## Guide-level explanation

### What changes for people

Nothing visible. Opening an old Session's history may take a few more milliseconds, and a Session survives its Durable Object.

### The bucket

The bucket is `axo-sessions`, bound as `SESSIONS` and declared in `sites/axo.leostera.dev/cloudflare.config.ts`. It already holds `archived/<session>.jsonl` objects from 2026-10-28, from before RFD0018. They stay as they are: they may be the only copy of some Sessions (Unresolved questions). Everything this RFD writes is under `accounts/`:

```
accounts/<account>/hosts/<host>/sessions/<session>/<generation>/
  epoch-1/header.json
  epoch-1/0000000001-0000000310.atxf.jsonl
  epoch-1/0000000311-0000000340.atxf.jsonl
  epoch-2/header.json
  epoch-2/0000000081-0000000090.atxf.jsonl
```

- **`header.json`** is the ATXF transcript header (`TranscriptHeader`) that the stream made from the Session's Pi `session` line. Axo adds its own fields under `ext.axo`:

  ```json
  { "atxf": "0.2", "id": "…", "source": { "agent": "pi", "sessionId": "…" }, "fidelity": { "native": "all", … },
    "ext": { "axo": { "accountId": "…", "hostId": "…", "sessionId": "…", "generation": "…",
                       "epoch": 2, "keep": 80, "parent": 1, "headerHash": "…",
                       "converter": "@leostera/atxf@0.3.0 pi.stream" } } }
  ```

  `keep` is how many records the epoch shares with `parent`, the epoch it was cut from. Epoch 1 has `keep: 0` and `parent: null`. The header with an epoch's segments, in cursor order, is a valid ATXF transcript any ATXF reader opens.
- **A segment** holds records `from` to `to` of one epoch. It has one ATXF record per line, each with its Pi line in `native`, as `AtxfTranslator` returns it (`withNative`). Cursors are padded to ten digits, so a listing comes back in order. A segment holds at most 2,048 records or about 16 MiB, the budget translation already uses (`TRANSLATE_RECORDS`, `TRANSLATE_BYTES`).

Axo writes every object once, with `If-None-Match: *`, and never overwrites or deletes one.

### A Session written live

At 10:02 Pi writes a line, and axod appends it as cursor 41. The SessionDO commits it with its hash and chain, and translates it while its stream is warm, as it does today. It sees that R2 has 40 records, so it sets `due_at` to 11:02. By 11:02 Pi has written 300 more lines. The alarm then:

1. writes the range 41–340 down;
2. PUTs the segment;
3. reads it back;
4. checks that every line taken out of `native` is byte for byte the line it holds;
5. drops those 300 lines, keeping their rows.

A Session nobody writes to is never woken.

### Reading history

A phone scrolls up to cursor 100. Each record row names its segment, with the record's byte offset and length in it. The SessionDO reads that range with an R2 ranged GET and takes each line out of `native`. It sends the phone the same `pi/3` records it always has. Segments never change, so the reads go through the Workers Cache too.

### A Mac restored from an old backup

The Studio comes back from last week's Time Machine. Its file has 80 records. The cloud has 120; R2 has given back 100 of them, and the SessionDO dropped those. The uploader cuts the cloud back to 80. In the same transaction, the SessionDO moves the lines it has not read back from R2, 101–120, to its side table. Later alarms store them as `epoch-1/…101-…120.atxf.jsonl`, read them back, and delete them from the side table. Then epoch 2 gets its header (`keep: 80, parent: 1`) and its own records from 81. Nothing of epoch 1 is lost.

### A SessionDO that lost its storage

A bad release wipes a SessionDO. The next handshake finds it empty, and the Mac uploads its file again. The new storage picks a new generation, so its segments go beside the old generation's, which still holds everything R2 had.

## Reference-level explanation

### Who holds what

| | SessionDO | R2 |
|---|---|---|
| Header line, header hash, epoch, cuts | yes | in each epoch's `header.json` |
| Per record: cursor, id, hash, chain, refs, bytes | yes, always | recomputable from `native` |
| Per record: segment, offset, length | yes, once stored | — |
| Pi line | until R2 gave it back | in `native` |
| ATXF record | until R2 gave it back | yes |
| ATXF stream state | a saved state at the end of each segment | — |

`append` never needs a dropped line. It checks an overlap by hash, hashes new records against stored hashes (`pi3RecordHash`, `hashOf`), and folds the stored chain. So appends cost what they cost today.

### Schema

New last steps of `SESSION_SCHEMA`:

```sql
-- Where each record's ATXF is in R2, once it is.
ALTER TABLE records ADD COLUMN segment TEXT;       -- the object key's last part
ALTER TABLE records ADD COLUMN seg_offset INTEGER;
ALTER TABLE records ADD COLUMN seg_length INTEGER;
CREATE TABLE storage (singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  generation TEXT NOT NULL, due_at INTEGER, failures INTEGER NOT NULL DEFAULT 0, refused TEXT);
CREATE TABLE storage_epochs (epoch INTEGER PRIMARY KEY, keep INTEGER NOT NULL, parent INTEGER,
  through INTEGER NOT NULL,      -- the last cursor R2 has
  dropped INTEGER NOT NULL,      -- the last cursor R2 gave back, and whose line the SessionDO dropped
  header_saved INTEGER NOT NULL DEFAULT 0);
CREATE TABLE storage_pending (singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  kind TEXT NOT NULL, epoch INTEGER NOT NULL, "from" INTEGER, "to" INTEGER, stored INTEGER NOT NULL DEFAULT 0);
CREATE TABLE storage_cut (epoch INTEGER NOT NULL, cursor INTEGER NOT NULL, line TEXT, atxf TEXT,
  PRIMARY KEY (epoch, cursor));   -- with storage_cut_parts for lines over PART_CHARS
-- The ATXF stream's saved state, the latest only, in parts: it is about 155 bytes a record.
CREATE TABLE stream_state (idx INTEGER PRIMARY KEY, cursor INTEGER NOT NULL, epoch INTEGER NOT NULL, data TEXT NOT NULL);
```

`records.line` and `records.atxf` become nullable in meaning. `NULL` means "in R2", and `segment` says where. A SessionDO from before gets `storage_epochs` rows from its `cuts`, with `through = dropped = 0`.

### Rules

Seven rules keep the properties true. The spec checks that each one is needed: without it, a property breaks.

1. **`commitArms`: a commit sets the alarm.** `append` and `truncate` set `due_at` to now plus `STORE_DELAY` (an hour) if it is null, in their transaction.
2. **`oneAlarm`: one alarm for both jobs.** A Durable Object has one alarm, and `setAlarm` replaces it. Translation sets it for now (`catchUp`, `translateAfterAppend`), which would replace the alarm set for R2. Nothing calls `setAlarm` directly any more: `scheduleAlarm()` sets it to the earliest of "now, if translation waits" and `due_at`. The handler calls it on every way out.
3. **`outbox`: a range is written down before its PUT.** The handler takes the next segment, oldest epoch first (its header, then records from `through + 1` up to the last translated one). It writes the range to `storage_pending` before the PUT, and a retry sends that range again. Without this, a PUT whose answer was lost would be followed by a longer one from the same cursor, leaving two segments that overlap.
4. **`readBackBeforeDrop`: lines go only after R2 gave them back.** Once a segment is stored, the handler marks `stored = 1`, sets `through`, and records each row's `segment`, `seg_offset` and `seg_length`. The next run GETs the segment, checks its SHA-256, and takes the Pi line out of every record's `native`. If each line is byte for byte the one held, it sets `line = NULL, atxf = NULL`, deletes their parts, and advances `dropped`, all in one transaction. A mismatch stops storing for this Session (`storage.refused`), keeps every line, and logs `session.storage_refused`. In the spec, a bug that stores other bytes than those sent is caught here.
5. **`cutKeepsUnstored`: a cut keeps every line R2 has not given back.** Before deleting, `truncate` copies into `storage_cut` every record of the current epoch after `dropped`, whether R2 has it or not. Lines stored but not yet read back still need the read-back. The new epoch's row gets `through = keep`. Side-table rows go only when their segment reads back equal.
6. **`generations`: keys carry the generation.** A random UUID, made when the `storage` table is created. A SessionDO rebuilt from nothing has a new one, so its epoch 1 never lands on the old epoch 1's keys.
7. **`checkpoints`: the stream's state is saved at each segment's end.** Today a SessionDO evicted from memory rebuilds its ATXF stream by reading every line from cursor 1 (`AxoSessionDO.resume`). Once lines are dropped, that means reading the whole Session back from R2 on the first append after each eviction, up to 118 MB. So after storing a segment, the handler saves the stream's state at its last cursor. It uses `reading.state()` from `@leostera/atxf` 0.4.0 and replaces the one saved before, in parts of `PART_CHARS`, in the transaction that records the segment (`stream_state`). `resume` starts from it with `pi.stream({ resume })` and reads at most one segment. It falls back to reading every line only if the saved state is from another reader version (`state.stream !== PI_STREAM_STATE` throws a `RangeError`) or another epoch. The state holds every record's id, parent, type and hash, so it grows with the Session: 3.1 MB for the largest (121 MB, 20,775 records), 469 KB for a 53 MB one. That is 2–3% of the lines it replaces. A cut keeps the state only if it was saved at or before `keep`.

### Reading

`read` and `atxf` read rows as today. For a row whose `line` is `NULL`, they group the rows by `segment` and issue one ranged GET per segment (`range: { offset, length }` over the rows asked for). They take each `native` line out of the result and check its hash against the row. A cursor at or before the current epoch's `keep` may live in an earlier epoch's segment. The row's `segment` names it, so a reader never needs a header that might not be stored yet (`readsAreFaithful` in the spec).

R2 is behind the Workers Cache for these ranges (`AxoAssetCache` already does this for assets), keyed by object key and range, because segments never change.

### Failures

- **A PUT or GET fails.** It is caught, not thrown, because alarms retry a throwing handler only six times. The handler raises `failures`, sets `due_at` to now plus `min(2^failures minutes, 1 hour)`, and logs `session.storage_failed`.
- **A PUT finds the key taken** (`put` returns `null`). The handler compares the object's `checksums.sha256` with its own. Equal means an earlier try stored it. Different means something else wrote there: storing stops and says so.
- **An alarm and an append in the same object.** Storage reads are re-checked after each `await`, as `append` already does. The spec lets appends and cuts land while a PUT or GET is out.
- **ATXF refuses a line.** Translation stops there (`atxf_error`), so R2 stops there too, and the lines from it on stay in the SessionDO. That Session is listed as stuck (Observability).

### Sessions stored before

A HostDO schema step adds `session_index.storage_armed INTEGER NOT NULL DEFAULT 0`. On each handshake (`AxoHostDO.sync`), after answering, the HostDO calls `AxoSessionDO.armStorage(binding)` for up to 64 unarmed rows, missing ones included, 16 at a time, and sets the flag for each answer. `armStorage` sets `due_at` to now if R2 is behind. The 202 Sessions are armed by the first handshakes after release 1, and each then stores itself, a segment per alarm run.

### Eviction on the Mac waits for R2

RFD0027 evicts an archived Session's file once the cloud's count and chain match it. It now also waits until R2 has given every record back. Head and append answers carry `stored`, the current epoch's `dropped` (`SessionHead.stored`, `appendResultSchema`), and axod evicts only when `stored == count`. An axod that does not know `stored` does not evict.

### Restoring

`src/session-storage.ts` exports `restoreEpoch(list, get, generation, epoch)`. It reads an epoch's header, then its parent's first `keep` records (recursively), then its segments in order. It refuses a gap or an overlap, and checks every `native` line with `pi3RecordHash` and `pi3FoldChain` from the header hash. It returns what an `append` takes.

### Releases

1. **Store.** The schema, rules 1–3 and 5–6, the read-back without the drop, backfill, observability. The SessionDO still holds every line. Check: every Session reaches `through == count`, and a restore from R2 of the largest Session, one with a cut and one archived Session equals the SessionDO.
2. **Read through.** `read` and `atxf` also read each stored range from R2 and compare it with the line held. They serve the held line, and log `session.storage_mismatch` on any difference. This needs `checkpoints` (rule 7) from `@leostera/atxf`. Gate: a week with no mismatch.
3. **Drop.** Rule 4 in full; axod eviction waits for `stored`. Then the bucket lock.

### Cost

From the measurements above, at the published prices (`r2/pricing`, `durable-objects/platform/pricing`, read 2026-11-12):

| | Store hourly | Store every append |
|---|---|---|
| R2 PUTs a month | about 5,400 (7.5 Sessions × 24 h × 30) | about 1.1 million (`BATCH_RECORDS` is 64; records go as they come) |
| R2 GETs to read back | about 5,400 | about 1.1 million |
| Alarms a month | about 5,400 | none extra |
| Operations | inside the free tiers | about $0.50 past them, growing with use |
| Storage | about 5 GB of ATXF with `native`: $0.08 a month in R2, instead of about $0.50 in SQLite | the same |

Reading history costs a Class B operation per range ($0.36 per million), less what the cache serves.

### Observability

- `session.storage_stored` `{ epoch, from, to, bytes, ms }`, `session.storage_dropped` `{ epoch, to }`, `session.storage_failed` `{ epoch, failures, error }`, `session.storage_refused` `{ key, why }`, `session.storage_mismatch` `{ cursor }`, through `recordApiEvent`.
- Logs are sampled at 1% (`headSamplingRate`), so they cannot show one failing Session. The HostDO keeps each row's `stored` from the answers it already gets (`refreshHead`). `GET /api/v1/account/storage` lists Sessions more than two hours behind, stopped by ATXF, or refused.

### Testing

- **Unit:**
  - `restoreEpoch` on hand-made segments: one epoch; a cut; a gap; an overlap; a wrong hash; a wrong chain.
  - taking `native` out of every record of the ATXF fixtures equals the lines, byte for byte.
- **Worker, Miniflare** (`tests/session-storage.test.ts`, with R2):
  - live: one segment, read back, lines dropped, reads equal;
  - a backlog of 5,000 records stores in segments, oldest first;
  - a cut before R2 has the lines, and one between store and read-back: both epochs restore, and reads of the new epoch find kept lines in the old epoch's segment;
  - a failed PUT, then a success: same key;
  - a stored PUT whose answer is lost: the retry finds the same bytes;
  - a segment stored with other bytes (a stub): nothing dropped, the Session refused;
  - translation and a due segment share the alarm;
  - evicted (`unsafeEvictDurableObject`) between each step, and after lines were dropped: the next append's translation reads one segment at most;
  - a wiped object (a new SessionDO name standing for it) writes under a new generation;
  - backfill arms each row once.
- **End to end:** `tests/session-storage-e2e.test.ts` with a real axod. A Session is written, cut, evicted on the Mac and dropped in the SessionDO. It reads back on the phone path, and restores from R2 alone.
- **Spec:** `feynman check sessions/storage-in-r2` in CI, with `sources` as the code lands.

## Drawbacks

- **An hour of records can be lost** if a SessionDO loses its storage before R2 has them. The Mac usually has them, and archived Sessions are not written to.
- **History reads go to R2.** Ranged GETs behind a cache, but slower than SQLite for a phone scrolling back through a cold Session.
- **One alarm, two jobs, and a read-back.** More states than today's handler; rules 2–4 and their tests exist for that.
- **ATXF with `native` is about twice the Pi lines.** Cheap in R2, but it is the Pi data stored twice until ATXF can stand alone.
- **Cut records are kept forever.** That is the point, but a cut never frees space.

## Alternatives

- **Back R2 up from the SessionDO, which stays where Sessions live.** This RFD's first draft. It keeps the bulk at SQLite prices and the SessionDO as the place a Session can be lost.
- **Store on every append.** A thousand times the writes, thousands of tiny objects per Session, and an R2 call in every commit.
- **Store Pi lines, not ATXF.** Smaller, but readers want ATXF, and RFD0043's hub would convert on every read.
- **Mutable objects, one per Session.** Every store rewrites up to 118 MB, and a bucket lock forbids it.
- **Point-in-time recovery of Durable Objects.** Thirty days, inside the same system, and no help when a namespace or an account is lost.

## Unresolved questions

Before acceptance:

- **ATXF must accept every line.** Done in `@leostera/atxf` 0.4.0: `pi.stream().push` never throws, and a line that is not JSON becomes a `custom` record (namespace `pi.line`). The SessionDO's `atxf_error` stop stays only for a stream that cannot reproduce a stored translation. Axo upgrades its readers to 0.4.0 before its writers, since 0.3.0 validators reject the new fields.
- **A bucket lock.** (a) None. (b) 30 days on `accounts/`, so nothing, not a bug and not a leaked token, can delete or overwrite a segment for 30 days. (c) Indefinite. Recommendation: (b), after release 3.
- **The preview Worker** (`axo-public-app-preview`) shares buckets today. (a) Its own, `axo-sessions-preview`. (b) The same; generations keep keys apart. Recommendation: (a).
- **The delay.** (a) An hour. (b) Ten minutes: six times the operations, still inside the free tier. Recommendation: (a).

During implementation:

- Whether `cf deploy` creates a bucket that `bindings.r2` names and the account lacks. `axo-sessions` exists already, so this matters only for preview.
- How many segments one alarm run stores for a large backlog. One per run is simplest.
- Whether the stream state should shrink to kilobytes, by having the reader look up earlier records in the SessionDO's `records` rows (which already hold each id and hash) instead of carrying them. That needs a new reader interface in `@leostera/atxf`. Worth it only if the 2–3% shows up in storage or resume time.

Out of scope:

- The `archived/` objects in `axo-sessions` and the `axo-session-files` bucket. Compare them with the SessionDOs, keep what exists nowhere else, and decide in a separate change.
- Dropping `native`. ATXF no longer needs it (0.4.0); Axo's `pi/3` hashes do, until RFD0043 moves the chain to ATXF records. That is when a new generation is written without it.

## Future possibilities

- **Archived Sessions leave their SessionDO.** An archived Session R2 holds whole could keep only its index rows, or nothing, and be read from R2 when opened.
- **RFD0043's hub.** `storage_cut` is §9.4's side table for forked records by another name, and the segments are the hub's replica.
- **Exports and sharing.** A Session's folder is a valid ATXF transcript, ready to share or download.
