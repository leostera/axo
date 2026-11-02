# AXP extension registry

Extensions add methods, slots, record conventions and fields to AXP without changing the core ([SPEC §15](../SPEC.md#15-extensions)). Each one is negotiated per connection in `axp.hello`.

| Identifier | Version | Status | Roles | Error codes | Document |
| --- | --- | --- | --- | --- | --- |
| `sessions` | 0.1 | Draft | host, client | -32200 to -32219 | [sessions.md](sessions.md) |
| `pi` | 0.1 | Draft | host, client | -32220 to -32239 | [pi.md](pi.md) |
| `terminal` | 0.1 | Draft | host, client | -32240 to -32259 | [terminal.md](terminal.md) |
| `connections` | 0.1 | Draft | hub, host, client | -32260 to -32279 | [connections.md](connections.md) |
| `share` | 0.1 | Draft | hub, host | -32280 to -32299 | [share.md](share.md) |
| `upgrade` | 0.1 | Draft | host, hub, client | -32300 to -32319 | [upgrade.md](upgrade.md) |
| `local` | 0.1 | Draft | host, client (local only) | -32320 to -32339 | [local.md](local.md) |

Each extension's schema is published at `https://axp.leostera.dev/schema/v0.1/ext/<identifier>/<version>/<identifier>.schema.json`.

## Registering an extension

An extension listed here has a document in this directory with this front matter, a schema, at least one example exchange in [`examples/`](../examples/), and a reserved error range of 20 codes between -32200 and -32999. Private extensions use a reverse-DNS identifier and need no registration.

```text
Identifier: <slug>
Version:    <major.minor>
Status:     Draft | Stable | Deprecated
Requires:   <identifiers, or "core only">
Roles:      <which roles implement it>
```

The document says, as it applies: what the extension models, its methods and notifications with who sends them, whether each is routed (SPEC §10.1) and whether it is a command (SPEC §10.2), its slots, its log record conventions, its fields under `ext.<identifier>`, its errors, limits and security considerations.
