# AXP extension: `terminal`

```text
Identifier: terminal
Version:    0.1
Status:     Draft
Requires:   core only
Roles:      host, client
```

Pseudo-terminals that belong to a Session, how they are laid out, and their bytes. Terminal bytes are ephemeral: no one stores them, and a client that joins late asks for the screen instead.

## 1. Model

- A **shell** is a pseudo-terminal on the host, identified by a `shellId` (a UUID) within its Session. It has a size in `rows` and `cols`.
- A Session's **layout** arranges its shells in panes. It is a tree:
  - a leaf `{ "shell": <shellId> }`;
  - a split `{ "direction": "row" | "column", "children": [Node], "sizes": [number] }`, `sizes` being fractions that sum to 1, with 2 to 8 children.
- The host owns the layout and publishes it in the Session's metadata under `ext.terminal.layout`, with the list of shells under `ext.terminal.shells` (`[{ "shellId", "title", "rows", "cols" }]`).
- **Output** is the bytes a shell writes, numbered by `seq`, the count of bytes written before them.

## 2. Methods

All are routed (SPEC §9.1) and take `hostId`, `sessionId` and, except `terminal.shell.create`, `shellId`.

| Method | Command | Further params | Result |
| --- | --- | --- | --- |
| `terminal.shell.create` | yes | `rows`, `cols`, `cwd`? | `{ "receipt", "shellId" }` |
| `terminal.shell.close` | yes | | `{ "receipt" }` |
| `terminal.layout.set` | yes | `layout` | `{ "receipt" }` |
| `terminal.attach` | no | | `{ "screen", "seq" }` |
| `terminal.detach` | no | | `{}` |
| `terminal.input` | no | `seq`, `data` | `{ "seq" }` |
| `terminal.resize` | no | `rows`, `cols` | `{ "rows", "cols" }` |
| `terminal.screen` | no | | `{ "screen", "seq" }` |

- `terminal.attach` starts output for the calling client and answers with the current **screen**: `{ "rows", "cols", "cursor": { "row", "col" }, "lines": [string] }`, as plain text, and the `seq` it reflects. Output after `seq` follows as `terminal.output` notifications. A client that falls behind or misses output calls `terminal.screen` and continues from the `seq` it answers.
- `terminal.input` carries keyboard bytes. `seq` is the client's own counter of bytes sent to that shell; the host answers the highest `seq` it has written, and ignores input whose `seq` it has already written, so a client can resend input after an unknown outcome without typing twice.
- `terminal.resize` changes the shell's size. When several clients are attached, the host MAY choose the size and answers the size it applied.
- `rows` and `cols` are 1 to 1000.

## 3. Notifications

`terminal.output` (host → client) `{ "hostId", "sessionId", "shellId", "seq", "data" }`, `data` being base64url bytes. A hub forwards it only to the connections that attached to that shell. It is in the `ephemeral` priority class (SPEC §3.1), and a hub MUST NOT store it. A hub MAY drop output for a slow connection and send `terminal.gap` `{ "hostId", "sessionId", "shellId", "seq" }` instead, after which the client calls `terminal.screen`.

## 4. Errors

| Code | Name | `retry` | Meaning |
| --- | --- | --- | --- |
| -32240 | `unknownShell` | `never` | No such shell in this Session. |
| -32241 | `invalidLayout` | `never` | The layout does not name every shell of the Session exactly once, or breaks the tree's rules. |
| -32242 | `notAttached` | `never` | `terminal.input` or `terminal.resize` from a connection that has not attached. |

## 5. Security and privacy

Terminal input runs commands as the host's user. Terminal output routinely contains secrets. A hub MUST NOT log, store or replay either.
