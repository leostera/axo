# RFD0049 - Axo: browser conversation cache

- Feature Name: `web-conversation-cache`
- Status: Implemented (Axo 0.59)
- Author: leostera
- Start Date: 2026-11-14
- Updated: 2026-11-14
- Document Type: Snapshot
- Amends: [RFD0040](RFD0040-web-conversation-pipeline.md)

## Summary

After authentication, paint recent account-scoped conversations, the selected chat and text drafts from a bounded browser snapshot while the live connection opens. This is a display cache, not an offline command queue or a trusted transcript replica. Replace each cached conversation with a fresh server window before enabling its composer and transcript actions.

## Motivation

Refreshing previously emptied the UI until hosts and history returned. The composer also tried to focus while disabled, never retrying when the connection became ready. Keep the conversation visible during reconnect and put focus where the person will type, without taking it from a search or dialog they opened meanwhile.

## Guide-level explanation

A person refreshes a chat with an unfinished draft. Once their sign-in is verified, its recent messages, sidebar and draft appear with “Connecting to Mac…”. The cached conversation is read-only. The connection fetches the authoritative listing and newest history window; stale messages are replaced, the draft stays, and the message field becomes ready. It takes focus only if the person has not focused something else.

A deep link absent from the bounded snapshot waits for the live listing. An invalid link becomes a new chat, never an unrelated cached conversation. A disappeared chat or Mac is removed by live reconciliation.

## Reference-level explanation

- `packages/axo-web-app/src/chat/cache.ts` owns versioned localStorage persistence, parsing and eviction. `ChatWorkbench` owns hydration, dirty-state debounce, synchronous `pagehide`/dispose flush and live replacement. `ChatApp` receives the account ID only from the authenticated session and creates a fresh workbench when it changes.
- Keys are `axo.chats.v1.<accountId>`. Authentication still finishes before reading a snapshot; cached identity/profile data cannot authenticate a person. This does not make the sign-in check offline or replace the existing sign-in screen.
- A snapshot holds host/session metadata, last selection, up to ten recently opened transcript previews and 32 text drafts. Presence/status is normalized to offline/unknown on read. Persisted listing epochs/heads are null/zero; restored chat epochs are null. `openChat` never supplies a cached cursor in `have`, even if an intervening live reset assigns an epoch.
- Limits: 64 hosts; 1,000 sessions, prioritizing the selected session and then recency; 128 records and 192 KiB per written preview; 16,000 UTF-8 bytes per draft; 2 MiB encoded snapshot; seven-day expiry. Older conversation previews are evicted when storage refuses a write. A record too large for its preview budget is not persisted, so a preview can be empty. Full history remains on the server.
- Parse the entire external snapshot before applying it: version/time/size, protocol schemas, host/session membership, ascending record cursors and draft ownership. Malformed, expired, denied or exhausted storage is a cache miss, not a chat failure. Unknown versions are ignored; there is no migration layer for an optional display cache.
- Durable state/navigation/drafts schedule a 300 ms debounce. Streaming progress alone does not serialize the cache. Refresh/unmount flush synchronously so a last keystroke does not depend on the debounce finishing.
- Sign-out clears this account’s cache and disables its writer before invoking logout. Storage-clear events disable writers in other open tabs, preventing pending callbacks from repopulating it. Account changes create an isolated workbench/key; no other account’s cache is read.
- Live progress, pending command delivery/retries, uploads, approval requests, device keys and account credentials are not serialized. Cached raw transcript lines can naturally contain sensitive conversation content; localStorage is not encrypted and remains accessible to same-origin code and the browser profile. No telemetry or transcript logging is added.
- The feed and scroll owner remain those of RFD0040. Cached content is settled history, never a resumed live reveal. Composer focus runs again when ready but preserves another focused control during reconnect; selecting a chat still directs keyboard focus to its composer.

## Validation

Model tests cover pre-connection hydration, preserved selection/drafts, no transient progress, blocked cached sends, fresh-window replacement including changed content at the same cursor, account isolation, sign-out/late writes, corrupt/expired/oversized snapshots, byte/record limits and unavailable storage. Browser tests hold cloud replies during refresh, verify cached messages/sidebar/draft before release, verify fresh replacement and initial focus, preserve search focus during reconnect, and clear storage across two tabs. Existing invalid-link, conversation rendering/scroll, shared-session and tools browser tests remain regression gates. All 79 standard Bazel test targets pass; native fixture and paused-cloud browser screenshots were reviewed without installing or restarting the active app.

### Publication evidence

Axo 0.59 (Mac 330 / axod 80, release commit `2a3983fc6802f88aa6e3970abcdca7a89cb54758`) was pushed and published as `axo-0.59-2a3983fc6802-aarch64-apple-darwin.zip`. Worker deployment `f675b310-7ce6-4cf4-b4c7-0be6ef6a3efa` serves the new web bundles; downloaded public JavaScript matches the built assets byte-for-byte, and the public HTML references the new entry bundle. All 79 standard Bazel test targets pass.

The public latest/legacy manifests agree. The new archive verifies against the configured signing identity/team and captured version/build/commit; a probe compiled from the actual updater fetched the public manifest and verified the downloaded release without installing it. Manifest and archive cache headers are respectively no-store and immutable. The prior 0.58 immutable archive remains byte-for-byte unchanged. All seven codemode model/task integration cases passed again using the downloaded 0.59 helpers/resources in an isolated test account/daemon. The active app and Session were not restarted or installed over.

## Drawbacks and alternatives

- Conversation text now persists in the browser profile for up to seven days unless explicitly signed out or browser storage is cleared. It is not encrypted at rest by Axo. Bounds and eviction mean not every past chat or oversized entry is available as a preview.
- localStorage is synchronous; bound the snapshot and debounce writes rather than writing on every progress frame. IndexedDB is an alternative if measured costs justify more lifecycle complexity; no performance improvement is claimed here.
- Caching only the sidebar is simpler but still leaves the open conversation blank. Caching the full workbench or replaying cached commands risks stale approvals, duplicate operations and invented continuity.
- Trusting persisted epochs/cursors would reduce rereads but requires a stronger replica-integrity contract. Always fetch a fresh window instead.
- Doing nothing preserves the refresh blank state and the failed initial focus attempt. Full offline editing/sending, persisted scroll anchors, cached attachment blobs and cross-tab live auth synchronization remain out of scope.
