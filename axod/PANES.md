# Local shell panes: explicit add/remove

`axo.session.pane.add` and `axo.session.pane.remove` are **local-only public JSON-RPC methods**, implemented in Rust through the same actual `axo` CLI/local WebSocket/Manager/native PTY path. The shared package exposes them in `localMethods`, not the cloud `remoteMethods` allowlist. The Rust relay dispatcher rejects them too. This does not wire shortcuts or attach Ghostty in the current Mac app.

## Shortcut semantics selected by the operator

- **Cmd+D / Cmd+Shift+D → add:** create an independent shell-pane identity and launch a fresh daemon-owned PTY in one explicit operation. The Mac chooses right/down placement and attaches a renderer locally. No separate pane create/start methods or aliases are selected.
- **Cmd+W → remove:** explicitly terminate the exact captured shell runtime, wait for verified ownership completion, then tombstone the pane. This is destructive intent, not just renderer detach.
- Client quit, renderer detach, cloud loss and unrelated view closure do not invoke remove or terminate work. Pi's managed pane is not a shell pane and cannot be removed through these methods.

Geometry, focus and terminal bytes are not RPC arguments/results. A public local terminal data plane and Ghostty external-PTY adoption remain separate gates.

## Configuration and wire shapes

Use the existing private approved profiles file with `axod serve ... --profiles-config /absolute/private/profiles.json`. For example:

```json
{"profiles":{"work":{"directory":"/absolute/approved/workspace","argv":["/bin/sh"]},"shell":{"directory":"/absolute/approved/workspace","argv":["/bin/zsh","-l"]}}}
```

Create workspace/session metadata first. Add selects `shell` by operator-approved profile ID. Its canonical directory must match that work session's saved directory; the launch uses the captured canonical directory and approved argv. There is no caller argv/cwd/prompt or runtime fallback.

```json
{
  "target": {
    "machineId": "CAPTURED_MACHINE_UUID",
    "hostGeneration": "CURRENT_HOST_UUID",
    "workspaceId": "WORKSPACE_UUID",
    "sessionId": "WORK_SESSION_UUID"
  },
  "commandId": "FRESH_COMMAND_UUID",
  "profileId": "shell"
}
```

Invoke with bounded stdin, not shell/prompt argv:

```sh
axo rpc /absolute/private/state/local-endpoint.json axo.session.pane.add < add-params.json
```

The result has `hostGeneration`, an immutable `receipt`, and a `pane` containing `paneId`, `kind:"shell"`, `profileId`, metadata `state`, original `runtime` and its nullable `terminal` observation. `axo.session.get/list` expose bounded `shellPanes`; session list adaptively shortens pages to keep projections within 48 KiB. Catalog revision still fences work-record identity/name pages, not atomic live process observations or a new pane-view epoch.

Remove takes the same captured parent `target`, fresh `commandId`, returned `paneId` and **exact returned `runtime`**, including its birth host generation, target and runtime generation. `runtime:null` is explicitly required only for a known failed/unlaunched pane with no runtime; omission is invalid. Wrong scope/generation cannot retarget a sibling or successor. Closing a Pi pane through this shell method rejects.

## Ownership, receipts and recovery

Private mode-0600 `pane-state.json` v1 stores identities, approved profile IDs, lifecycle and original normalized operation receipts—not argv, terminal bodies, geometry, history or credentials. Caps: 32 active panes/session, 1,000 retained pane identities, 2,000 receipts and 4 MiB. Removed identities remain tombstones and cannot be replaced through generic runtime launch. There is no automatic eviction/import/migration or shell restoration after restart.

New command admission/collision/persistence fencing is shared across work/runtime/Pi/pane domains. Add durably reserves identity/intent before native launch; remove durably reserves captured intent and `closing` state before delivering a signal. Original command reconciliation never starts another shell or repeats a removal signal, even after removal or changed operator policy. `axo.command.get` returns `kind:"pane"` receipts; prepared start evidence can include the journal's original runtime when final binding was uncertain.

Dispositions: `prepared`, `added`, `removed`, or known `rejected` with a closed native reason. Added means native launch accepted, not shell command completion. Removal uses the existing owned TERM → bounded KILL escalation, never historical PIDs. Final `removed` requires an unforgeable Manager completion witness: original child reaped, terminal drain/EOF complete, original group absent and exact completion durably recorded. A proven completed historical runtime can be tombstoned without signaling it.

A five-second completion deadline or lost ownership produces truthful unknown/recovery with the original prepared receipt and closing record, **not fake removal, retry permission or automatic replacement**. It may require explicit operational recovery; repeated commands do not redispatch. Storage uncertainty fences further admission but does not kill accepted siblings.

**Residual limitation:** the original owned process group is not every foreground/job-control group or escaped descendant. No claim of comprehensive escaped-process containment, abrupt-crash/power-loss recovery, scalable retention, terminal-state reconstruction or production readiness is made. A raw backlog is not a VT snapshot.

## Evidence

`tests/public_cli.rs` now uses actual `axo`/`axod serve` to add two real shell PTYs, proves TTY execution through an approved shell effect, reconciles without another effect, rejects stale runtime/generic replacement, removes only one shell, verifies the sibling remains running, restarts without replay, removes a proven-stopped historical pane and reads original receipts. `tests/managed_public.rs` separately adds/removes a shell alongside actual ambient Pi and verifies Pi remains admitted with no provider replay; Pi persistence failure also fences new pane admission.

Five store/admission tests cover tombstones/original dispositions, missing completion witness, wrong runtime/duplicate removal, exhaustive synthetic truncation/unreceipted edits, persistence fencing and cross-domain collision/fencing. Protocol tests cover closed local schemas, captured runtime, no geometry/argv/body leakage, typed client calls and nonexecuting notifications. The real local/cloud matrix tests malformed/stale local pane requests, idless nonexecution and rejection of valid pane requests at the cloud route. These are daemon/protocol facts, not native shortcut/rendering or live app acceptance.
