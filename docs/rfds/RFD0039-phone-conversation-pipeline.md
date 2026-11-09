# RFD0039 - Axo: The Phone's Conversation Pipeline

- Feature Name: `axo-phone-conversation-pipeline`
- Status: Accepted
- Author: leostera
- Start Date: 2026-11-09
- Updated: 2026-11-09
- Document Type: Proposal

## Summary

I propose rebuilding how the iPhone app turns a Session's records into the conversation on screen, on three rules:

1. **Drawing never gates data.** Whether a row is in the conversation is decided by the model alone. No view appearing, finishing an animation or being measured can hold a row back.
2. **One owner for the scroll position.** The list's own layout pass decides where the conversation is scrolled to, at the moment row sizes change. Nothing else sets it.
3. **Rows are made once, changed in place, and only ever added at the ends.** The list hears which rows were added or removed, and nothing else. A row's content changes inside its row: a streaming reply redraws one row.

The list becomes a UIKit `UICollectionView` with a diffable data source, and its rows are drawn by SwiftUI (`UIHostingConfiguration`). The reveal of a reply's words, which today waits on the row's view, runs on a clock in the model.

## Motivation

Leo reports that opening a busy chat on the phone often shows an empty screen (2026-11-08 and 2026-11-09, on 0.39 to 0.42). Two fixes did not fix it: the scroll offset resting past the end (380a06d), and making the rows append-only (c1cd910). A trace from the phone (Axo 0.42 (31), with logging of the feed, the rows appearing and the scroll geometry, 2026-11-09 18:42) shows why: the failures are structural.

**A reveal that never ran held the conversation back.** A reply that arrives while the chat is on screen has its words let out over time, and the rows after it wait until it is done (`ConversationReveal.shown` stops at an unfinished reveal). "Done" is reported by the row's view (`RevealedMarkdown.letOut` calls `finished`). The trace has reply `reply:1794246247275#0` revealing in 15 consecutive feed updates, with no `row +` for it: its view never appeared, so it never finished. Meanwhile the transcript grew from 122 to 124 messages, and the screen kept showing 122. A lazy list does not promise to make a view: an empty view (a reveal at zero characters) or one the list has not reached is never made. So whether data shows depended on how SwiftUI laid out a row, which nothing guarantees.

**Two mechanisms moved the scroll position.** After a correction to the measured end (75917), the offset went back to 75989 within the same millisecond, five times in a row (18:44:21.887–21.889). `ScrollPosition`'s own tracking of the row at the bottom and the corrections in `keepWithinEnd` disagree, and each undoes the other. Before that, every move to the end landed on estimated heights: on opening, the end was 7644, then 6792, 8774, 8855, 8390 within 30 ms as the lazy stack measured rows. That is the earlier bug's mechanism (a move to an estimate, then the content shrinks), and patching it from outside cannot be made exact, because SwiftUI does not expose its estimates or when it replaces them.

**An older page loaded on its own.** The list is laid out first at its top (offset −113), where "Load earlier messages" calls `loadOlder` from `onAppear`. So opening the chat parsed and laid out 63 more messages before the reader scrolled at all.

**Everything was redrawn.** Before c1cd910 the whole transcript was one observed value. Every word of a reply laid out the list again and redrew each row on screen (24 list redraws per 20 streamed updates). c1cd910 fixed that in the model, but the list is still a SwiftUI `LazyVStack`, whose estimates and scroll tracking are the two problems above.

## Goals

- Opening any chat, of any length and in any state, shows its newest rows, just above the message box, in the first frame drawn after its records arrive.
- While the reader follows, the newest line stays just above the message box, exactly, as rows are added and grow. There is no frame where the conversation is scrolled past its end or short of it.
- A reader who scrolls up stays where they are while rows are added below or an older page above.
- A reply being written redraws only its own row. The list changes only when a row is added or removed.
- Memory grows with the rows on screen, not with the conversation: rows off screen are not kept as views.
- Every row in the transcript reaches the screen, however views are made or animated.

## Non-goals

- Changing the transcript, the records protocol or the feed's row order (c1cd910's `ConversationFeed` contract stays).
- Changing how rows look. The row views (`ChatMessageView`, `ToolTranscriptView`, the cards) are reused as they are.
- The Mac app and the web app.

## Guide-level explanation

A conversation is a pipeline of four stages, each with one job and one owner:

```
records, progress ──▶ ChatTranscript ──▶ ConversationFeed ──▶ ConversationList ──▶ rows on screen
   (the Mac)          what happened       which rows, in        which rows are       each row draws
                                          what order, with      where; where the     its own content
                                          what content          list is scrolled
```

**ChatTranscript** (unchanged) applies records and progress: messages, the reply being written, tools, questions, queued prompts.

**ConversationFeed** (from c1cd910, extended) turns the transcript into rows. Each row is an object, made once, whose content is observed on its own. The feed also owns the **reveal clock**: while the chat is on screen, a reply's words are let out a step at a time by a timer in the feed, and the rows after it are held back in the feed until it is done. The clock does not wait for any view. If the chat is not on screen, or motion is reduced, a reveal is done at once. A reveal never holds rows back for longer than its words take at the hurried pace.

The feed tells the list what happened to the rows, as one of four changes: rows added at the end, rows added at the top (an older page), rows removed (a message taken back), or the rows started again (a cut, or a reload). It never tells the list that a row changed: the row's view hears that itself.

**ConversationList** is a `UICollectionView` with a diffable data source of row ids. Each cell hosts the row's SwiftUI view. When a row's content grows, its view grows, and the cell sizes itself again. UIKit moves only the rows below it. Off-screen cells are reused for other rows.

The list owns the scroll position. In its layout pass, after UIKit has sized the rows:

- If the reader is following, the offset is set to the end: the content's height less the visible height, on a whole pixel. This happens in the same pass that changed the sizes, so no frame is drawn in between.
- If an older page went on top, the offset grows by the height added above the first row that was on screen, so that row stays where it was.
- Otherwise it is left alone.

Nothing else sets the offset. Whether to follow is still `ScrollFollow`'s decision, from how the reader scrolls.

### Examples

**Opening a busy chat.** The records arrive: the feed makes 51 rows, and the list applies one snapshot with them. In its next layout pass UIKit sizes the rows near the end (estimating the rest), and the list sets the offset to the end. A moment later the reply's progress arrives: the feed adds the reply's row, the list appends it, and its layout pass pins the end again. The reply's words are let out by the feed's clock. Each step changes that row's text, and its cell grows by a line. In the next layout pass the offset follows.

**Streaming.** Twenty progress updates change one row's content twenty times. The list applies no snapshot and lays out one cell twenty times. No other row's view runs.

**Scrolled up.** The reader drags up and stops: `ScrollFollow` stops following, and the list leaves the offset alone from then on. New rows go on the end below. The "Jump to new message" button shows. The reader nears the top, the next older page is read, and the feed adds its rows on the top. The list keeps the row the reader was looking at in place.

## Reference-level explanation

### The feed

`ConversationFeed` keeps its contract from c1cd910: `items` only gain rows at the end, except for an older page (top), a message taken back, and a reset. It changes in two ways:

- **Changes are announced, in the same turn.** After every change to its rows, the feed calls `changed(grew:)` synchronously, with the ids of the rows whose content changed (a reply's words coming out, a record taking a live row's place). The list applies its snapshot (the feed's ids, so a diff of appends at the end, an older page at the top, or a removal) and sizes the rows that grew. All of it happens before the frame is drawn.
  - At first I let the list observe `items` and apply on the next turn, but the rows came one frame late and the cells were sized in a later layout pass. In between, a reply's new lines were drawn over the rows below it, and a finished reply's buttons over the next reply. Screenshots of the flood at 5 a second caught it in about half the frames.
- **The reveal clock.** `ConversationFeed.Item` gets `revealed: Int?`, the number of characters of its text let out, nil when it shows whole. A clock task on the main actor runs only while some row is revealing and the chat is on screen (`feed.onScreen`). Every `RevealPace.frame` (32 ms) it advances each revealing row by `RevealPace.next`. A row whose text is all out, and which is final (its record is in), stops revealing, and the rows it held come in. `ConversationReveal`'s decisions (what is history, what rises, what reveals, the "caught up" rule) stay as they are. Only who advances the reveal moves: from the view's `.task` to the feed's clock.
  - Off screen or with motion reduced, no reveal starts, and those under way finish at once.
  - `RevealedMarkdown` becomes a plain view of `item.revealed` characters of the text.

### The list

`ConversationList` is a `UIViewRepresentable` owning a `ConversationCollectionView` (a `UICollectionView` subclass) and its coordinator.

- **Layout:** `UICollectionViewCompositionalLayout` with one section of full-width items. Heights are estimated (`.estimated(120)`) and self-sizing. Spacing is 30 points between rows, as now.
- **Data source:** `UICollectionViewDiffableDataSource<Section, ID>` with sections `top` (the older-history control), `rows` and `bottom` (the question, the activity row, the extensions' cards). Each change from the feed is one snapshot change: `appendItems`, `insertItems(beforeItem:)` for the top, `deleteItems`, or a new snapshot for a reset. It is applied without animation, except a removal, which fades.
- **Cells:** `UICollectionViewCell` with `contentConfiguration = UIHostingConfiguration { ConversationItemView(item:…) }.margins(.all, 0)`, registered once per kind. The row's SwiftUI view observes its item, so content changes redraw it. The environment the rows read is passed in explicitly, since a hosting configuration does not inherit it: the `SidewaysScrolling` model and the tint. The colour scheme comes through UIKit's traits.
- **Sizing:** a row that grew is sized at once. Its cell is asked for its size again (`invalidateIntrinsicContentSize`, UIKit's own path for this), and the list lays out now (`layoutIfNeeded`) rather than in the next pass. Invalidating the item in the layout instead made every visible row's view run again on every step of a reveal (63 extra message redraws for 20 streamed updates).
- **Rows are never empty, and never wider than the column** (`LeadingColumn`).
  - A row is at least a point tall. A cell with no height is not among the visible cells, and a cell that is not visible never hears that its content grew. A reply whose reveal starts at no characters stayed hidden for good, the same trap the old list had.
  - A row is exactly as wide as the column and starts at its leading edge. A hosted cell centres content wider than itself, and a half-written code block is.
- **Cells clip** what they draw to their frame, so nothing is ever drawn over the row below.
- **Insets:** the bars above and below stay SwiftUI. The list runs under them (`ignoresSafeArea`) and takes their heights, and the keyboard's, as `contentInset`. They are measured where the list would sit without them (`onGeometryChange` on the safe area) and handed to it directly, without redrawing the screen. It sets `contentInsetAdjustmentBehavior = .never`, so UIKit's own adjustment does not double them. Touches where the bars cover the list go to the bars (`hitTest`); otherwise the full-screen list took the menu button's taps.

### The scroll owner

`ConversationCollectionView.layoutSubviews()` calls `super`, then `pin()`:

```swift
let end = max(-contentInset.top, contentSize.height + contentInset.bottom - bounds.height)
switch scroller.mode {
case .following: if contentOffset.y != end.pixelRounded { contentOffset.y = end.pixelRounded }
case .anchored(let id, let minY):  // an older page went on top
  if let frame = layoutAttributesForItem(at: indexPath(id))?.frame { contentOffset.y += frame.minY - minY }
  scroller.mode = .free
case .free: break
}
```

- `scroller.mode` is `.following` while `ScrollFollow.isFollowing` and nothing holds the list (a finger, a coast, an animated move to the end).
  - Otherwise, after every pass, the reader's row stays where it was. That row is the first whose top is in view, recorded by its place in the content at the end of each pass. However rows above it grew, or an older page arrived, the offset moves by what moved that row, less what the layout moved the offset by itself.
  - That one rule covers both the prepend and rows measured late as the reader scrolls up, so there is no separate `.anchored` mode.
- The scroll view delegate reports phases to `ScrollFollow` as today: dragging is `byReader`, deceleration ends in `idle`. It also reports when the reader is within one screen of the top. Only then is an older page read, and only once the reader has scrolled.
- "Jump to new message" and sending set the mode to `.following` and animate to the end with `setContentOffset(_:animated:)`.
- The pull-to-refresh mascot reads the overscroll at the top from `scrollViewDidScroll`, as `Overscroll` does today.

### Invariants

- **I1. Every row the feed holds is in the list's snapshot,** in the feed's order, after each change is applied.
- **I2. No row waits on a view.** The feed's rows depend only on the transcript, the pending prompts and the clock.
- **I3. A reveal holds rows back for a bounded time.** It is at most the time its text takes at `RevealPace.hurriedCharactersPerSecond` after its record arrives.
- **I4. While following, after every layout pass, the offset is the end,** to the pixel.
- **I5. A row is never moved.** Rows already listed keep their relative order, and new ones go only at the ends.
- **I6. A row's content change redraws that row's view alone.** The list applies no snapshot for it.

### Tests

- **Feed (model tests, `ConversationFeedTests`):**
  - I1, I2, I3 and I5 through scripted runs, stepping the clock by hand.
  - A regression for the trace: a reply no view ever draws is still let out, and the rows behind it come in, within the time its words take.
  - Letting words out changes the row, not the list. The list is told which rows changed, and only those.
- **List (UI tests, through the preview's fake Mac):**
  - A flood of 30 replies keeps the last one in view, and nothing is drawn left of the column in any sample. The column is checked from screenshots, not accessibility frames, which a row being resized reports for its next size for a moment (`AxoPhoneFollowTests`).
  - Following rests at the end, not past it. Scrolled up, the reader is left where they were and told something is new. "Jump to new message" follows to the last reply.
  - The render counts: while a reply streams, the messages above it redraw at most once, and the list only when a row is added (`AxoPhoneRenderTests`).
  - Not yet built: opening a long chat (a real 1,500-record log as a fixture) shows its last row in the first screenshot with no older page read, and a reader's row holds within a pixel as an older page loads above it.
- **Device:** the trace's scenario on Leo's phone: open a busy chat; it shows its newest rows.

## Drawbacks

- UIKit in a SwiftUI app: a representable, a coordinator and cell registration, about 400 lines.
- The SwiftUI environment is not inherited by hosting cells, so anything the rows read from it has to be passed in, and forgetting one is a bug that only shows on a row.
- `UIHostingConfiguration` cells have their own costs: a hosting view per cell, reused. That is still fewer views than now, since the lazy stack keeps views alive in its window too.

## Alternatives

- **(b) Keep SwiftUI's lazy stack, flipped upside down** (a scroll view rotated 180°, rows rotated back), so the newest row is at the start and following needs no offset at all. This is the usual React Native and SwiftUI chat trick. But it keeps the stack's estimates for scrolling up and loading older pages, needs the rotation undone for context menus, VoiceOver order and gestures, and keeps two scroll mechanisms.
- **(c) Keep the current list and fix what the trace found.** That means moving the reveal clock into the feed (which this RFD does anyway) and dropping `ScrollPosition`'s tracking. The blank screen might go, but the offset would still be corrected after SwiftUI's own layout, from outside, against estimates it does not expose. Each fix so far has found the next way for that to go wrong.
- **(d) Drop the reveal's hold on the rows after a reply.** This is simpler, and removes the stall by construction, but the web app holds them (ed8f8b0), and Leo asked for parity.

I recommend the proposal, with the reveal clock built first. It is needed whichever list we choose, and it alone removes the stall the trace shows.

## Prior art

- **Signal iOS:** a `UICollectionView` with a custom layout for its conversation, keeping the bottom pinned in layout (`ConversationViewLayout`, `ConversationViewController+Scroll`).
- **Element iOS:** a `UITableView` for the room timeline.
- **Exyte Chat:** a SwiftUI chat library that wraps a `UITableView` rather than a lazy stack, citing scroll position control.
- **Apple:** `UIHostingConfiguration` (WWDC22, "Use SwiftUI with UIKit") is the supported way to draw SwiftUI in collection view cells, with self-sizing on content change.

## Rollout

These are slices, each tested, committed and installed on the phone:

1. The reveal clock in the feed, and its regression test. This alone fixes the stall (72bfc14).
2. `ConversationList` with all of it, in one change: the rows, top and bottom, following and the end pin, the reader's row kept in place, older pages read on scrolling up, and pull-to-refresh. It replaces `ScrollingToEnd`, `Scrolled`, `keepWithinEnd` and the lazy stack. Splitting it did not pay: the old and new lists could not share the scroll position, so a half-way slice would have had two owners, which is what this RFD removes.
