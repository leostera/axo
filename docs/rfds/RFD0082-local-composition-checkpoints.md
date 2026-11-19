# RFD0082 - Axo: local composition checkpoints

- Feature Name: `local-composition-checkpoints`
- Status: Accepted; in implementation
- Author: leostera
- Start Date: 2026-11-19
- Document Type: Snapshot

## Summary

Keep typed drafts and recognized dictation text in an account-scoped local atomic snapshot. Save recognized words synchronously as they arrive, independently of SwiftUI transcript handoff. Restore text for review only, never recording or Send intent. A second microphone tap cannot overwrite a finished transcript that has not been consumed.

## Motivation and guide-level explanation

The app previously kept drafts only in the `PhoneWorkbench` instance. Finished speech depended on a mounted composer's observation, and starting another dictation discarded an unconsumed transcript. Recognized words must survive navigation, interrupted finalization, view replacement and app relaunch. For example, typing “Fix” and dictating “the café” checkpoints the typed prefix and current speech separately; a relaunch restores “Fix the café” once, without sending.

## Reference-level explanation

`DraftTextStore` owns a versioned JSON archive under Application Support, scoped by the authenticated account UUID. Entries identify a host and optional Session; one separate voice checkpoint includes a recording UUID, destination and recognized text. `VoicePrompt` synchronously checkpoints live recognition and final text with the same UUID. `PhoneWorkbench.keepVoiceTranscript` replaces that checkpoint with the combined draft in one atomic snapshot. Explicit Cancel removes the recording checkpoint, not typed text. Ordinary navigation interrupts for review; explicit new-draft host selection retargets the same recording.

On load, merge the voice checkpoint into the in-memory base exactly once. The next snapshot contains the merged base and no old checkpoint. Restoring neither starts the microphone nor restores Send intent. Existing send admission, uncertainty and non-retry behavior are unchanged: this archive is not a durable command outbox. Attachments and unrecognized raw audio are not newly persisted by this change; only text actually received from the recognizer can be recovered.

`AccountSession` exposes only its account identifier for storage scoping. A signed-out or differently scoped old workbench cannot write its archive. Account changes replace the workbench view; old accounts' files remain untouched. Archives are excluded from backups and use iOS protection available after first unlock. No text is logged or uploaded by checkpointing. Corrupt/unknown-version data blocks replacement, leaving the original bytes intact; in-memory editing still works and a persistent warning explains the failure. Write failures also warn and preserve the current in-memory composition.

## Validation and rollout

Unit tests cover typed Unicode drafts, separate destinations, repeated recognition checkpoints, handoff without duplicate appends, restored Send intent remaining inert, explicit Cancel, late callbacks and sign-out fencing. Phone/tablet UI tests exercise typed prefixes, host/agent changes and cold relaunch during dictation. Install only immutable integrated releases in place, with current recording/draft preservation checks. No identities, account credentials, existing draft data or Watch apps are deleted or reset.

## Alternatives and drawbacks

Keeping only in-memory dictionaries is simpler but loses recognized text when the model is replaced. Saving only on background callbacks misses abrupt termination. A command outbox would require separate dispatch/receipt recovery semantics and is deliberately not introduced. Each recognition update writes a small snapshot; avoiding lost text takes precedence over batching. A crash during an existing network send remains subject to that send's existing uncertainty handling, not an exactly-once guarantee from this archive.
