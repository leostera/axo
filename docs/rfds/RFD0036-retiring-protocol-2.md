# RFD0036 - Axo: Retiring protocol 2

- Feature Name: `axo-retire-protocol-2`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-09
- Updated: 2026-11-10
- Document Type: Proposal
- Amends: [RFD0032](RFD0032-push-delivery.md), [RFD0031](RFD0031-durable-objects-wake-on-demand.md)

## Summary

Every client speaks protocol 3 (RFD0032), and each still falls back to protocol 2 when protocol 3 is refused. This RFD removes protocol 2 in two releases. The first stops the clients falling back. The second removes what only protocol 2 used: the ClientDO's following, notices and record pump, and the HostDO's followers, watchers and notice batches. Removal waits for evidence that nothing speaks protocol 2, gathered as described below.

## Current state (2026-11-10)

Still a draft. Only the evidence instrument is built. Neither release has started, and both wait on the evidence gate below:

- **Built:** the Worker logs `client_hello` with the protocol and the kind of client for each account hello (`packages/axo-api-worker/src/client-do.ts`, `8e55647`). `notice_batch` is still logged.
- **Release A, not started.** axod still falls back (`Protocol::Relayed`, `RELAYED_AFTER_REFUSAL` and `peers.protocol_fallback` in `crates/axo-relay/src/peers.rs`). So do `@axo/app` (`ProtocolRefused` in `packages/axo-app/src/index.ts`) and the Swift `AccountConnection` (`withFallback`).
- **Release B, not started.** `AxoClientDO` still serves protocol 2, and `AxoHostDO` still keeps followers and flushes notice batches (`flushNotices`, `forgetFollower` in `packages/axo-api-worker/src/host-do.ts`).
- **Evidence:** no 7-day window has been recorded in this document yet.

## Motivation

Protocol 2 costs code in four places and requests in one.

- **Code.** The Worker keeps a second delivery path: `AxoClientDO` follows every host, receives each notice batch, and pumps records. `AxoHostDO` keeps `followers` and `watchers`, batches notices for them, and answers `subscribe`, `watch` and `unwatch`. Each client keeps a fallback: axod's `Protocol::Relayed` for 10 minutes (`RELAYED_AFTER_REFUSAL`), `@axo/app`'s `ProtocolRefused`, and the Swift `AccountConnection`'s protocol 2 path. Every change to delivery is made, and tested, twice.
- **Requests.** Billable Durable Object requests fell about 90% when clients moved to protocol 3 (RFD0032, Cost). What protocol 2 still costs is small but not zero: `ClientDO.notify` was still called after every client had moved. One ClientDO received notices at 21:38 and 00:03 UTC on 2026-11-08/09, from about 200 calls in six hours, extrapolated from a 1% sample.

## Guide-level explanation

Nobody should notice. A client that cannot speak protocol 3 stops working instead of falling back. By then no such client exists. The web app reloads to the current release, and the Mac and phone apps update.

## Reference-level explanation

### Evidence before removal

Removal waits for all of the following, each measured over 7 days:

1. **Hellos.** `client_hello` (added for this) logs each account socket's protocol and kind of client: `peer`, `phone` or `web`. Zero hellos at protocol 2, for every kind.
2. **Notices.** Zero `notice_batch` events and zero `AxoClientDO` `notify` invocations in Workers Observability. Both are only ever made for protocol 2 followers.
3. **Fallbacks.** Zero `peers.protocol_fallback` in each Mac's `~/.axo/server/stderr.log`; for the Studio, use `codemode.bash.run`.
4. **Builds.** No Mac with axod older than build 61 (0.38), and no phone older than build 28, has registered or said hello. Check the live manifest and the account's hosts.

The 1% sample makes zero events weak evidence on its own. Items 1 and 2 together, over a week, are what count. If protocol 2 hellos still appear, first find the client: its kind is logged, and the phone's UI tests are a likely source.

### Release A: clients stop falling back

- axod: remove `Protocol::Relayed`, `RELAYED_AFTER_REFUSAL` and `peers.protocol_fallback`. A refused hello is retried as a connection failure.
- `@axo/app`: remove `ProtocolRefused` and the protocol 2 connection.
- Swift `AccountConnection`: remove the protocol 2 fallback and the `Router` paths it needs.
- The Worker keeps serving protocol 2, so an old client still works while it updates.

### Release B: the Worker stops serving protocol 2

- `AxoClientDO`:
  - `hello` at version 2 answers -32602 with a fixed message ("update Axo"), as protocol 1 was refused (RFD0017).
  - `followHosts`, `notify`, `openSession`, `ack`, `pump` and the `hosts` and `open_sessions` tables go.
  - What stays is the account socket of protocol 3: hello, refresh, the hosts listing, and `hostsChanged`.
- `AxoHostDO`:
  - `subscribe`, `unsubscribe`, `watch`, `unwatch`, `flushNotices`, `everything` and `forgetFollower` go.
  - Notices go only to `HostClients.deliver`.
  - `callHost` stays: the account's apps use it.
- Storage: a schema step drops `followers` and `watchers` on the HostDO, and `hosts` and `open_sessions` on the ClientDO. Each is connection state, rebuilt at every hello. A rollback recreates them with `CREATE TABLE IF NOT EXISTS`.
- Specs: `specs/sessions/push-migration.ts` models the mix of protocols and is retired with it. `remote-sessions.ts` and `relay/remote-access.ts` keep only protocol 3's paths.
- Tests: the protocol 2 cases in `session-sync`, `push-delivery`, `release-p` and `axod-relay` either become protocol 3 cases or go. One test pins the refusal of `hello 2`.

### Cost baseline

Before release B, record a day of billable requests by class and hour, as RFD0032's table does. After it, `AxoClientDO` should take only account-socket frames and `hostsChanged`, with no `jsrpc` `notify`.

## Drawbacks

- A client that was not updated stops working, with a message to update. There are no users outside the account's own devices, so this is acceptable.
- Release A removes the safety net before release B removes the server side. A bug in protocol 3 found between the two can no longer be worked around by falling back. The 7 days of evidence are for this.

## Rationale and alternatives

- **Keep protocol 2 indefinitely.** It costs little in requests now, but doubles every delivery change and its tests.
- **Remove both sides in one release.** That would be simpler, but a rollback of the Worker alone would leave clients with no protocol in common.
- **Turn protocol 2 off briefly first, to see what breaks.** The measurements above give the same answer without breaking anyone.

## Unresolved questions

- Which client still spoke protocol 2 on 2026-11-09? `client_hello` will say. Until then, release A waits.
