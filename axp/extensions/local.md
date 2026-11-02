# AXP extension: `local`

```text
Identifier: local
Version:    0.1
Status:     Draft
Requires:   core only
Roles:      host, client (on a local socket only)
```

Control of a host from the same machine: its health, its settings, and its link to a hub. A host MUST offer this extension only on a local socket (SPEC §5.1) and MUST NOT accept its methods from a hub.

## 1. Methods

| Method | Params | Result |
| --- | --- | --- |
| `local.health` | | `{ "version", "hostId", "generation", "startedAt", "hub": HubLink }` |
| `local.config.get` | `key` | `{ "key", "value" }` |
| `local.config.set` | `key`, `value` | `{ "key", "value" }` |
| `local.hub.pair` | `uri` | `HubLink` |
| `local.hub.unpair` | | `HubLink` |
| `local.hub.status` | | `HubLink` |
| `local.viewport.set` | `width`, `height`, `scale`, `cell`: { `width`, `height` } | `{}` |

- `HubLink` is `{ "state", "hub"?, "account"?, "device"?, "error"? }`, `state` being `unpaired`, `connecting`, `online` or `offline`.
- `local.hub.pair` takes a pairing URI (SPEC §5.3), generates the device key, redeems the code and connects. The key never leaves the host.
- `local.config.*` keys are slugs the host defines, such as `agent` or `shell`. Values are JSON. A host answers `-32320` for keys it does not know.
- `local.viewport.set` tells the host the size of the client's terminal area in points, its backing scale, and its cell size in pixels, so the host can size shells that no client is attached to (`terminal` extension).

## 2. Errors

| Code | Name | `retry` | Meaning |
| --- | --- | --- | --- |
| -32320 | `unknownKey` | `never` | No such configuration key. |
| -32321 | `invalidValue` | `never` | The value is not valid for the key. |
