# @axo/protocol — control profile 1

A proper private JavaScript package: compiled ESM, generated TypeScript declarations, explicit exports, pinned dependencies and package tests. TypeScript consumers import `@axo/protocol`, not sibling source files. It uses [`json-rpc-2.0` 1.8.1](https://www.npmjs.com/package/json-rpc-2.0) for typed client/server interfaces, method dispatch, response constructors and client correlation. It is not published to npm.

Shared JSON-RPC 2.0 contract for the standalone `axod`/private API vertical slice proposed in [RFD0008](../docs/rfds/RFD0008-private-multi-machine-control-plane.md).

- [`schemas.json`](schemas.json): language-neutral JSON Schema definitions for well-formed envelopes, parameters and results.
- [`src/contracts.ts`](src/contracts.ts): domain/runtime validators and policy limits above JSON-RPC.
- [`src/rpc.ts`](src/rpc.ts): typed `AxoMethods`/`DaemonMethods`/`ServiceMethods`, library factories and bounded message adapter.
- [`src/index.ts`](src/index.ts): the public package surface, built into `dist/`.
- [`fixtures/envelopes.json`](fixtures/envelopes.json): the same codec cases executed by Rust and TypeScript tests.
- [`generate-schema.ts`](generate-schema.ts): regenerate schemas; `--check` rejects drift.

```sh
npm --prefix protocol ci
npm --prefix protocol test
npm --prefix protocol run schema:check
```

## Swift package

`Package.swift` exposes the `AxoProtocol` library for macOS 14+ and iOS 17+, with no external dependencies. Add this directory as a local Swift package in Xcode, or use it from another Swift package:

```swift
.package(path: "../protocol")
```

The initial Swift surface includes JSON-RPC envelope/response types, a bounded envelope decoder, and Codable models for the currently implemented machine/runtime methods. It uses the shared `fixtures/envelopes.json` corpus to keep the Swift envelope boundary aligned with Rust and TypeScript. The real-daemon end-to-end test is run from the private API suite, which provides a disposable authenticated Worker and starts isolated `axod`/PTY fixtures; a plain `swift test` skips that test when the harness inputs are absent.

```sh
swift test --package-path protocol
```

The Codable contract models establish wire shapes; method-specific runtime validation and a reusable production client/server transport remain follow-up work before replacing an existing transport boundary. The end-to-end test exercises these Swift wire types over `URLSessionWebSocketTask` against a real daemon through the isolated API test harness.

## Typed use

```ts
import { createAxoClient, createProfileServer, listSchema,
  type TypedJSONRPCServer, type DaemonMethods } from "@axo/protocol";

const server: TypedJSONRPCServer<DaemonMethods> = createProfileServer();
server.addMethod("axo.runtime.list", params => {
  const input = listSchema.parse(params); // Types do not validate incoming JSON.
  return { hostGeneration: input.target.hostGeneration, terminals: [], next: null };
});

const client = createAxoClient(sendAuthenticatedMessage);
const result = await client.request("axo.runtime.list", { target });
```

Transport authentication, destination fencing and result validation still belong at the relevant boundary. Compile-only regression tests reject misspelled methods, missing targets and wrong result assumptions. JavaScript or an untrusted peer can bypass annotations; runtime schemas remain mandatory. Bidirectional library interfaces are exported for controller/daemon endpoints.

The library is deliberately **not** used as a replacement for the relay's durable SQLite correlation state: its in-memory client map cannot survive DO hibernation. Local service methods dispatch through `JSONRPCServer`; the dummy network client uses `JSONRPCClient`. The relay's hop IDs/leases/batch assembly remain bounded transport coordination, not another executor.

Version 1.8.1 has two inspected quirks: its server collapses a batch containing one reply, and its advanced client treats null IDs as notifications. The bounded `serveProfileMessage` adapter preserves batch arrays and null-ID server replies; generated string IDs are used for client calls. Raw fixture tests still verify explicit null requests. Its loose envelope checks do not replace our input/domain schemas, and its default exception logger is disabled to prevent payload leaks. These boundaries are regression-tested without patching the dependency.

## Wire profile

JSON-RPC `jsonrpc` is exactly `"2.0"`. Application `protocolVersion` is independently `1`. Use named parameter objects for Axo methods; valid positional parameter envelopes still decode but these methods reject them with `-32602`.

IDs are strings of at most 128 UTF-16 code units, null, or finite numbers within ±(2^53−1). Prefer generated string IDs. An **absent** ID is a notification; `id: null` is response-bearing. Mutations without IDs never execute and never receive replies. Notifications do not create response placeholders in batches. Invalid batch members receive individual `-32600` replies; empty/oversized batches receive one error. Replies have exactly one result/error, preserving their original ID. JSON-RPC IDs are not durable command identities.

A text frame/body is at most 65,536 encoded UTF-8 bytes; batches contain at most eight logical calls. JSON Schema describes valid messages; the codec also handles invalid members. Binary control frames are rejected. Standard parse/request/method/params errors use `-32700`, `-32600`, `-32601`, `-32602`. The `rpc.` method namespace is not used.

UUIDs are case-insensitive inputs normalized to lower-case routing keys. A label or UUID never authenticates a machine. Targets always contain `machineId` and `hostGeneration`. Source `hostGeneration` is included in successful daemon results. Historical terminal records retain their original runtime references; their presence in a current metadata response is not current ownership or permission to signal a historic PID.

## Implemented methods

| Method | Parameters | Availability |
| --- | --- | --- |
| `axo.protocol.negotiate` | `{protocolVersion: 1}` | Client/daemon WebSocket before other calls |
| `axo.machine.register` | `{protocolVersion: 1, machineId, hostGeneration, label}` | Authorized daemon only |
| `axo.machine.heartbeat` | `{leaseId}` | Registered daemon only |
| `axo.machine.list` | `{}` | Authorized client HTTP JSON-RPC discovery |
| `axo.runtime.list` | `{target: {machineId, hostGeneration}, after?, limit?}` | Relayed read-only daemon metadata, default/max page 50 |
| `axo.runtime.startApproved` | `{commandId, target: {machineId, hostGeneration, sessionId, paneId}, profileId}` | Relayed daemon mutation using an operator-configured launch profile |
| `axo.transport.ack` | `{frames: positive integer <= 32}` | WebSocket notification acknowledging consumed outbound frames |
| `axo.workspace.list` | `{target, cursor?, limit?}` | Shared daemon record page; source/revision/domain-bound cursor |
| `axo.workspace.create` | `{target, commandId, expectedRevision, directoryId, name}` | Metadata-only commit from an approved directory ID; no initial session or execution |
| `axo.workspace.rename` | `{target: {...source, workspaceId}, commandId, expectedRevision, name}` | Durable manual-label mutation |
| `axo.session.list` | `{target, workspaceId?, cursor?, limit?}` | Shared work-session pages; cursor includes workspace filter |
| `axo.session.get` | `{target: {...source, workspaceId, sessionId}}` | Work/pane metadata and runtime facts, not transcript/Pi readiness |
| `axo.session.create` | `{target: {...source, workspaceId}, commandId, expectedRevision, name}` | Fresh unstarted work/Pi-pane identities, no fabricated chat/history |
| `axo.session.rename` | `{target: {...source, workspaceId, sessionId}, commandId, expectedRevision, name}` | Durable manual Axo label, not Pi-title mutation |
| `axo.command.get` | `{target, commandId}` | Read-only machine-scoped work/runtime receipt; null never proves rejection or safe replay |

`startApproved` has no remote argv, shell string or cwd parameter. `axod` resolves `profileId` from its private configuration and uses the existing `Manager::start`/durable launch receipt. Its result reports the actual terminal disposition; a retry can return a previously exited terminal, not a fresh process. Matching command IDs reconcile normalized execution intent, while conflicting target/launch arguments fail. Changing request IDs does not create a new logical command ID. No adapter replays calls on reconnect.

A `runtime.list` page returns `{hostGeneration, terminals, next}`. `startApproved` returns `{hostGeneration, terminal}`. Terminal snapshots describe runtime identities, process disposition, attachment state and backlog **count**; no terminal bytes travel through the API. The response validator rejects extra payload fields. Current source generation and original runtime generation are deliberately separate.

Workspace/session record methods now share the same isolated daemon store locally and through the API. `target` means explicit machine/host source; `expectedRevision` is the global work-record revision. Names are 1–80 Unicode scalar values without controls/surrounding whitespace. Work lists default/max at 50 and return source, revision and an explicitly scoped `next` cursor; a changed revision/source/domain/filter rejects a cursor. There is no cached public catalog endpoint or silent fallback. `directoryId` currently selects only an operator profile's approved directory; resolved host paths remain private.

Create/rename return committed metadata and revision. Reusing a command reconciles the exact original normalized intent; conflicting arguments or execution/work command reuse reject. Work commits and runtime receipts are separate bounded stores under one owner/admission lock. Uncertain persistence fences mutations in both domains. `command.get` returns a work commit or original runtime reference with any available observation; missing or an absent historical snapshot never permits execution replay.

The proposed `axo._.*` names in [RFD0009](../docs/rfds/RFD0009-protocol-capability-parity.md) have **not** replaced the current prototype spellings yet; no aliases are introduced. Work-record APIs have TypeScript/Rust/schema evidence, not Swift/native adoption. Pi start/admission, chat controls/history, stop/subscriptions, file authority and native cutover remain unfinished. A runtime observation in `session.get` is deliberately separate from the null/notAdmitted Pi binding.

## Delivery and failure semantics

The service retags forwarded requests with unique hop IDs and stores only bounded route/correlation/deadline metadata. Replies are fenced to the same admitted daemon connection. A caller ID shared by two client sockets never identifies the same pending call.

Clients/daemons acknowledge each consumed service frame, including negotiation replies, by sending `axo.transport.ack` with `frames: 1`. A batch reply is one frame. Service queues have 32-frame/128-KiB delivery-credit ceilings. Invalid credits, exhausted queues and oversized aggregate replies close the socket rather than blocking daemon execution indefinitely. This is flow control, not an execution acknowledgement.

Control calls expire after at most 10 seconds, further bounded by caller expiry and the current machine lease. Forwarded-call timeout/disconnect/invalid daemon result is `-32004` **unknown outcome**; it is not confirmed rejection or cancellation. Offline-before-forwarding is `-32005` with nothing queued. Daemon-side launch receipts allow explicit reconciliation by the original command ID/arguments. Do not invent exactly-once effects or blindly retry under a new ID.

Other profile errors: negotiation required `-32001`; stale/wrong destination `-32002`; registration admission failure `-32003`; capacity `-32006`; command conflict `-32007`; storage failure `-32008`; recovery required `-32009`; other daemon rejection `-32010`. Error bodies contain no prompts, paths, credentials or raw upstream details.

Access remains the current cloud edge gate; this package does not implement application accounts/auth or user management. The local Unix listener and legacy envelope have been removed. At the user's explicit request, local WebSocket is credential-free: numeric loopback, exact Host/path and no-Origin guards are browser restrictions, **not authentication against other local processes/users**. UUID routing identities are not credentials.

## Local bootstrap

`axod serve` publishes an atomic, private mode-0600 `local-endpoint.json` (at most 4 KiB) in its owned state directory. `localEndpointSchema` / the `localEndpoint` JSON Schema definition describe `{version: 1, protocolVersion: 1, endpoint, machineId, hostGeneration}`. The endpoint is exactly `ws://127.0.0.1:<port>/v1/rpc`; there is no token or authentication header. Readers validate absolute path, ownership, regular/single-linked file, permissions, size and schema before connecting. The runtime validator also checks port range.

Capture discovery before connection, negotiate, then send explicit machine/host targets and acknowledge each consumed reply frame. After disconnect, reread discovery to get the current boot fence; do not replay work. Both adapters use the same dispatcher/manager/receipts and named-profile policy. No terminal data is exposed by these methods. Native bootstrap/package wiring remains with the native agents; this is not a live-app ownership cutover.
