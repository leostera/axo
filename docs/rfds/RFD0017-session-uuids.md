# RFD0017 - Axo: Sessions are identified by UUIDs

- Feature Name: `axo-session-uuids`
- Status: Implemented
- Author: leostera
- Start Date: 2026-10-29
- Updated: 2026-10-30
- Document Type: Proposal

## Summary

I propose that a Session's identity everywhere, in Axod's catalog, the local protocol, the host relay, the cloud, the web, the phone and the Mac app, becomes the UUID Axod already gives every new Session (`session_uuid`), and that the SQLite integer stops existing. `sessionId` keeps its name on the wire and changes type from a positive integer to a lowercase UUID string; the redundant `sessionUuid` field goes away. Axod's catalog is rekeyed by the UUID in one local migration that runs once, gives the 111 older Sessions that have no UUID a new one, and rewrites the shells that point at them. The protocol version goes from 1 to 2 so a mismatched Mac and cloud refuse each other clearly. Shell IDs stay integers. This is a narrow cutover timed with the relay and connection changes already in flight (RFD0016), not a compatibility layer.

## Motivation

Integer Session IDs come from `INTEGER PRIMARY KEY AUTOINCREMENT` in one Mac's `axo.db` (`crates/axo-store/src/lib.rs`). They are unique only within that file and only while it lives. Every place they now leave the Mac assumes more than that:

- **Cloud history is keyed by them.** Each Session's Pi events are stored in a Durable Object named `<account>:<host>:<integer>` (`sessionDOName`, `packages/axo-api-worker/src/session-history.ts`), with no automatic expiry, and its `session_identity` row pins that integer. If a Mac's database is lost, reset or reinstalled while the host keeps its pairing, the counter restarts and new Session 1 is fenced into, or shown, old Session 1's history. The cloud cannot tell the two apart.
- **Cloud catalogs are keyed by them.** `host_sessions_v1` in the account manager and in the host directory has `PRIMARY KEY (host_id, session_id INTEGER)`; the same restart overwrites one Session's snapshot with another's.
- **Clients have to carry the Mac alongside.** The web routes chats as `/app/<hostId>/<integer>` (`packages/axo-web-app/src/chat/route.ts`) and the phone and relay address `(host, sessionId)` pairs. An integer cannot name a Session on its own, so anything account-wide must always carry both: RFD0016's call log records the "calling Session", and sharing (`/axo-share`) records a share against a Session.
- **Two identities already exist.** Axod generates a v4 UUID for every new Session (`new_uuid_v4` in `crates/axo-server/src/session/workspaces.rs`), and Pi already knows its Session only by that UUID: `AXO_SESSION_ID` is the UUID (`crates/axo-pi/src/launch.rs`), the transcript is `<uuid>.jsonl`, the bridge token is keyed by it, and `axod mcp` connects with it and translates to the integer (`crates/axo-server/src/mcp.rs`). The wire exposes the UUID as an optional `sessionUuid` beside `sessionId`. Code has to know which identity each surface wants, and the Swift `SessionID` doc comment says a secondary identity like `sessionUuid` "is not needed" because integers are never reused, which is true only inside one database.

The relay is being reworked now (fragments, `axo.connections.*`, host capabilities), and every client ships together with Axod except the cloud, which is deployed by the same person. This is the cheapest moment the change will ever have.

## Goals

- One identity per Session, the same on every surface: a UUID that no other Session, on any Mac or after any reset, will have.
- Existing Sessions keep their identity where they already have one: the UUID their Pi transcript, bridge token and socket path already use.
- Older Sessions without a UUID get one, once, in a local migration.
- A Mac and a cloud that disagree on the format refuse each other with a clear error, rather than mis-parsing.

## Non-goals

- Shell (pane) IDs. They never leave their Session, appear only together with a Session ID, and are not stored in the cloud. They stay `ShellId` integers; `shells.session_id` just changes type.
- Workspace IDs. They are UUIDs already (`workspaces.workspace_id TEXT PRIMARY KEY`).
- Time-ordered IDs (UUIDv7). Existing Sessions keep their v4 UUIDs, so ordering by ID would mean nothing for them; ordering uses `created_at`.
- Migrating cloud history. It is in a developer-only phase (RFD0013/RFD0014 status); integer-keyed Session Durable Objects are left unread, not moved.
- Accepting both formats. There is no period in which integers and UUIDs are both valid.

## Guide-level explanation

A Session is named by its UUID, everywhere:

```json
{ "method": "axo.session.close", "params": { "sessionId": "2f5c3a1e-8d4b-4c6a-9e1f-0b7d3c2a5e41" } }
```

The same string is what Pi sees in `AXO_SESSION_ID`, what the transcript is called, what `axod mcp` tools accept (or `"self"`), what the relay forwards, what names the Session's history in the cloud, and what the web puts in its URL:

```text
https://axo.leostera.dev/app/<hostId>/2f5c3a1e-8d4b-4c6a-9e1f-0b7d3c2a5e41
```

A Session ID alone identifies the Session across the account; `hostId` stays in URLs and relay calls only because it says which Mac to route to.

The first time the new Axod starts on a Mac, it backs up `axo.db`, gives every Session without a UUID a new one, and rekeys the catalog by UUID. Open Sessions are unaffected: they all have UUIDs already. Nothing in the Pi transcripts changes. The Mac app forgets which Session was last selected (it was stored as an integer) and opens the default one.

A Mac still on protocol 1 that connects to the updated cloud is refused at host registration with "this Mac's Axo is out of date"; an updated Mac against an old cloud is refused the same way in the other direction.

## Reference-level explanation

### Identifier format

A Session ID is an RFC 9562 UUID in its canonical text form: lowercase hexadecimal, hyphenated, 36 characters. Parsers accept only that form and reject everything else, including uppercase. This matters on Apple platforms: Foundation's `UUID` encodes as uppercase (`uuidString`, and `Codable`), so `SessionID` encodes its own lowercase string instead of relying on `UUID`'s `Codable`. New Sessions keep using v4 (`new_uuid_v4`). Parsing does not check the version, because migrated IDs are v4 too and nothing depends on the version.

### What changes

**Axod catalog (`crates/axo-store`)**

- `sessions.id` becomes `TEXT PRIMARY KEY` holding the UUID; the `session_uuid` column is removed. `shells.session_id` becomes `TEXT NOT NULL REFERENCES sessions(id)`; the `shells_by_session_state` index is recreated.
- Queries that `ORDER BY id` on sessions (open Sessions at startup) order by `created_at, id`.
- Lookups that matched both (`WHERE id = ? AND session_uuid = ?`, binding a Pi session) match `id` only.

**Migration (`user_version` 8 → 9)**

Runs in `initialize_database` inside the existing transaction, before any Session is restored:

1. Copy `axo.db` to `axo.db.pre-uuid` (mode `0600`) unless that file exists. The copy is made before the transaction, using SQLite's backup API so the WAL is included.
2. `UPDATE sessions SET session_uuid = <new v4> WHERE session_uuid IS NULL`, one UUID per row. On the author's Mac that is 111 archived Sessions without a Workspace or transcript; the 279 others keep theirs.
3. Create `sessions_v9` and `shells_v9` with the new types; insert from the old tables with `sessions_v9.id = sessions.session_uuid` and `shells_v9.session_id` taken from a join on the old integer.
4. Check that row counts match and that no `session_uuid` was duplicated (the insert fails on the primary key if one was); drop the old tables, rename the new ones, recreate the index, and set `user_version` to 9.

If any step fails the transaction rolls back and Axod exits with the error; the database and the backup are untouched. The migration runs once: a database at version 9 skips it, and a fresh database is created at version 9 directly.

**Local protocol and events (`crates/axo-protocol`, `schemas/axo.leostera.dev/v1`)**

- `SessionId` becomes a UUID newtype (serde as the canonical string) instead of the `positive_id!` integer; `ShellId` keeps `positive_id!`.
- Every `session_id`/`sessionId` field changes type: requests in `rpc.rs` (including `from_session_id`, `resume_session_id`, `archived_session_ids`), `Event::{SessionRemoved, SessionFocus, ShellActivity, …}`, and `SessionRecord`/snapshots in `model.rs`.
- `session_uuid`/`sessionUuid` is removed from `SessionRecord`, snapshots and `RemoteModels`.
- `PROTOCOL_VERSION` becomes 2. JSON schemas (`common.schema.json` and every schema referencing a Session ID), fixtures, and the Rust/TypeScript parity and conformance tests change with it.

**Axod (`crates/axo-server`, `crates/axod`, `crates/axo-relay`, `crates/axo-pi`)**

- Internal maps keyed by `SessionId` keep working unchanged; the type changes underneath.
- `axod mcp` stops translating `AXO_SESSION_ID` to an integer; its tools take a UUID string or `"self"` (`session_id_schema` loses `"integer"`).
- Prompt provenance (`fromSessionId`) and logs (`target_session_id=…`) carry UUIDs.
- The relay forwards Session IDs as strings; host events carry them.

**Cloud (`packages/axo-api`, `packages/axo-api-worker`)**

- `sessionIdSchema` becomes `z.uuid()` in canonical lowercase form, and `protocolVersion` becomes 2. Host registration refuses any other version with a clear error.
- `sessionDOName(account, host, sessionId)` uses the UUID. History Durable Objects named with integers are not read again and are left as they are.
- `session_identity.session_id` becomes `TEXT`. Since every history object is new, no existing row needs to change.
- `host_sessions_v1` in the account manager and the host directory is replaced by `host_sessions_v2` with `session_id TEXT`; the v1 tables are dropped. A host replaces all its snapshots when it registers, so nothing is lost. The account's host listing, which reads at most 256 snapshots `ORDER BY session_id`, orders by the snapshot's creation time instead.

**Clients (`apple/*`, `packages/axo-web-app`, `packages/axo-app`)**

- Swift `SessionID` holds a lowercase UUID string, encoded as a JSON string; it stops being `ExpressibleByIntegerLiteral` (tests and fixtures use UUID literals) and stops being `Comparable`. `ShellID` keeps the integer `AxodIdentifier`, and the shared protocol is split so only shells use it.
- Mac app: `AxoPreferenceKey.selectedSession` is read as a UUID string. An old integer value is ignored and removed, and the default Session is selected.
- Web: routes are `/app/<hostId>/<uuid>`. An old numeric path falls back to a new chat, which is what an unknown chat already does. Sorting chats by `sessionId` (`workbench.ts`) uses creation time instead.
- Phone: no Session ID is persisted, so this is a type change only.
- Pi (`packages/pi-axo`): no change; it already uses the UUID.

### Invariants

- A Session ID is assigned once, at creation or by the migration, and never changes.
- No two Sessions anywhere share an ID. Before this change, uniqueness held within one `axo.db`. Afterwards it rests on 122 random bits.
- A Session that had a UUID before the migration has that same UUID as its ID afterwards, so its transcript, bridge socket and bridge token still match.
- Every Session ID on every surface is in canonical lowercase form; comparisons are plain string equality.
- Nothing orders Sessions by ID.

### Rollout

1. Land protocol, schema and fixture changes together with Axod, the cloud, the web and the Apple clients in one branch, on top of the in-flight relay work.
2. Deploy the cloud and web. Hosts on protocol 1 are refused until they update.
3. Rebuild and install `dist/Axo.app`. Axod restarts on the new build number, migrates `axo.db`, and registers with protocol 2.
4. Rebuild the phone app.

Between steps 2 and 3, remote access to the Mac is down. That is acceptable for the people using Axo today. `axo.db.pre-uuid` is kept for rollback: put it back and reinstall the previous app.

## Testing

- `axo-store`: migrating a version-8 fixture with both kinds of Session (with and without `session_uuid`, open and archived, with shells) keeps every row and every existing UUID, gives the rest new unique v4 UUIDs, rewrites `shells.session_id`, and reaches version 9. Running the migration again does nothing. A duplicated `session_uuid` makes the migration fail without changing anything. A new database starts at version 9.
- `axo-protocol`: `SessionId` accepts only canonical lowercase UUIDs. Rust and TypeScript fixtures agree. Version 1 is refused.
- `axod` RPC tests and the Swift `AxoClientDaemonInteropTests` run against UUID IDs. The interop suite currently fails at `listSessionSnapshot` (one Session expected, none found), so it needs fixing alongside this change.
- api-worker: history keyed by UUID; a protocol-1 host is refused at registration; `host_sessions_v2` round-trips.
- Web: route parsing and printing with UUIDs; an old numeric URL opens a new chat.
- Mac: an old integer `selectedSession` is dropped and the default Session is selected.
- By hand: migrate a copy of a real `axo.db` and compare.

## Drawbacks

- **A large mechanical diff.** About 1,500 references across Rust, Swift and TypeScript change type at once, which makes the branch hard to review except as "the type changed".
- **Cloud history is left behind.** Integer-keyed history becomes unreachable. That is fine in the current developer phase, but it is a real loss for anyone who relied on it.
- **IDs are no longer readable.** A log line or a bug report says `2f5c3a1e-…` instead of `42`. Short prefixes help people, but code must always use the full ID.
- **Remote access is down between steps 2 and 3 of the rollout.**

## Rationale and alternatives

### Keep the integer inside Axod and translate at the edges

Every surface outside Axod would use the UUID, while Axod and its database keep integers and translate in both directions. The database change is smaller, but it keeps two identities forever and a translation step on every request and event. That is exactly the confusion this RFD removes. `axod mcp` already does this translation, and it is one of the motivations. Rejected.

### Make the cloud key unique without changing IDs

Name history `<account>:<host>:<hostGeneration>:<integer>`, or add the `session_uuid` to the cloud key. This fixes the reset collision for history, but clients still need `(host, integer)` pairs, catalogs collide the same way, and RFD0016 and sharing still lack an account-wide name. Rejected as a partial fix.

### Accept both formats for a while

Clients would accept an integer or a UUID during a transition. All of Axo's clients ship together and the cloud is deployed by the same person, so a transition period only adds code that must later be removed. The protocol version bump gives a clean refusal instead. Rejected.

### UUIDv7 for new Sessions

New Sessions would get sortable IDs. Old Sessions keep v4 IDs, so nothing could rely on ordering by ID anyway, and `created_at` already gives the order. Deferred as a possible later change with no effect on the contract.

### Do nothing

History and catalogs stay one database reset away from showing one Session's conversation under another. Every account-wide feature (connections, sharing, a cross-Mac Session list) has to pair Session IDs with hosts. The cost of changing grows as the protocol settles.

## Prior art

- Workspaces are already identified by UUID strings (`workspace_id TEXT PRIMARY KEY`, RFD0014), and nothing pairs them with a host. This RFD gives Sessions the same model.
- Pi identifies sessions by UUID and names transcripts after them. Axo adopted that UUID for its Session files, which is why most existing Sessions migrate without a new ID.

## Unresolved questions

### Before acceptance

- Delete the integer-keyed history Durable Objects explicitly, or just leave them unread? Leaving them is simpler and costs only storage.
- Should `/axo-share` links carry a short Session ID prefix, as first discussed, now that Session IDs are account-wide? The current design uses a random share ID only.

### Resolved during implementation

- **Shell ID sequence.** The rebuilt `shells` keeps every shell's ID, and `sqlite_sequence` is raised back to the old high-water mark afterwards, so the ID of a shell whose row is gone is never reused.
- **Backup.** `axo_store::open` writes `axo.db.pre-uuid` with `VACUUM INTO` before the migrating transaction (it includes the WAL), only once.
- **Ties.** Sessions created or closed in the same second are ordered by SQLite's `rowid` (insertion order), which the migration preserves by copying in the old integer order. Clients tie-break on creation time, then the ID string, only to be deterministic.
- **Session numbers in the UI.** None were shown except fallbacks such as "Session 42" for an unnamed Session; they now say "Session".
- **Protocol refusal.** `axo.protocol.negotiate` refuses any version but 2 with code `-32010` and a fixed message ("this Mac's Axo and the cloud must both speak protocol 2; update Axo"), which the relay does not replace with "Operation rejected".
- **Swift fixtures.** Test targets give `SessionID` an integer literal (`7` is `00000007-0000-4000-8000-000000000007`) in a test-only `SessionIDFixtures.swift`; the app's `SessionID` has no integer form.

### Out of scope

- Shell IDs as UUIDs.
- Moving existing cloud history to UUID keys.

## Future possibilities

- UUIDv7 for new Sessions, if ordering by ID ever becomes useful.
- One account-wide Session list across Macs, now that a Session ID needs no host to make sense.
