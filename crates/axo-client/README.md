# Shared local axod client

`//crates/axo-client:axo_client` is the Rust transport used by the shipped CLI and
Linux native workbench. It is extracted from the CLI, not a CLI subprocess wrapper,
new daemon, session store, account manager or application-authentication scheme.

- Negotiates the existing protocol and checks advertised request methods.
- Limits outgoing requests to 8 MiB and incoming newline JSON frames to 32 MiB;
  checks JSON-RPC version, matching IDs, and exactly one result/error.
- Never retries writes. Cancellation, malformed replies and transport failures
  discard the connection so a late reply cannot become another request's result.
  Ordinary RPC rejections preserve an aligned connection. Callers own operation
  deadlines; connect/negotiation/stream-opening also have five-second bounds.
- Settings reads/writes check that replies name the requested key. Commands/ranges
  remain daemon-validated and persisted; a lost write acknowledgement is unknown,
  not failure proof. The GTK caller requires reload before offering a retry.
- Opens event streams as the first request on their own connection; parses batches
  into shared protocol events and ends lagged/cancelled/invalid subscriptions.
  Consumers must relist and resubscribe, not display stale state as live.
- `LocalCatalog` parses the existing catalog into a native-renderable boundary:
  unique Session/pane identities, layout references within their owning Session,
  absolute advertised attach sockets. Missing layouts remain a readiness state;
  unshown panes are allowed. It does not invent a competing layout or database.
- `CatalogWatch::channel()` supplies a bounded latest-state receiver and a single
  `CatalogWatcher` to run on the caller's runtime. The watcher establishes its RPC
  connection, subscribes **before** catalog/health reads, and treats catalog events
  as invalidations, never stale snapshot patches. Reads have a five-second deadline;
  bursts coalesce for 100 ms; EOF/lag/invalid frames reconnect with 250 ms–5 s backoff.
  Idle catalogs are not polled. Manual refresh preserves the pending event-read
  future, because cancelling `EventStream::next` deliberately poisons that stream.
- Every new subscription gets a new epoch even if IDs/PIDs/paths are unchanged.
  Native consumers must invalidate old attachments on an epoch change, including
  when latest-state delivery coalesced the intermediate disconnect. Daemon readiness
  comes from health/`daemon.ready`, not receipt of a catalog alone. Dropping the
  receiver cancels bootstrap, idle reads and backoff. This owner only negotiates,
  subscribes and reads catalog/health; it never retries actions, starts Pi or
  supplies privileged local identity.

A private socket/same UID does **not** grant privileged-app identity. This client
never impersonates `Peer::Relay`, launches/upgrades axod, reads credentials or
changes pairing. Native workbench policy and presentation remain separate from
wire framing. Swift currently retains its existing native client implementation.

Run `bazel test //crates/axo-client:test //crates/axo-cli:all` (the CLI e2e target
requires the platform daemon build dependencies).
