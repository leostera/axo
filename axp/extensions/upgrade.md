# AXP extension: `upgrade`

```text
Identifier: upgrade
Version:    0.1
Status:     Draft
Requires:   core only
Roles:      host, hub, client
```

A host that is about to restart on purpose, to update itself or its agents, says so first. Clients then show the host as restarting and wait, instead of treating it as gone.

## 1. Methods

| Method | Caller | Params | Result |
| --- | --- | --- | --- |
| `upgrade.prepare` | host → hub | `reason`, `expectedMs`, `version`? | `{ "deadline" }` |
| `upgrade.cancel` | host → hub | | `{}` |

- `upgrade.prepare` tells the hub the host will disconnect within a few seconds and expects to be back within `expectedMs` (at most 10 minutes). `reason` is `update`, `agentUpdate` or `restart`. The hub answers the time by which it expects the host back.
- Until the host reconnects or the deadline passes, the hub reports the host's presence as `restarting`, and answers routed calls with `-32010` (`hostOffline`) carrying `retryAfterMs` until the deadline. Clients SHOULD wait and retry rather than fail.
- When the host reconnects with a new `generation`, presence returns to `online`. When the deadline passes first, presence becomes `offline`.
- A host SHOULD finish or hold running agent turns before it restarts, so that commands it accepted are not lost. A command a host accepted before restarting MUST still run at most once after it.

## 2. Errors

| Code | Name | `retry` | Meaning |
| --- | --- | --- | --- |
| -32300 | `upgradeInProgress` | `safe` | The host is restarting; retry after `retryAfterMs`. |
