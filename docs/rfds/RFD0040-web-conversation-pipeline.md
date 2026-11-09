# RFD0040 - Axo: The Web's Conversation Pipeline

- Feature Name: `axo-web-conversation-pipeline`
- Status: Accepted
- Author: leostera
- Start Date: 2026-11-09
- Updated: 2026-11-09
- Document Type: Proposal
- Amends: RFD0039 (the same pipeline, for the web app)

## Summary

I propose giving the web app's conversation the pipeline the phone got in RFD0039:

1. **Drawing never gates data.** Whether a row is in the conversation is decided by a model, `ConversationFeed`. A reply's words are let out by the feed's own clock, not by the row's animation frames, so a hidden tab, or a row that is not drawn, cannot hold the conversation back.
2. **Rows are made once, changed in place, and only ever added at the ends.** The list renders when a row is added or removed. A row renders when its own row changes. A reply streaming renders that reply.
3. **One owner for the scroll position.** It is the transcript's `ResizeObserver`, which runs after layout and before paint. While following, it puts the end in view. Otherwise it keeps the reader's row where it was.

## Motivation

The web shows the same conversation as the phone, built the way the phone was before RFD0039. A browser test (`test/conversation.test.mjs`, against a fake cloud, with 400 records and 50 on screen) measured it on 2026-11-09 (`bench/conversation-baseline.json`):

| What happens | Conversation renders | Row renders (rows above) | Markdown renders |
|---|---|---|---|
| A reply streams (20 updates) | 56 | 200: each row on screen, 4 times | 42 |
| 30 replies, 10 a second | 194 | 200 | 1,780 |
| A reply streams in another chat | 10 | 0 | 50 |

- **Everything renders on every event.** The app subscribes to the whole workbench, so every event from any chat renders the conversation. That recomputes which messages show and the rows, and reconciles every row. Each row also takes `working`, so Pi starting or stopping renders every row.
- **A hidden tab holds the conversation back.** The reveal of a reply runs on `requestAnimationFrame` in the row's view, and the view says when it is done. A hidden document runs no animation frames, so while the tab is hidden a reply that arrives is never let out, and the messages after it never come in. The test hides the page as a background tab is hidden, and the message after a reply is not there after 3 seconds hidden; it comes in only once the tab is shown. This is the stall the phone's trace found, by another route.

On a fast Mac none of this is slow (no long tasks). The web app also runs on phones, though, where reconciling every row on every word is not free, and the hidden-tab stall is a bug everywhere.

## Design

```
records, progress ──▶ ChatTranscript ──▶ ConversationFeed ──▶ ConversationRows ──▶ RowView ×n
   (the socket)        what happened      which rows, in        renders when a     renders when its
                                          what order; the       row is added or    own row changes
                                          reveal clock          removed
```

### The feed (`src/chat/feed.ts`)

A port of the phone's `ConversationFeed` and `ConversationReveal`, in plain TypeScript with no React:

- `items`: row objects, top to bottom. They are made once by key and changed in place. New rows go on the end, and an older page goes on the top. A cut, or a transcript read again, starts them again. A reply whose live words were cleared before its record arrived stays until the record takes its place.
- Each item has `row` (the message with what decides how it shows: live, rising in, being let out, and for tool rows whether Pi is working), `revealed` (characters out, while being let out) and its own subscription. The list subscribes to the feed, which notifies only when the set of rows changes.
- **Rows compare by content, not identity:** reading an older page rebuilds the transcript's messages, and an unchanged message keeps its row.
- **The reveal clock:** a timer every 32 ms, while a reply is being let out and the chat is on screen. It runs at the same pace as the phone's (`RevealPace`), and catches up faster with more waiting behind. A row holds the ones after it only while it is being let out.
- **On screen** is the chat being selected *and* the document being visible. Off screen, nothing is let out: a reveal under way shows whole, and what arrives just shows. Coming back on screen, what the chat holds is history.

The workbench keeps the feed of the chat on screen, in `changed()`, its one place for telling what changed. The other chats' feeds, and the open chat's while the tab is hidden (`setVisible`, from `visibilitychange`), are not kept. A chat that comes on screen, or a tab shown again, opens its feed, so everything it holds is history and shows at once.

### The list

- `ConversationRows` is a memoised component that subscribes to the feed and renders one `RowView` per item, keyed by id.
- `RowView` is memoised, subscribes to its item, and renders `MessageView` or `PendingView`. Its callbacks are stable, so the conversation rendering does not render it.
- `MessageView` no longer runs the reveal. It draws the first `revealed` characters, with the new words fading in as now.

### The scroll

The transcript column's `ResizeObserver` does all of it: a row added, a row growing, or an older page on top all change the column's size. Its callback runs after layout and before paint:

- following: the end;
- not following: the reader's row stays where it was (the anchor, as today), and "Jump to new message" shows if a row was added below.

The layout effect keyed on the workbench's version goes. The conversation no longer renders when rows change, so it could not see them anyway.

## Measured

Same test, same machine, before (`bench/conversation-baseline.json`) and after (`bench/conversation.json`). Each row is renders, or for the last row a time:

| What happens | Before | After |
|---|---|---|
| A reply streams: rows above it | 200 | 2 |
| A reply streams: Markdown | 42 | 44 |
| 30 replies: rows already there | 200 | 58 (each new reply, as it arrives and once it is all out) |
| 30 replies: Markdown | 1,814 | 588 |
| A reply in another chat: rows | 0 | 0 |
| A tab shown again: what arrived while hidden is there | 204 ms | 6 ms |

In every frame painted while following, the end is in view, before and after: the test watches from a `ResizeObserver` that runs after the app's.

The conversation itself still renders on every event (54 times for one streamed reply), for the composer and the bars around the rows. It no longer reaches the rows, so it costs little. Splitting it further can wait for a measurement that says it matters.

## Invariants

- I1: the rows the list renders are the feed's, in its order.
- I2: no row waits on a view, an animation frame or visibility. The feed's rows depend only on the transcript, the waiting prompts, the clock and whether the chat is on screen.
- I3: a row already shown keeps its place.
- I4: a reply streaming renders its row alone, and an event in another chat renders no row.

## Tests

- **Model (`chat-model.test.ts`):**
  - The feed keeps rows in place, appends and prepends, and resets on a cut.
  - A reveal finishes with no view, by its clock.
  - Off screen, nothing is held.
  - An unchanged message keeps its row object across a rebuild.
- **Browser (`conversation.test.mjs`):**
  - The measurements above, with budgets: while a reply streams, the rows above it render at most 4 times. A reply in another chat renders no row.
  - The last row is in view after the stream and after the flood.
  - What arrived while the tab was hidden is there when it is shown again, at once.
  - In every frame painted while following, the end is in view.

## Alternatives

- **Virtualise the list** (render only the rows near the screen). The chat already opens with 50 rows and grows by pages, and browsers lay out a few thousand nodes cheaply. Virtualising brings back estimated heights, the phone's original bug, so it is not worth doing until a measurement says otherwise.
- **`content-visibility: auto` on rows.** It is cheaper than virtualising, but it also introduces estimated heights off screen, under the anchoring. Not now, for the same reason.
- **Memoise harder without a model** (stable props, `useMemo` on the rows). It cuts some renders, but leaves the reveal in the view, and the hidden-tab stall with it.
