# Scoped draft persistence integration — build142

## Exact delivery and scope

Implementation **`223a537eda5aa14d77c9b9e5f7ebdd1c97069b17`**, `dist/Axo.app` **build142**, bundled helper **`0.1.0 (223a537e)`**, matching `AxoBuildCommit`; `codesign --verify --deep --strict` passes. This connects the [build140 dormant storage foundation](private-draft-storage.md) to production editor/coordinator state. It does **not** close M12/M13, A09/A10 or any full workflow gate. The running app/helper, live data, API deployment and physical phone were left untouched. An exact package is not a live helper upgrade.

## Implemented boundaries

- Production `AxodChatDrafts` requires trusted private storage loading before editing/submission. `AxodDraftPersistence` serializes encoding, disk reads and atomic commits off the main actor. Typing captures bounded immutable rows, with at most one active write and one coalesced latest snapshot, not a write-task queue per keystroke. Budgets remain 32 editable drafts/32 pending records, 64KiB per draft/1MiB aggregate and 2MiB archive; RPC/terminal bounds are unchanged.
- Only the fixed `chat-drafts` child of the captured private local state root is provisioned. Existing unsafe roots/files are not repaired/replaced. Creation flushes the parent; subsequent storage retains no-follow component walking, pinned descriptor identities, regular single-link0600 files, validated transaction-local leases, store-bound exact-byte CAS, atomic same-directory writes and uncertain-I/O fencing.
- Private binary **v2** adds a closed original send/steer operation to each pending ticket. Complete original target/command/text revision survive loading, including a ticket without a text row. Older/unknown/corrupt formats are preserved and block use; there is no inferred conversion or legacy import. Build140's v1 was dormant, not a production editor format.
- Logical editable identity excludes runtime/host generations. Dispatch separately captures current complete target, operation and interaction. A captured ticket must be durably saved **before** the pending preference hint or RPC; operation/connection/private-endpoint authority and observed cancellation are rechecked after that await. Storage data never grants permission to send.
- Validated original receipts and known no-effect results await durable settlement before clearing matching text/hints. Only the unchanged original revision clears; later/ABA edits survive. A failed/conflicting/busy store preserves local text and original data, blocks sending and does not automatically merge/retry. Loaded text remains locally editable after failure, but is explicitly unsaved.
- When the preference hint is absent, a restored archive ticket permits only **original read-only command lookup**. This covers the archive-before-hint window without recreating a hint or resending. Opaque/non-Data preferences are preserved and never bypassed. Prepared/null/mismatched/unknown results do not clear data or grant replacement-command authority.
- Unavailable draft storage or matching restored pending intent blocks automatic empty startup at both native checks. Explicit New Session and daemon-owned terminals remain independent. The ordinary quit hook commits the field editor, freezes accepted editing and awaits the save barrier; storage/capacity refusal cancels quit with an inline explanation, never a daemon stop. Actual OS quit/IME acceptance is still open; force termination is not guaranteed to preserve unsaved keystrokes.

## Passing evidence

### Exact packaged native/local route

Two full fresh-root rounds, **seven modes / 14 owned scenarios / 38 component-owner PASS lines**, using the exact bundled helper and installed adapter. Existing delayed/unavailable/automatic/pending/panes/chat regressions pass through production coordinator/views, actual local RPC, daemon PTYs and ambient interactive Pi.

- Chat retains normal tool/title/canonical history, offered/stale answer with usable shell, cancellation and steering, exact original runtimes, and **eight model requests per chat scenario**.
- A fresh coordinator loads `preserved after actual steering` from disk. The owned check then captures and saves an intentionally **never-sent** original ticket without a preference hint. Another fresh coordinator restores its exact identity/text; actual original command lookup returns null, preserving pending/text without a new message/model call or runtime. This is not a lost mutation reply or process-crash test.
- The new `storage` mode starts with an owned opaque private archive. Automatic startup creates no work; bytes remain unchanged and editor dispatch is unavailable. Explicit direct New Session still commits/selects metadata, supplies captured Pi-left/shell-right terminals and usable shell input. Reconnect/fresh coordinator/disposal preserve bytes and accepted runtimes.

These are offscreen owned production components and fresh **coordinators in one application process**, not Finder/ServiceManagement, actual text-field/button/OS-input/IME, actual app process exit/crash, deployed API or phone acceptance.

### Component/regression lanes

- `check-mac-draft-persistence.sh`: 1,000 coalesced synthetic editor revisions, fresh cache/runtime-generation-independent text, exact original operation/target/revision ticket restoration, no capture over unresolved ticket, wrong-target refusal, rejected/unknown/ABA outcomes, durable unchanged-revision clearing, competing stale-store refusal, writer-lease failure preserving text/ticket, opaque-file preservation, successful quit freeze/flush and failed quit without discarding text.
- `check-mac-chat-drafts.sh`: existing bounded draft/receipt/preflight checks pass.
- `check-mac-draft-storage.sh`: archive/storage/fault checks pass, including older/future version and invalid operation refusal. Fault seams remain compile-only. Same-kernel reopen/pre-post-rename injection is not crash/power-loss proof.
- Exact helper public CLI **8 passed**; exact helper AxoCore **81 passed/no skips**.
- Full serial Rust **104 library + interactive1/local2/managed-public1/CLI8/relay4** pass; all-target strict Clippy and formatting pass. Swift protocol **41 executed/one existing real-daemon E2E skip**; no coverage is claimed for that skip. Pane-layout and shell-creation checks pass.
- Mac compile, atomic packaging and deep strict signature pass. Existing MacAppearance actor-conformance, linker search-path and AppIntents warnings remain nonfatal. No new TS/API/iOS build/device/deployment results are claimed.

Logs: `/tmp/axo-durable-draft-{unit-initial,storage-initial,build-initial,build-rerun,native-initial,persistence-initial,persistence-quit,unit-final,storage-final,build-final,native-expanded,persistence-final,build-precommit,native-final,clippy,rust,core,protocol,storage-v2,layout,shell,package-exact}.log`; final exact-package `/tmp/axo-durable-draft-142-{native,cli,core,unit,storage,persistence}.log`. Intermediate packages are not the final exact-source claim. No failing test run occurred in this owning campaign; earlier storage/chat failures remain in their historical evidence rather than being erased.

## Still-required acceptance

**M12/M13/A09/A10 remain incomplete.** Actual rendered composer/source-selection/field-editor/button/keyboard/IME/capacity cases, concurrent app processes, known rejected/unknown/lost-reply receipts, real ordinary app exit/crash/recovery and storage-fault handling must pass on required surfaces. Branch-authoritative draft policy, bounded history/tool detail/reading/navigation and binding transfer remain unimplemented. A cache reopen, valid archive or quit-state test is not app-exit/power-loss proof. Live service/handoff, terminal fidelity, deployed API/phone and all other supported-workflow gates remain open; no scope is deferred by this checkpoint.
