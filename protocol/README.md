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

`startApproved` has no remote argv, shell string or cwd parameter. `axod` resolves `profileId` from its private configuration and uses the existing `Manager::start`/durable launch receipt. Its result reports the actual terminal disposition; a retry can return a previously exited terminal, not a fresh process. Matching command IDs reconcile normalized execution intent, while conflicting target/launch arguments fail. Changing request IDs does not create a new logical command ID. No adapter replays calls on reconnect.

A `runtime.list` page returns `{hostGeneration, terminals, next}`. `startApproved` returns `{hostGeneration, terminal}`. Terminal snapshots describe runtime identities, process disposition, attachment state and backlog **count**; no terminal bytes travel through the API. The response validator rejects extra payload fields. Current source generation and original runtime generation are deliberately separate.

This is not yet session/workspace/Pi API parity. Prompt/history/stop/subscriptions, local WebSocket dispatch, file authorization migration and native client cutover are not implemented by this profile.

## Delivery and failure semantics

The service retags forwarded requests with unique hop IDs and stores only bounded route/correlation/deadline metadata. Replies are fenced to the same admitted daemon connection. A caller ID shared by two client sockets never identifies the same pending call.

Clients/daemons acknowledge each consumed service frame, including negotiation replies, by sending `axo.transport.ack` with `frames: 1`. A batch reply is one frame. Service queues have 32-frame/128-KiB delivery-credit ceilings. Invalid credits, exhausted queues and oversized aggregate replies close the socket rather than blocking daemon execution indefinitely. This is flow control, not an execution acknowledgement.

Control calls expire after at most 10 seconds, further bounded by caller expiry and the current machine lease. Forwarded-call timeout/disconnect/invalid daemon result is `-32004` **unknown outcome**; it is not confirmed rejection or cancellation. Offline-before-forwarding is `-32005` with nothing queued. Daemon-side launch receipts allow explicit reconciliation by the original command ID/arguments. Do not invent exactly-once effects or blindly retry under a new ID.

Other profile errors: negotiation required `-32001`; stale/wrong destination `-32002`; registration admission failure `-32003`; capacity `-32006`; command conflict `-32007`; storage failure `-32008`; recovery required `-32009`; other daemon rejection `-32010`. Error bodies contain no prompts, paths, credentials or raw upstream details.

Authentication belongs to transport/caller context, never method parameters. Local private Unix IPC is still the daemon's existing development adapter; only the outbound relay uses this profile today. The local/relayed shared dispatcher direction does not authorize exposing an unauthenticated localhost execution endpoint.
