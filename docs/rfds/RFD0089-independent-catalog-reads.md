# RFD0089 - Axo: independent catalog reads

- Feature Name: `independent-catalog-reads`
- Status: Implemented
- Author: leostera
- Start Date: 2026-11-20
- Document Type: Implementation design
- Amends: [RFD0041](RFD0041-axod-session-tasks.md)

## Summary

Keep one serialized SQLite writer with WAL and `synchronous=FULL`. Add one
read-only WAL connection on its own worker for catalog/archive inspection.
Local and relay catalog reads no longer queue behind a slow durable mutation or
transcript eviction. This is not a second writer, a cached catalog, or a weaker
commit policy. There is no schema or wire change.

## Motivation and guide

Two Session creation calls timed out while concurrent catalog requests took up
to 44.8 seconds. Both named creations subsequently had persisted open records.
The existing Store sends every SQL operation through one FIFO worker, including
catalog reads; a blocked mutation therefore also prevents clients from checking
what exists. A live thread was observed waiting for a filesystem journal commit.
The server directory is on an ext4 rotational volume. That does not prove all
delay originates there, but head-of-line blocking follows
directly from the single queue in `crates/axo-server/src/store.rs`.

When a write is slow, a client can still inspect the previously committed catalog.
After the writer acknowledges a commit, the next read sees it. While a transaction
is uncommitted, the reader sees its prior committed snapshot, never partial rows.
An absent row is still not permission to retry an uncertain create: pending calls
can commit later. Idempotent creation and global storage latency remain separate
problems.

## Reference contract

`axo-store::open_reader` returns a distinct read-only connection type, rejecting
non-WAL or non-current-schema catalogs. It opens read-only, without creating
or migrating it. The read connection has query-only mode and the same bounded
SQLite busy timeout. The writer's foreign-key, WAL, FULL-sync, ownership and
migration configuration stays unchanged. Bootstrap opens the reader only after
the writer has completed migration and startup reconciliation.

Store owns two cheap-to-clone worker handles. Existing `call` operations retain
their serialized ordering on the writer, including settings, mutation-dependent
checks, transcript eviction and cursor allocation. An explicit `read` accessor
runs catalog-only SELECTs in a read-only transaction on the reader, explicitly
rolled back on success or failure. No transaction or borrowed row escapes a read
closure, so later reads acquire fresh WAL snapshots. Local archive listing
and relay archive/cloud-presence lookup use this lane. Open runtime state remains
the existing watch catalog; there is no duplicate mutable catalog/cache.

Opening the reader is fallible and startup fails explicitly if its contract cannot
be established. It never falls back to an empty archive or a write-capable reader.
One extra connection/thread is retained per core, not per caller. No runtime
restart, data migration, credential change or personal Session mutation is part
of development/acceptance.

## Tests and limits

On private files, hold an uncommitted write transaction behind a test barrier and
prove a catalog read completes before releasing the writer. Require old committed
values during that transaction and fresh values after its acknowledged commit.
Prove SQL writes through the read lane fail, opening it cannot create a missing
catalog, and the writer remains WAL/FULL. Cover actual local and relay catalog
paths with the existing suites. Do not disable fsync or introduce artificial load
on the person's live database.

A read can still wait on the filesystem or SQLite locks; this removes queue
coupling, not all I/O latency. The two-connection catalog and watch state do not
become one atomic cross-runtime snapshot; the existing API already combines
separately observed stored/runtime state. Long readers could delay checkpoints,
so only materializing catalog SELECTs are moved, not transcript streaming.

## Alternatives

A second writer complicates ordering without fixing durability latency. Disabling
FULL sync loses acknowledged-data guarantees. A cache needs invalidation and
recovery rules while SQLite WAL already supplies committed snapshots. Returning
only open Sessions or silently dropping archived results would change the API.
