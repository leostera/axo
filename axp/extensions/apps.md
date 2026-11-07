# AXP extension: `apps`

```text
Identifier: apps
Version:    0.1
Status:     Draft
Requires:   core only
Roles:      hub, host, client
```

Tools that an account connects once at its hub and every Session on every host can use: MCP servers, apps with OAuth, and sandboxed scripts. The hub holds the credentials; hosts never see them.

## 1. Model

- A **connection** is a source of tools the account added at the hub: `{ "id", "name", "kind", "status", "tools": [Tool] }`.
  - `kind` is `mcp` (a remote [MCP](https://modelcontextprotocol.io) server), `app` (a service the hub integrates, such as an email provider), or another slug the hub defines.
  - `status` is `ready`, `needsSignIn` or `error`.
- A **tool** is `{ "name", "description", "inputSchema" }`, `inputSchema` being a JSON Schema.
- A **call** runs one tool for one Session and is logged by the hub for the account to review.

## 2. Methods

These are hub methods, not routed: their params carry no `hostId`.

| Method | Caller | Params | Result |
| --- | --- | --- | --- |
| `apps.list` | host, client | | `{ "apps": [Connection] }` |
| `apps.search` | host | `query`, `limit`? | `{ "tools": [{ "connection", "tool": Tool }] }` |
| `apps.execute` | host | `sessionId`, `connection`, `tool`, `arguments` | `{ "content", "isError" }` |
| `apps.script` | host | `sessionId`, `source`, `timeoutMs`? | `{ "result", "logs" }` |
| `apps.log` | client | `sessionId`?, `before`?, `limit`? | `{ "calls": [Call] }` |
| `apps.add` | client | `kind`, `url`?, `name`? | `{ "connection": Connection }` |
| `apps.remove` | client | `id` | `{}` |
| `apps.signIn` | client | `id` | `{ "url" }` |

- `apps.execute` calls one tool. `content` is a list of MCP content blocks.
- `apps.script` runs `source`, a JavaScript module whose default export is an async function, in a sandbox at the hub with no network of its own, where each connection's tools are callable as `apps.<name>.<tool>(arguments)`. It lets an agent chain several calls in one round trip.
- `apps.signIn` answers a URL a person opens in a browser to authorize the hub. The connection's `status` becomes `ready` when it completes, and the hub sends `apps.changed` `{ "apps": [Connection] }` to subscribed peers.
- A `Call` is `{ "id", "sessionId", "hostId", "connection", "tool", "at", "durationMs", "isError" }`. Arguments and results are not in the log.

## 3. Errors

| Code | Name | `retry` | Meaning |
| --- | --- | --- | --- |
| -32260 | `unknownConnection` | `never` | No such connection. |
| -32261 | `needsSignIn` | `never` | The connection needs `apps.signIn` first. |
| -32262 | `toolFailed` | `unknown` | The tool's server failed; it may have acted. |
| -32263 | `scriptFailed` | `unknown` | The script threw or timed out. |

## 4. Security

Tools act with the account's credentials. A hub MUST attribute every call to the Session and host that made it, MUST NOT expose credentials to hosts or scripts, and SHOULD let an account restrict which apps each host may use.
