# Private Axo API

This Cloudflare Worker is the Access-protected addressed transport for registered Axod machines. It authenticates client/daemon roles, maintains bounded machine discovery and routes JSON-RPC calls to the addressed daemon. It is not a session executor, transcript store, catalog authority, or retry queue. Shared request/result contracts are in [`@axo/protocol`](../../protocol/README.md); accepted session ownership is in [RFD0012](../../docs/rfds/RFD0012-sqlite-desired-state-and-session-materialization.md).

The repository contains no supported `service/` or `bridge/` runtime. Historic deployment/canary notes do not prove that a live endpoint has the current schema, and editing this repository does not deploy or change Cloudflare resources. No cloud rollout or credential operation is authorized by these development instructions.

## Components

- [`src/http/router.ts`](src/http/router.ts): public route selection, Access admission, and trusted internal WebSocket context.
- [`src/http/rpc.ts`](src/http/rpc.ts): method-role validation and bounded discovery dispatch.
- [`src/axo-host-directory.ts`](src/axo-host-directory.ts): bounded machine identity and registration reservations.
- [`src/axo-host-relay.ts`](src/axo-host-relay.ts): per-machine leases, hibernating sockets, and durable transport correlations.
- [`src/relay/`](src/relay): validated socket attachments, bounded reply groups, and SQL correlation records.
- [`src/access.ts`](src/access.ts): signature/claim/role verification.
- [`src/observability.ts`](src/observability.ts): allowlisted metadata-only logging.

The Worker stores bounded membership, lease, and pending-correlation metadata, not session graphs, prompts, canonical histories, or queued execution payloads. A route timeout, disconnect, or invalid daemon reply after forwarding is outcome-unknown. Reconnect does not replay a request; Axod's operation/input originals are reconciled separately.

## Test lanes

From the repository root:

```sh
npm --prefix protocol test
npm --prefix sites/api.axo.leostera.dev ci
npm --prefix sites/api.axo.leostera.dev run typecheck
npm --prefix sites/api.axo.leostera.dev run build
npm --prefix sites/api.axo.leostera.dev test
```

Tests use Node's test runner and Miniflare/workerd. Worker-level tests use ephemeral Access-shaped identities and explicitly isolated bindings. The real-daemon suites start only their owned disposable `axod` processes in private temporary roots and clean up those handles. They do not contact a deployed API, install/activate helpers, read live machine state, signal historical PIDs, use production credentials, or claim physical-device/Pi UI acceptance.

`npm run test:properties` runs bounded deterministic framing/property campaigns. `npm run test:axod` runs the real-daemon lanes. Rust tests and disposable PTY/Pi execution acceptance are separate; see [`axod/tests/README.md`](../../axod/tests/README.md).

## Authority and security boundaries

- Access is the edge identity gate; this Worker does not implement application account or enrollment storage.
- Client/daemon roles are derived from verified credentials, not caller-supplied JSON or public headers.
- Machine and host-generation values route and fence a request; they are not credentials.
- The local Axod WebSocket is a separate explicit endpoint. Loopback/Host/Origin restrictions block browser access but do not authenticate against other local processes or OS users.
- Runtime absence, socket closure, lease expiry, and missing reply are not proof that accepted work stopped. The Worker never uses these observations to delete work or authorize a retry.
- Logs contain allowlisted event/method/role/outcome metadata only. Do not log tokens, prompts, argv, paths, terminal/audio content, SQL parameters, arbitrary bodies, or raw upstream exceptions.

The private API tests establish bounded routing and transport behavior only. Central native/phone UI parity, cloud deployment, physical-device acceptance, installed-service lifecycle, and stronger crash/VT guarantees are separate gates.
