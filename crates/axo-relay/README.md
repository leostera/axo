# axo-relay

Axod's side of the Axo cloud: it links this host to an account, keeps an authenticated WebSocket to the relay so remote clients can list, create and drive Sessions, uploads every Session's transcript, and keeps a copy of the account's other Macs' Sessions.

Everything runs on threads that `RelayWorker::start` owns. The crate reaches axod only through the `RelayHost` trait (`host.rs`), so it holds no catalog or process state of its own.

## Layout

| Module | Owns |
| --- | --- |
| `relay` | The reconnect loop and `RelayWorker`. `relay/`: `status` (what Axo.app shows), `socket` (WebSocket transport, shared with `peers`), `session` (one connected session), `dispatch` (`axo.remote.*` calls), `jobs` (bash, prompts with attachments, sign-ins), `elicitation` (RFD0029), `wire` (JSON-RPC types) |
| `sync` | Uploading transcripts (RFD0018, RFD0027). `sync/`: `metadata`, `uploader` (the handshake and append loop). It reads each transcript with `axo_agent::pi::TranscriptFile` |
| `peers` | Copies of other Macs' Sessions and commands sent to them (RFD0022, RFD0024). `peers/`: `mirror` (copies on disk), `index` (the listing), `live` (state shared with axod's remote panes), `follower` (the socket) |
| `link`, `pairing`, `credential` | Whether and how this host is linked to an account, and where its credential is kept (Keychain or files) |
| `outbound` | `RelayChannel`: how other threads send on the host's one socket, by priority |
| `fragments` | Messages larger than one frame (RFD0016, Transport) |
| `assets` | Fetching a prompt's attachments before it reaches Pi (RFD0030) |
| `bash`, `signin` | The host connection's `bash` tool and loopback sign-in (RFD0016) |
| `endpoint`, `host` | The relay URL, and the `RelayHost` trait axod implements |

## Rules

- The daemon route authenticates with the host credential and never follows a redirect; a redirect means something (usually an Access login) intercepts it, and is reported.
- The cloud's answer to a sync handshake always wins over what `axo.db` remembers; a cursor moves only when the cloud acknowledges a commit.
- A peer copy is acknowledged only once written, never uploaded, and never written into this Mac's own folder.
- `fragments` (and `axo_agent::pi::pi3`) have TypeScript twins in `packages/axo-api`; both are checked against `schemas/axo.leostera.dev/v1` and the models in `specs/`.

## Build and test

```sh
bazel build //crates/axo-relay
bazel test //crates/axo-relay:axo_relay_tests
```
