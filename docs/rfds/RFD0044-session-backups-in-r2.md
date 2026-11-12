# RFD0044 - Axo: Session backups in R2

- Feature Name: `session-backups`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-12
- Updated: 2026-11-12
- Document Type: Proposal
- Amends: [RFD0018](RFD0018-session-sync-and-client-delivery.md) (the SessionDO gains a copy, and truncation keeps what the copy lacks), [RFD0027](RFD0027-archived-sessions-live-in-the-cloud.md) (eviction waits for the copy)

## Summary

Every SessionDO copies the records it commits to a new R2 bucket, `axo-session-backups`, as write-once objects. Each object holds one range of one epoch's records, exactly as they are stored: the Pi line, its hash and its chain. The SessionDO sets its alarm an hour after the first record the copy lacks, so a Session that is written all day is copied about once an hour, and a quiet one costs nothing. A cut never deletes a record the copy lacks: those move to a side table first and are copied under their old epoch. Object keys carry a generation that the SessionDO picks when its storage is new, so a SessionDO that lost its storage and was rebuilt never writes over what the old one copied. Sessions stored before this get their first copy when their Mac next connects.

The design is modelled in [`specs/sessions/backups.ts`](../../specs/sessions/backups.ts).

## Motivation

The cloud holds the only copy of some Sessions, and nothing else holds a copy of any.

- **Archived Sessions live only in the cloud.** [RFD0027](RFD0027-archived-sessions-live-in-the-cloud.md) deletes an archived Session's file on the Mac once the SessionDO holds all of it (`evict_next` in `crates/axo-relay/src/sync/uploader.rs`). From then on its SessionDO is the only copy.
- **A cut deletes the cloud's records.** When the Mac's file and the cloud disagree, `SessionStore.truncate` runs `DELETE FROM records WHERE cursor > ?`. A Mac restored from an old backup cuts the cloud back to it. For an archived Session, those records are then gone everywhere. [RFD0043](RFD0043-axo-on-axp.md) removes truncation in its phase 3d, months away.
- **Durable Objects do not run forever.** A storage bug, a bad migration (`HOST_SCHEMA`/`SESSION_SCHEMA` steps run once and cannot be undone), a deleted namespace, or a mistake in a release can lose an object's storage. Every RFD0043 phase-3 release rewrites how SessionDOs store records, so the risk is about to go up.
- **There is no backup and no restore.** Nothing can rebuild a SessionDO except its Mac uploading the file again, which an evicted Session no longer has.

What the cloud holds, from the three Macs' `~/.axo/sessions` on 2026-11-12 (each Mac follows the others, so each holds the account's 202 Sessions):

| | Measured |
|---|---|
| Sessions | 202 (432 files on the Studio, with sub-agents) |
| Size | 1.0–2.3 GB of Pi lines per Mac |
| Largest Session file | 117.8 MB |
| Records written per day | 4,600–38,000, last 14 days |
| Busiest hour | 4,782 records |
| Sessions written in an hour | 7.5 on average, 107 at most (an initial sync) |
| Hours with any writes | 288 of the last 336 |

## Goals

- Every record a SessionDO commits can be read back from R2 within about an hour, and for good.
- A copy in R2 is never changed once written.
- No cut, crash, retry or lost storage leaves a committed record that neither the SessionDO nor R2 can give back, except records the SessionDO lost before it copied them.
- Restoring a Session from R2 alone gives back every epoch, checked against its hashes and chain.
- Writes to R2 cost about one per Session per active hour, not one per record.

## Non-goals

- Backing up anything but Sessions: accounts, apps and their call log, assets, WhatsApp links, shares. They come next, in their own RFD.
- Serving reads from R2, or moving old records out of the SessionDO. See Future possibilities.
- Backing up ATXF. It is derived from the Pi lines (RFD0035), and is made again from them.
- A restore command for production. This RFD gives the restore function and its tests; using it on production data is a separate decision.

## Guide-level explanation

### What changes for people

Nothing visible. The cloud quietly keeps a second copy of every Session. If a SessionDO ever loses its records, the Session can be rebuilt from that copy.

### The bucket

One private bucket, `axo-session-backups`, bound to the Worker as `SESSION_BACKUPS` and declared in `sites/axo.leostera.dev/cloudflare.config.ts` next to the others. Nothing else writes to it. Each Session has a folder:

```
accounts/<account>/hosts/<host>/sessions/<session>/<generation>/
  epoch-1/header.json
  epoch-1/0000000001-0000000064.jsonl
  epoch-1/0000000065-0000000071.jsonl
  epoch-2/header.json
  epoch-2/0000000069-0000000090.jsonl
```

- **`header.json`**, one per epoch, written before its records:

  ```json
  { "format": "axo.session-backup/1", "accountId": "…", "hostId": "…", "sessionId": "…",
    "generation": "…", "epoch": 2, "keep": 68, "parent": 1,
    "header": "{\"type\":\"session\",…}", "headerHash": "…" }
  ```

  `keep` is how many records the epoch shares with its `parent`, the epoch it was cut from. Epoch 1 has `keep: 0` and `parent: null`.
- **A chunk** holds records `from` to `to` of one epoch, one per line, as the SessionDO stores them:

  ```json
  {"cursor":69,"hash":"…","chain":"…","line":"{\"type\":\"message\",…}"}
  ```

  Cursors are padded to ten digits, so a listing comes back in order. A chunk holds at most 2,048 records or about 16 MiB of lines, the same budget the ATXF translation uses (`TRANSLATE_RECORDS`, `TRANSLATE_BYTES`).

Every object is written once, with `If-None-Match: *`, and never overwritten or deleted by Axo.

### A Session written live

At 10:02 Pi writes a line, and axod appends it (cursor 41). The SessionDO commits it, sees that its copy has 40 records, and sets its alarm for 11:02, unless one is already set. Pi writes 300 more lines by 11:02. The alarm fires and copies cursors 41–340 as one chunk, then sets the alarm again only if records came in meanwhile. A Session written all day is copied about once an hour. One nobody writes to is never woken.

### A Mac restored from an old backup

The Studio comes back from last week's Time Machine. Its file for a Session has 80 records; the cloud has 120, of which the copy has 100. The uploader cuts the cloud back to 80 (`truncate`, keep 80). In the same transaction, the SessionDO moves records 101–120 to its side table. Later alarms copy them as `epoch-1/0000000101-0000000120.jsonl`, then write `epoch-2/header.json` with `keep: 80, parent: 1`, then the new records. Records 81–120 of epoch 1 are no longer in the SessionDO, but R2 has them.

### A SessionDO that lost its storage

A bad release wipes a SessionDO. The next handshake finds it empty, and the Mac uploads its file again. The new storage picks a new generation, so its copies go to `…/<session>/<new generation>/`, beside the old ones. The old generation still holds everything that was copied before the loss, including records the Mac no longer has.

## Reference-level explanation

### The SessionDO's copy state

A new last step of `SESSION_SCHEMA` adds:

```sql
CREATE TABLE backup (singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  generation TEXT NOT NULL,     -- a random UUID, taken when this table is created
  due_at INTEGER,               -- when the next copy is due; null when nothing waits
  failures INTEGER NOT NULL DEFAULT 0);
CREATE TABLE backup_epochs (epoch INTEGER PRIMARY KEY,
  keep INTEGER NOT NULL, parent INTEGER,
  through INTEGER NOT NULL,     -- the last cursor of this epoch copied
  header_saved INTEGER NOT NULL DEFAULT 0);
CREATE TABLE backup_pending (singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  kind TEXT NOT NULL, epoch INTEGER NOT NULL, "from" INTEGER, "to" INTEGER);
CREATE TABLE backup_cut (epoch INTEGER NOT NULL, cursor INTEGER NOT NULL,
  hash TEXT NOT NULL, chain TEXT NOT NULL, line TEXT, PRIMARY KEY (epoch, cursor));
CREATE TABLE backup_cut_parts (epoch INTEGER NOT NULL, cursor INTEGER NOT NULL,
  idx INTEGER NOT NULL, data TEXT NOT NULL, PRIMARY KEY (epoch, cursor, idx));
```

A SessionDO with records from before this step gets a `backup_epochs` row for its current epoch with `through = 0` and `keep` from the last row of `cuts` (or 0).

### When copies are made

The copy is behind when an epoch has records after `through`, or needs a header it has not written. Five rules keep it from losing or tangling anything. Each one is a rule in the spec, and the spec checks that each property breaks without it.

1. **`commitArms`: a commit sets the alarm.** `append` and `truncate` set `due_at` to now plus `BACKUP_DELAY` (an hour) if it is null, in their transaction, and make sure the alarm is set for the earliest thing due.
2. **`oneAlarm`: one alarm for both jobs.** A Durable Object has one alarm, and `setAlarm` replaces it. ATXF translation sets it for now (`catchUp`, `translateAfterAppend`), which would replace an alarm set for the copy. So nothing calls `setAlarm` directly any more: a `scheduleAlarm()` helper sets it to the earliest of "now, if records wait for translation" and `due_at`. The alarm handler translates if translation waits, copies if a copy is due, and calls `scheduleAlarm()` on every way out.
3. **`outbox`: the range is written down before the PUT.** The handler takes the next copy, oldest epoch first (a header, then a chunk from `through + 1`), and writes it to `backup_pending` before it sends the PUT. A retry sends the pending copy, not a new one. Without this, a PUT that succeeded but whose answer was lost would be followed by a longer one from the same cursor, and R2 would hold two chunks that overlap.
4. **`cutKeepsUnbacked`: a cut keeps what the copy lacks.** `truncate`, in its transaction and before deleting, copies every record of the current epoch after its `through`, including those at or before `keep`, into `backup_cut`. It then adds the new epoch's `backup_epochs` row with `through = keep`, `parent` the old epoch. The old epoch's copy then reads from `backup_cut`. Its chunks stay contiguous, and the new epoch's start after `keep`. Once a chunk of an old epoch is copied, its rows in `backup_cut` are deleted.
5. **`generations`: keys carry the generation.** The generation is a random UUID made when the `backup` table is first created. A SessionDO rebuilt from nothing has a new one, so its epoch 1 is not the old epoch 1's key.

A PUT uses `onlyIf: new Headers({ "If-None-Match": "*" })` and the chunk's SHA-256 (`sha256` in `R2PutOptions`). It returns `null` when the key exists. Then the handler reads the object's `checksums.sha256` with `head()`. Equal means an earlier try stored it, and the copy moves on. Different stops the copy for this Session and logs `session.backup_refused`. By rule 5, that cannot happen unless something else wrote into the bucket.

After a copy is stored, one transaction advances `through` (or `header_saved`), clears `backup_pending`, deletes copied `backup_cut` rows, resets `failures`, and sets `due_at` to now if more is behind (the rest of a large backlog goes at once, one chunk per alarm), or null.

A failed PUT is caught, not thrown. Alarms retry a throwing handler only six times. The handler raises `failures`, sets `due_at` to now plus `min(2^failures minutes, 1 hour)`, and logs `session.backup_failed`.

An alarm that runs while another request is in the object sees the same storage. The handler's checks are re-read after each `await`, as `append` already does (the spec lets appends and cuts land while a PUT is out).

### Sessions stored before

A HostDO schema step adds `session_index.backup_armed INTEGER NOT NULL DEFAULT 0`. On each handshake (`AxoHostDO.sync`), after answering, the HostDO calls the new `AxoSessionDO.armBackup(binding)` for up to 64 rows with `backup_armed = 0`, missing ones included, 16 at a time, and sets the flag for each answer. `armBackup` sets `due_at` to now if the copy is behind. The 202 Sessions are armed by the first handshakes after the release. Each SessionDO then copies itself, a chunk per alarm.

### Eviction waits for the copy

RFD0027 evicts an archived Session's file once the cloud's count and chain match the file's. With this RFD the cloud is not one copy but two, and eviction waits for the second. The SessionDO's head and append answers carry `copied`, the copy's `through` for the current epoch (`SessionHead.copied`, `appendResultSchema`). axod evicts only when `copied == count`. Until a Mac's axod knows `copied`, it does not evict.

### Restoring

`src/session-backup.ts` exports `restoreEpoch(list, get, generation, epoch)`. It reads the epoch's header, then its parent's first `keep` records (recursively), then its chunks in order. It refuses a gap or an overlap, and checks every record with `pi3RecordHash` and `pi3FoldChain` from the header hash, as `append` does. It returns the header and records an `append` would take. The tests rebuild a SessionDO from it in Miniflare and compare heads.

### Cost

From the measurements above, at R2's and Durable Objects' published prices (`r2/pricing`, `durable-objects/platform/pricing`, read 2026-11-12):

| | Copy hourly (this RFD) | Copy every append |
|---|---|---|
| R2 PUTs a month | about 5,400 (7.5 Sessions × 24 h × 30) | about 1.1 million (one per append; the uploader sends records as they come, `BATCH_RECORDS` 64) |
| Alarms a month | about 5,400, billed as requests | none extra |
| Cost of operations | inside the free tier (1M Class A, 1M requests) | about $0.50 past the free tier, and growing with use |
| Objects to read to restore a Session | tens | thousands |
| Storage | about 2.5 GB, about $0.04 a month in R2 ($0.015/GB) | the same |

The SessionDO already holds the same bytes in SQLite at $0.20/GB-month, so the copy adds about 7% to storage cost.

### Observability

- `session.backup_copied` `{ epoch, from, to, bytes, ms }`, `session.backup_failed` `{ epoch, failures, error }`, `session.backup_refused` `{ key }`, through `recordApiEvent`.
- Workers logs are sampled at 1% (`headSamplingRate` in `cloudflare.config.ts`), so logs alone will not show a failing Session. The HostDO keeps each row's `copied` from the answers it already gets (`refreshHead`). `GET /api/v1/account/backups` lists the account's Sessions whose copy is more than two hours behind, for the deploy check and the alert (Unresolved questions).

### Testing

- **Unit:** `restoreEpoch` on hand-made objects: one epoch; a cut with a parent; a gap; an overlap; a wrong hash; a wrong chain.
- **Worker, Miniflare** (`tests/session-backups.test.ts`, with an R2 binding):
  - append then fire the alarm: one chunk, and a restore equal to the SessionDO;
  - a backlog of 5,000 records copies in chunks, oldest first;
  - a cut before the copy: both epochs restore;
  - a PUT that fails, then succeeds: the same key;
  - a stored PUT whose answer is lost (a stub that stores, then throws): the retry finds the same bytes and moves on;
  - translation and a due copy share the alarm;
  - eviction (`unsafeEvictDurableObject`) between the outbox and the PUT;
  - a wiped object (a new SessionDO name standing for it) writes under a new generation;
  - backfill arms each index row once.
- **End to end:** `tests/session-backups-e2e.test.ts` with a real axod: a Session written, cut and evicted restores from R2 alone.
- **Spec:** `feynman check sessions/backups` in CI, with `sources` filled in as the code lands.

### Rollout

1. Create the bucket and declare it in `cloudflare.config.ts` (`SESSION_BACKUPS`). If `cf deploy` does not create a missing bucket, create it once with `cf r2 buckets create axo-session-backups`.
2. Release the Worker. The first handshakes arm every Session.
3. Check: `GET /api/v1/account/backups` empties within a few hours; restore three Sessions (the largest, one with a cut, one archived) from R2 into Miniflare and compare their heads with production.
4. Release axod with eviction waiting for `copied`.
5. Turn on a bucket lock (Unresolved questions).

## Drawbacks

- **An hour of records can be lost** if a SessionDO loses its storage between copies. For most Sessions the Mac still has them. An archived Session is not written to, so it has nothing uncopied.
- **One more thing shares the alarm.** Translation and copying in one handler is more to get right. Rule 2 and its test exist because of it.
- **Copies of cut records stay forever.** That is the point, but it means a cut never frees space in R2.
- **A second copy of every Session** is a second place private conversations live. It is a private bucket in the same account, with the same encryption at rest as the SessionDO.

## Alternatives

- **Copy on every append.** About a thousand times the R2 writes for the same data, thousands of small objects per Session to restore from, and a PUT on every commit's path. An hour is a fine RPO for a second copy.
- **A Worker cron that walks every SessionDO.** It would wake every Session, written or not, and needs a list of all of them. The alarm wakes only Sessions that changed.
- **Mutable objects (one file per Session, rewritten).** Simpler to read, but every copy rewrites the whole Session (up to 118 MB), and a bucket lock would forbid it.
- **Durable Objects' point-in-time recovery.** It restores an object's storage to any moment in the last 30 days. That helps with a bad write, but not a deleted namespace, nor anything older than 30 days, and it stays inside the same system.
- **Reuse `axo-sessions`.** It holds old `archived/<session>.jsonl` objects from 2026-10-28, from before RFD0018. They may be the only copy of some Sessions, so this RFD leaves them alone (Unresolved questions).

## Unresolved questions

Before acceptance:

- **Is an hour the right delay?** (a) An hour: about 5,400 copies a month. (b) Ten minutes: about six times as many, still inside the free tier, and ten minutes of loss at worst. (c) A day. Recommendation: (a). The Mac holds what a SessionDO has not copied, except for Sessions it evicted, which are not written to.
- **A bucket lock?** (a) None. (b) A lock on `accounts/` for, say, 30 days: nothing, not even a bug or a leaked token, can delete or overwrite a copy for 30 days, and deleting a person's data stays possible after that. (c) Indefinite. Recommendation: (b), once the first copies have been checked.
- **The preview Worker** (`axo-public-app-preview`) shares the other buckets. (a) A second bucket, `axo-session-backups-preview`. (b) The same bucket; generations keep their keys apart. Recommendation: (a), so preview data never sits with production's.
- **How we hear about a Session that stops copying.** (a) Only `GET /api/v1/account/backups`, checked after deploys. (b) That, plus axod asking for it daily and showing a warning in the Mac app. (c) Workers Analytics Engine, unsampled, with a query we check. Recommendation: (a) now, (b) next.

During implementation:

- Whether `cf deploy` creates a bucket that `bindings.r2` names and the account lacks.
- Whether the alarm handler should copy more than one chunk per run for a large backlog. One per run is simplest; the measured backlog is 202 Sessions of up to 118 MB.

Out of scope:

- What to do with `axo-sessions` and `axo-session-files`. Compare their objects with the SessionDOs, keep what exists nowhere else, and delete them only after that, in its own change.
- Backing up the rest of the account.

## Future possibilities

- **R2 as the long-term home.** Archived Sessions could leave their SessionDO once copied, and be read back from R2 when opened, like RFD0027 does on the Mac. That lowers storage cost and makes RFD0043's hub a cache in front of R2.
- **Backups for AXP logs.** RFD0043's §9.4 side table for forked records is `backup_cut` by another name. Phase 3d can use one table for both.
- **Exports.** A person could download every Session they have as the same objects.
