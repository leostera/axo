# Managed ambient Pi: public RPC checkpoint

The selected path is **actual Rust `axo` → public WebSocket RPC → `axod serve` → owned native PTY → ambient interactive Pi + `pi-axo`**. The isolated Worker forwards those same methods to that owner. It does not execute Pi. No Mac window is required, and no Mac app/live registry/startup/deployment adoption is enabled by this checkpoint.

## Explicit operator policy

```sh
axod serve /absolute/private/daemon-state \
  --profiles-config /absolute/private/profiles.json \
  --pi-config /absolute/private/pi.json
# Optional existing Access-protected cloud route:
# --relay-config /absolute/private/relay.json
```

All configuration files are owned, single-linked regular mode-0600 files without symlinks, bounded to 64 KiB. The daemon state and Pi session directories already exist and are owned/private (0700). Keep credentials outside the repository and out of argv/environment/logs; this adds no credential or enrollment framework.

`profiles.json` establishes the approved work-directory identities used by metadata creation:

```json
{"profiles":{"work":{"directory":"/absolute/approved/workspace","argv":["/bin/sh"]}}}
```

`pi.json` selects the installed extension and the Pi policy for those directory IDs:

```json
{
  "extension": "/absolute/operator-installed/pi-axo/index.ts",
  "profiles": {
    "work": {
      "directory": "/absolute/approved/workspace",
      "sessionDirectory": "/absolute/private/pi-sessions",
      "executable": "/opt/homebrew/bin/pi",
      "arguments": []
    }
  }
}
```

`executable` is optional: omission captures the normal ambient PATH launcher. Repository/npm-injected runtime candidates are excluded; ordinary package-manager symlinks remain valid. There is no bundled fallback, installation or upgrade. `arguments` is a closed operator-only flag allowlist (provider/model/thinking/tools/extensions and resource switches), not prompt text, caller argv, alternate modes, session selection or credentials. The work directory must still match the current Pi approval before a new launch. Operator policy changes never reinterpret an original command receipt.

## Methods and identities

The shared package exposes 19 daemon methods: the earlier ten work/generic-runtime methods plus:

- `axo.session.start`
- `axo.chat.get`, `axo.chat.history`, `axo.chat.getToolOutput`
- `axo.chat.sendMessage`, `axo.chat.sendSteeringMessage`, `axo.chat.cancelTurn`
- `axo.chat.answerQuestion`, `axo.chat.setViewing`

Request/result validators are in `protocol/src/pi-contracts.ts` and generated `protocol/schemas.json`. Rust routing uses a closed domain-action enum and operation-specific request types. Unknown fields/methods and malformed identities fail closed. Notifications cannot execute mutations in the library, Worker or daemon.

`session.start` captures machine/current host/workspace/work-session/Pi-pane identities and a fresh command ID. Persistence is explicit: `{kind:"fresh"}` or `{kind:"resume",chatId,previousRuntime}`. Creation remains metadata-only. Spawn is not admission: the extension must bind actual public Pi chat/file/cwd, child PID, model and TUI/TTY state through the inherited owner-only fd-3 socket. Exact resume requires the recorded file/header/tree and a proven completed previous owned runtime. Generic launch cannot replace an admitted Pi pane.

Chat targets additionally carry `chatId`, `runtimeGeneration` and `runtimeHostGeneration`. The last field preserves the runtime's birth generation independently of the current response/host destination, including explicit stopped reads after reboot. No selection fallback or automatic retargeting is allowed.

The CLI is the same Rust `axo` executable, currently local-only:

```sh
axo rpc /absolute/private/daemon-state/local-endpoint.json axo.session.start < start-params.json
```

Parameters are bounded stdin, never prompt argv. Tests also use a Rust-owned cloud peer against the real isolated Worker; this does not imply a cloud CLI option or live Access deployment.

## Durable dispositions, not execution claims

`pi-state.json` is a separate private version-1 metadata store under the daemon's existing owner lock. It stores normalized intents, preparation fingerprints, original dispositions and actual canonical bindings, **not message bodies, history, terminal output or credentials**. Bounds: 2,000 receipts, 1,000 bindings, 4 MiB. Boot validates ownership, hashes, parent/pane relationships, binding/receipt consistency, unique managed files/chats, cross-domain command collisions and machine ownership.

A normalized intent commits before native spawn or extension dispatch. Admission and its start disposition commit together after public Pi binding. Work/runtime/Pi command admission and persistence fencing are shared. Failure fences further mutations, not accepted children. Original receipt reads remain available; missing receipt knowledge is not replay permission.

- `prepared`: persisted intent without a final dispatch disposition; may be in flight or uncertain. Do not replay.
- `dispatched`: the native admission or public Pi dispatch API was acknowledged; **not proof a message executed, was delivered, or settled**.
- `rejected`: a known pre-effect delivery guard rejected the intent, with its original error code.

A genuine Pi input hook can consume a void send. The uncertainty deadline fences further delivery rather than inventing a canonical message, rejection, success or retry. Same-command reconciliation never dispatches again, renews a viewing lease or answers another question.

## Reads and questions

Default `readMode:"live"` requires the captured admitted endpoint. Explicit `readMode:"stopped"` requires proven completed ownership and reconstructs the **persisted resume branch** from public Pi JSONL v3 parent links. That is not a claim to restore an unpersisted last UI selection. Stopped reads never discover/probe/start Pi. Uncertain writers, missing/changed files, unsupported format or incomplete data fail closed. No history writer or automatic repair is introduced.

History pages contain at most 50 canonical projections within a 48-KiB entry budget, with full source/read-mode/leaf/anchor-bound continuation. Recent snapshots reserve 32 KiB for entries plus the bounded question/source. Text previews are 2 KiB. Non-message/plugin/compaction bodies are not fully projected in this checkpoint; images and file bodies are not copied. Tool detail resolves the recorded canonical entry/tool-call pair and pages its recorded text with UTF-8 byte offsets (at most 8 KiB), not caller paths or full bash spool files. Large histories beyond the current 4-MiB private/file-read bound fail closed; scalable private paging and full view/observation contracts remain open.

Normal messages require ready/idle state; steering and cancel capture an active interaction. Pending questions block normal/steering sends. Only `pi-axo`'s public `axo_ask` tool exposes a remotely answerable question with question/interaction/option IDs. A remote offered answer closes the sibling local selector. Cancellation/invalid/late answers never grant approval. Generic public `ui_prompt_start/end` waits are observed but are **not remotely answerable permissions**.

Viewing leases are explicit chat-scoped metadata (maximum 16, TTL 1–120 seconds). They expire and are not subscriptions or a new attention-delivery system.

## Evidence and remaining gates

`cargo test --manifest-path axod/Cargo.toml --locked --offline --test managed_public -- --test-threads=1` owns the actual binaries, ambient Pi, private roots, Rust HTTP model and real Worker/Access fixture. Rust owns all daemon/Pi/process orchestration; the Node fixture only hosts Worker/workerd. Synthetic assertions stay in bounded private files. Owned compiler/Worker process groups retain an unreaped leader until cleanup, and terminal bytes are never interpreted.

The acceptance test exercises actual local CLI admission/messages/real bash/canonical history/tool pages, start/message reconciliation, owned questions/choices, viewing expiry/no renewal on replay, explicit steering/cancel/late rejection, clean restart/stopped reads/exact resume, actual cloud admission of an independent Pi and real tool effect, cloud/client loss, stale targets, consumed-input uncertainty and three-domain storage fencing without stopping accepted Pi. The separate 24-case TUI battery remains transitional TypeScript orchestration around the production Manager, not extra public-path cases.

**Not production/Mac readiness:** cooperative managed writer leases do not exclude arbitrary unmanaged same-user writers. An empty newly admitted Pi may not yet have persisted its lazy canonical file; missing exact-resume files reject rather than minting another chat. Full branch/view epochs and bidirectional history, compaction/plugin/spool projection, public observation/gaps, attachments under existing file authority, public-path sibling/cancellation/crash campaigns, escaped descendants/power-loss/soak, namespace/stop/pane/archive/cache/data-plane work and native adoption remain open. No live deployments, registry migrations, app packaging or restarts were performed.
