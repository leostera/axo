# Private Axo API

The first isolated implementation slice of [RFD0008](../../docs/rfds/RFD0008-private-multi-machine-control-plane.md): a Cloudflare Access-protected machine directory and per-machine WebSocket relay using the proper [`@axo/protocol` package](../../protocol/README.md). Its `json-rpc-2.0` dependency handles local service method dispatch and dummy-client correlation; Axo's schemas, leases and durable relay coordination remain separate.

**Deployed private canary** on Cloudflare as `axo-api` at `https://api.axo.leostera.dev/` with separately provisioned Access policies. The normal-system-DNS live route is validated: dedicated Access service-token WSS registration, authenticated client discovery/runtime listing, a real approved-profile PTY launch, durable receipt reconciliation, client disconnect/reconnect and cold-restart generation fencing. This is supervised connectivity evidence, not unattended/native/Pi readiness. The existing `service/`, R2 namespace, Mac packaging/startup, live registry and running application sessions remain unchanged. This is the next iteration of the existing private relay, not an account/enrollment platform or cloud executor.

## Module layout and Vite

`cf build` delegates to the configured Cloudflare Vite plugin. Vite bundles the complete module graph; multiple source files do not require multiple Worker deployments. [`src/index.ts`](src/index.ts) is only the entry-point export surface:

- [`src/http/router.ts`](src/http/router.ts): public route selection, Access admission and trusted internal WebSocket context.
- [`src/http/rpc.ts`](src/http/rpc.ts), [`src/http/body.ts`](src/http/body.ts): discovery dispatch and bounded body decoding.
- [`src/axo-host-directory.ts`](src/axo-host-directory.ts): `AxoHostDirectory`, the bounded machine/principal projection and registration reservations.
- [`src/axo-host-relay.ts`](src/axo-host-relay.ts): `AxoHostRelay`, the single per-host actor coordinating leases, hibernating sockets and durable correlations.
- [`src/relay/peer.ts`](src/relay/peer.ts), [`src/relay/records.ts`](src/relay/records.ts): validated socket attachments and named SQL record types.
- [`src/access.ts`](src/access.ts): JWT signature/claim/role validation.
- [`src/observability.ts`](src/observability.ts): allowlisted, metadata-only event logging.

The named Durable Object exports are deployment/storage identities, not cosmetic names. They were renamed before the first deployment; future renames require an explicit migration rather than silently replacing storage.

## Implemented boundary

- The Worker verifies RS256 Access JWT issuer/audience/expiry/application type and distinct client/daemon identities. Public headers cannot claim internal roles. Native WebSocket connections reject browser Origin headers.
- Authorized daemons connect outbound to `/v1/machines/{machineId}/daemon`; authorized clients connect to `/v1/machines/{machineId}/client`. Both negotiate profile 1.
- Authenticated machine registration automatically publishes machine discovery. No pairing, account creation or enrollment UI is involved. Directory reservations prevent arbitrary creation of unregistered relay objects; reserved-but-unregistered slots are not discoverable.
- The directory and per-machine relay use independent SQLite Durable Objects and accepted WebSocket hibernation. Connection attachments hold bounded identity/credit metadata; SQLite holds membership, lease and pending correlation facts, not queued execution payloads.
- Machine identity is durable; daemon boot generation and relay connection lease are fresh fences. A duplicate live connection is rejected. Expiry/close never deletes local work or claims old children died.
- JSON-RPC `POST /v1/rpc` implements bounded `axo.machine.list` discovery. Relayed `axo.runtime.list` and `axo.runtime.startApproved` reach the same Rust dispatcher/runtime owner used by the native loopback JSON-RPC WebSocket.
- Remote starts resolve an operator-configured named launch profile; there are no remote argv/cwd/shell parameters. Durable daemon receipts prevent duplicate starts.
- Responses contain bounded structured terminal **metadata**, never terminal/audio/file bytes. A current response source generation does not rewrite historical runtime references.
- Control-call deadlines are at most 10 seconds, machine leases at most 30 seconds/auth expiry. Missing replies are unknown outcomes; nothing is replayed on reconnect. Client/daemon frame delivery has explicit 32-frame/128-KiB credits.

Current private Access policy accepts one human email and one daemon service-client ID. Several machines may use that credential, but it is not hardware identity and has shared compromise/revocation scope. Distinct per-host credentials and operator binding/rotation policy remain production configuration work; no product account/enrollment mechanism is implied.

Offline registrations and incomplete bounded reservations are retained; operator forget/removal/retention tooling is not yet implemented. Revocation detection is bounded by observed JWT/gateway behavior, not an immediate-revocation promise. Error messages/logging must not expose tokens, prompts, paths, raw frames or transcript bodies. Access/WSS are not E2EE.

## Build and test without deployment

Install the repository dependencies, the standalone protocol package, then this site's packages. The site declares `@axo/protocol` as a local package dependency; it never imports its sibling TypeScript sources:

```sh
# From Axo root
npm ci
npm --prefix protocol ci
npm --prefix protocol test
npm --prefix sites/api.axo.leostera.dev ci
npm --prefix sites/api.axo.leostera.dev run typecheck
npm --prefix sites/api.axo.leostera.dev run build
npm --prefix sites/api.axo.leostera.dev test
```

The suite uses **Node test + Miniflare/workerd**, not a new test-framework migration. The site pins `workerd` 1.20261009.1 because the installed Miniflare alpha's default binary only supports the older compatibility date. Tests exercise the same 2026-10-09 target as the `cf` configuration. Miniflare v5 persistence is configured with `resourcePersistencePath`; the legacy `durableObjectsPersist` field was silently ignored by its converter. Whole-runtime restart tests verify real SQLite recovery rather than assuming repeated calls prove persistence.

### API in isolation

Tests open actual network sockets to the Worker. They sign ephemeral Access-shaped JWTs with a test RSA key and supply only a test JWKS through Miniflare's isolated outbound handler. No production auth bypass/test mode exists in the Worker; public validation remains in the path. Fake daemon endpoints are explicitly protocol fixtures, not claimed process/Pi execution.

Coverage includes invalid/forged/expired/ambiguous roles, multi-machine discovery, duplicate connections, case-normalized identities, request ID isolation, batches/null IDs/notifications, stale targets, malformed/oversized frames, delivery/deadline exhaustion, hibernation with pending/partial batches, cold service restart, generation pinning and no phantom active routes.

### API with real axod

`tests/axod.test.ts` builds the Rust daemon offline and starts two actual `axod` processes in owned, private `/tmp/axo-fleet-*` roots. The same dummy client sends authenticated requests through the Worker to the outbound daemon sockets. It tests:

1. Registration/discovery/listing with no launch side effects, including the standalone CLI client.
2. An approved profile spawning the real isolated Python PTY fixture.
3. Same command receipt returning the same runtime, conflicting arguments failing and arbitrary argv being rejected.
4. Machine routing independence and no inherited extra descriptors/`AXO_*` configuration.
5. Client reconnect preserving runtime identity.
6. Cold daemon restart preserving machine/receipt identity, using a fresh source generation and retaining historical runtime references without relaunching work.
7. Fixture ticks advancing **after** API shutdown has completed: cloud loss does not kill the PTY.
8. A SwiftPM end-to-end test using the Swift package's Codable request/response contracts over `URLSessionWebSocketTask`, through the protected test Worker to a real `axod`. It negotiates, lists, starts an approved profile, retries the same command ID and verifies the typed runtime snapshot plus the owned PTY fixture.

The Swift test gets its short-lived client assertion from a mode-0600 file in the test's temporary directory. It does not contact the deployed API or use deployment credentials. A plain `swift test` skips this network test unless the harness variables are provided; `npm test` in this site runs it as part of the real-`axod` suite.

Cleanup signals only the owned test daemon handles. It does not signal historical snapshot PIDs, open live Mac state, fabricate Pi history or deploy resources. macOS, a Rust toolchain and cached crates are required for the real-daemon test. Pure API tests can be selected separately with `tsx --test tests/api.test.ts tests/lifecycle.test.ts tests/limits.test.ts`.

## Reusable dummy client

The CLI supports a local development endpoint or, after separately approved provisioning/deployment, `https://api.axo.leostera.dev/`. Supply an authorized human Access JWT in an owned, single-linked mode-0600 file. The token is never a command-line argument or printed value:

```sh
npm --prefix sites/api.axo.leostera.dev run smoke -- \
  https://api.axo.leostera.dev/ /absolute/private/client.jwt

# Read one explicit machine; no selected-machine fallback
npm --prefix sites/api.axo.leostera.dev run smoke -- \
  https://api.axo.leostera.dev/ /absolute/private/client.jwt --machine MACHINE_UUID

# Explicit mutation, using a profile configured on that daemon
npm --prefix sites/api.axo.leostera.dev run smoke -- \
  https://api.axo.leostera.dev/ /absolute/private/client.jwt \
  --machine MACHINE_UUID --start-approved PROFILE_ID
```

Discovery is the default. A mutation prints its complete non-secret command identity/target/profile before dispatch for reconciliation, and is attempted once only. Quitting the CLI leaves accepted work running. Local tests require the explicit `--allow-loopback` flag and a numeric loopback HTTP URL. Both transports reject credential-bearing URLs and redirects. The client uses the library's request correlation with bounded pending IDs, and raw fixture helpers for explicit batch/negative tests. It is not a production native client or retry queue.

## Daemon configuration

See [`axod/README.md`](../../axod/README.md) for the opt-in `--relay-config` launch. Production uses Access service-token credentials; ephemeral assertion credentials are useful for bounded test/tool sessions and do not auto-refresh. Keep configuration private and outside argv/environment. Neither opening the Mac app nor reading the directory launches a configured daemon.

`cloudflare.config.ts` declares only the new custom domain and its own SQLite exports—no legacy relay/file bindings. Access issuer/audience/email/client ID are public policy configuration, not credentials; the service-token secret and human JWT remain in owned mode-0600 files outside the repository. Build/type generation/deployment use the **`cf` CLI**. The client supplies a `CF_Authorization` cookie for the Access gateway as well as an assertion header for isolated tests; the Worker independently verifies the gateway assertion. No automatic redirect or execution retry is enabled.

Observability, invocation logs and traces are enabled. Trace sampling is 100% for this private canary; review volume/cost before broader use. Application events contain only allowlisted event names, roles, known method names, numeric close codes and reply/unknown dispositions. Do not add credentials, identities, URLs/query strings, raw exceptions, payloads or transcripts to diagnostics. A logged reply is not a claim that execution succeeded.

The dedicated deployed-test daemon service token expires **2026-10-10T23:19:31Z**. Rotation/replacement must update both the new Access Service Auth policy and `ACCESS_HOST_CLIENT_ID`; do not reuse or modify the legacy Mac relay token. The cloud Worker stays deployed when the isolated fixture daemon is stopped.

## Deployed connectivity evidence — 2026-10-10

The isolated release daemon connected to the live hostname using ordinary system DNS and native-root TLS verification. No resolver/address override, CA-file override or certificate-verification bypass was required. Live validation also rejected human credentials on the daemon route, verified one running PTY after explicit reconciliation of a confirmed launch receipt, observed local fixture progress after client disconnect, and recovered the same runtime through a fresh client. Cold daemon restart preserved machine identity, changed the source generation, rejected the old source target, retained historical runtime references and launched no work automatically.

This test exposed two real-boundary defects: tungstenite's Rustls dependency had no crypto provider selected; the initial `ring` choice did not support the corporate proxy's P-521 CA signatures. The daemon now explicitly selects Rustls's standard AWS-LC provider, with a configuration/algorithm regression test. A Darwin networking control descriptor also escaped CLOEXEC-only isolation; the fork child now closes nonstandard descriptors up to a validated, bounded kernel allocation ceiling before exec, including descriptors created by libraries. An intentionally inheritable descriptor regression covers that boundary.

The initial fixture command exposed the descriptor defect and was stopped through its owned daemon. Patched validation used a fresh, explicitly saved command identity; neither command was automatically replayed, and both receipts were retained. The final fixture daemon was stopped after cold-restart checks; live discovery reported it offline. The API remains deployed.

Validation passed: 23 Rust tests, strict Clippy, release build, 13 daemon process tests, 7 protocol package tests, API typecheck and all 19 API tests. Only fixture PTYs were launched. No Pi session, native app, legacy relay or file authority was touched. Complete API-shutdown/local-progress evidence comes from the isolated real-Worker/two-daemon suite, not an outage imposed on the deployed Worker. Credential files and fixture intent/evidence stay private outside the repository.

## Local/cloud parity checkpoint — 2026-10-10

The Unix listener/legacy envelope is removed. `axod serve` now publishes private boot-fenced loopback WebSocket discovery. At the user's request, there is **no local credential or application-auth layer**; exact numeric Host/path and no-Origin checks block browsers but do not authorize OS users. Access remains the existing cloud edge gate, without an application account/user-management product.

The real-Worker fleet suite now launches through a Mac-style local WebSocket and reconciles/observes that same runtime through the API's remote client route, using one manager/journal. It also verifies local RPC after complete test API shutdown. A release-daemon live-hostname smoke passed local launch, remote runtime/receipt identity, one running PTY, descriptor/config isolation and progress after both clients quit. A latest-release restart also confirmed stable machine/fresh source identity, stale-target rejection, unchanged historical runtime/receipt and no automatic launch. The owned fixture daemon was stopped; live discovery confirmed offline/null source generation while the API remains deployed. Neither native UI nor real Pi was involved. See [local bootstrap](../../protocol/README.md#local-bootstrap) for the native-client contract.

Process regressions were moved from the removed Unix harness to real JSON-RPC process tests and transport-independent real-PTY manager tests. No old request-ID cache/input replay semantics are claimed for the new profile; input is not exposed. Final validation passed 28 Rust tests, seven protocol/package tests and 25 API/local/fleet tests, strict Clippy, release build, schema check, API typecheck/build and changed documentation link checks.

## Next slices, not claimed complete

- Native client/bootstrap integration using the local/remote RPC contracts.
- Daemon-owned workspace/session catalogs, admitted vanilla Pi prompt/history/status and structured subscriptions.
- Additional mutating methods only after their durable receipts/reconciliation are defined; this slice has no remote stop method.
- Operator forget/credential rotation, publication/retention policy and production backoff/rate-limit tuning.
- Single-writer R2/file authorization migration, then coordinated native clients/packaging/ownership cutover after daemon hardening.
- Native Mac/physical-phone and real Pi acceptance; the deployed fixture route does not establish these.
