# AXP extension: `sessions`

```text
Identifier: sessions
Version:    0.1
Status:     Draft
Requires:   core only
Roles:      host, client
```

Creating, renaming and archiving Sessions, and the folders they run in. The core lists Sessions but never creates one; a client that wants to start an agent on a host from afar uses this extension.

## 1. Model

A **workspace** is a folder on the host that Sessions run in. It has a `workspaceId` (a UUID the host assigns), a `name` and a `path`. A Session belongs to at most one workspace, named in its metadata under `ext.sessions`:

```json
{"ext":{"sessions":{"workspaceId":"…","workspaceName":"axo"}}}
```

## 2. Methods

Every method is routed (SPEC §10.1). The ones with a `commandId` are commands (SPEC §10.2).

| Method | Params | Result |
| --- | --- | --- |
| `sessions.workspaces.list` | `hostId` | `{ "workspaces": [{ "workspaceId", "name", "path" }] }` |
| `sessions.create` | `hostId`, `commandId`, `agent`, `workspaceId`?, `name`? | `{ "receipt", "sessionId" }` |
| `sessions.rename` | `hostId`, `sessionId`, `commandId`, `name` | `{ "receipt" }` |
| `sessions.archive` | `hostId`, `sessionId`, `commandId` | `{ "receipt" }` |
| `sessions.restore` | `hostId`, `sessionId`, `commandId` | `{ "receipt" }` |

- `agent` names an agent the host can run, by its ATXF `source.agent` (for example `pi`). The host advertises the agents it can run in its Host entry under `ext.sessions.agents`.
- `sessions.create` answers with the new `sessionId` in the receipt. A duplicate `commandId` answers the same `sessionId`. The Session appears in the directory before the receipt is sent.
- `name` is 1 to 80 characters, or `null` to return to the agent's own title.
- `sessions.archive` stops the agent if it is running and sets `archived: true`. `sessions.restore` clears it. Neither changes the log.
- `path` is informative. Clients MUST NOT assume it exists anywhere but on the host.

## 3. Errors

| Code | Name | `retry` | Meaning |
| --- | --- | --- | --- |
| -32200 | `unknownAgent` | `never` | The host cannot run that agent. |
| -32201 | `unknownWorkspace` | `never` | No such workspace on the host. |
| -32202 | `sessionLimit` | `safe` | The host runs as many Sessions as it will. |

## 4. Security

Creating a Session starts a process on the host with the host user's rights. A host MAY restrict `sessions.create` to some devices and MUST check the `from.device` of every routed call against its own policy.
