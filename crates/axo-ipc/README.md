# axo-ipc

Axod's local IPC: newline-delimited JSON-RPC over a Unix socket, and the bounded event queues behind long-polled subscriptions.

| Module | Owns |
| --- | --- |
| `server` | `serve` and `TypedMethods`: one tokio task per connection and per request; synchronous handlers run on the blocking pool |
| `event_queue` | `EventQueue`: a bounded per-subscription queue with blocking and async waiters |

## Rules

- The executor never blocks. Waiting requests such as `axo.questions.wait` are plain futures, so thousands of them cost no threads and never delay other requests.
- Publishers never block. A full queue marks its subscription lagged, and the next take returns only the lag marker instead of a silent gap.

## Build and test

```sh
bazel build //crates/axo-ipc
bazel test //crates/axo-ipc:axo_ipc_tests
```

`extension` is the extension API (RFD0034 step 4): an `Extension` registers its methods into `Methods`, which keeps one owner per method and refuses a name two extensions claim.
