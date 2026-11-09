import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// One chat: the replies and what was asked, newest at the bottom. With no `session` it is a new
/// chat that does not exist yet; it comes to exist, in the Mac's Home Workspace, when its first
/// message is sent.
struct ConversationView: View {
  /// Sends, and keeps each chat's box. Passed whole, rather than as a binding and closures: a
  /// reference compares by identity, so a parent redrawing does not redraw this; and the box's
  /// words are read only by the box, so typing does not either.
  let phone: PhoneWorkbench
  let workbench: HostWorkbenchModel?
  let session: RemoteSession?
  let showSidebar: () -> Void
  /// Saying a message instead of typing it, where the iPhone can.
  let voice: VoicePrompt?
  /// Settings › Apps, from the box's + menu.
  var showApps: (() -> Void)?
  /// When to follow what is new and when to leave the reader be.
  @State private var follow = ScrollFollow()
  #if DEBUG && targetEnvironment(simulator)
    /// For the flood preview's test: what the scroll view and `follow` did, newest last.
    @State private var followTrace: [String] = []
    private func trace(_ line: String) {
      guard PreviewFixture.live == "flood" else { return }
      followTrace = Array((followTrace + [line]).suffix(40))
    }
  #else
    private func trace(_ line: String) {}
  #endif
  /// Where the end is and how the scroll view is moving, as last measured, and the way to scroll
  /// it; not observed.
  @State private var scrolled = Scrolled()
  @State private var scrollToLatestRequest = 0
  /// Pull-to-refresh, played by Axo: the empty chat's Axo, or a small one at the top.
  @State private var pull = ConversationPull()
  /// The screen's bottom inset: the home indicator's (at most a few dozen points), or the
  /// keyboard's while it is up (always far taller).
  @State private var bottomInset: CGFloat = 0
  /// The rows of a chat that does not exist yet: none.
  @State private var noFeed = ConversationFeed()
  /// What the rows do, kept apart so that a row compares equal to itself when the list redraws.
  @State private var actions = ConversationRowActions()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.displayScale) private var displayScale
  private var keyboardIsUp: Bool { bottomInset > 100 }

  /// This chat's own state: what it reads is what redraws it, so other chats' events do not.
  private var chat: Chat? { session.flatMap { workbench?.chat($0.sessionId) } }
  /// The conversation's rows, kept as the transcript changes (see `ConversationFeed`). The list
  /// reads only them: a reply being written redraws its own row, and the list only gains rows.
  private var feed: ConversationFeed { chat?.feed ?? noFeed }

  var body: some View {
    let _ = RenderCount.note("Conversation")
    conversation
      .background(ChatColors.background)
      .conversationBar(edge: .top) { header }
      .conversationBar(edge: .bottom) { bottomBar }
      .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
      // On screen, what the chat holds is history: it just appears.
      .onChange(of: session?.sessionId, initial: true) { previous, _ in
        // The chat left on its own: what it lets out shows whole from now on.
        if let previous, previous != session?.sessionId { workbench?.chat(previous).feed.closed() }
        actions.chat(session?.sessionId, workbench: workbench, phone: phone)
        feed.animates = !reduceMotion
        feed.opened()
      }
      .onChange(of: reduceMotion) { feed.animates = !reduceMotion }
      #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topTrailing) {
          if PreviewFixture.live == "flood" {
            Text(followTrace.joined(separator: " | ")).font(.system(size: 1)).opacity(0.01)
              .frame(width: 1, height: 1).accessibilityIdentifier("follow-trace")
          }
        }
      #endif
  }

  private var conversation: some View {
    ScrollingToEnd(scrolled: scrolled, anchor: Self.endAnchor) {
      let _ = RenderCount.note("Transcript")
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 30) {
          // What reads the chat's history state, which changes with every record, reads it itself.
          OlderHistoryRow(chat: chat, load: loadOlder)
          if feed.items.isEmpty { ConversationEmptyState(chat: chat, isNew: session == nil, canSend: canSend, pull: pull) }
          // The rows, each made once and kept where it came (see `ConversationFeed`); each redraws
          // when its own row changes.
          ForEach(feed.items) { item in
            ConversationItemView(item: item, feed: feed, actions: actions)
          }
          if let id = session?.sessionId {
            ElicitationCards(phone: phone, session: id, canAnswer: workbench?.status == .online)
            ConversationFooter(feed: feed, chat: chat, workbench: workbench, session: id, canSend: canSend)
          }
          Color.clear.frame(height: 1).id(Self.end)
        }
        .scrollTargetLayout()
        // No padding at the bottom: the stack's spacing before the end marker is the room under
        // the last row, and the end is where the content ends.
        .padding(.top, 24)
        // Exactly as wide as the screen: a row that asked for more would otherwise widen the
        // column, and scrolling to the end would slide it sideways.
        .containerRelativeFrame(.horizontal, alignment: .leading)
      }
      // The column's margins are the scroll view's, not padding inside it: the scroll position
      // lines a row's edge up with the content's edge, and with padding inside, every row slid
      // 20 points under the left edge of the screen.
      .contentMargins(.horizontal, 20, for: .scrollContent)
      // Following what is new; watched apart, so the reply growing does not redraw the list. On
      // the scroll view, not in the lazy stack, which lets go of what is scrolled away.
      .background {
        EndWatcher(
          feed: feed, chat: chat,
          changed: {
            let decided = follow.contentChangedAtEnd()
            trace("content \(decided)")
            move(decided)
          },
          // Sending something takes the reader to it.
          sent: { move(follow.sent()) })
      }
      .scrollDismissesKeyboard(.interactively)
      .softScrollEdges()
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      // The keyboard opening or the composer growing raises the bottom inset (the scroll view
      // itself keeps its size under the bars). A follower keeps the end in view, rather than the
      // last messages going under them.
      .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.bottom } action: { old, new in
        if new > old, !feed.items.isEmpty { move(follow.bottomInsetGrew()) }
      }
      // Where the end is, measured: rows the lazy stack only estimated change the content's height
      // after a move, and a move to the end marker lands a bar's height past it. Left there, the
      // screen shows nothing but the space past the last row, as a busy chat's often did.
      .onScrollGeometryChange(for: Scrolled.Ends.self) { geometry in
        Scrolled.Ends(
          offset: geometry.contentOffset.y,
          topInset: geometry.contentInsets.top,
          end: max(
            -geometry.contentInsets.top,
            geometry.contentSize.height - geometry.containerSize.height - geometry.contentInsets.top))
      } action: { _, ends in
        scrolled.ends = ends
        keepWithinEnd()
      }
      .onChange(of: scrollToLatestRequest) { move(follow.jumpRequested()) }
      // Pull-to-refresh, by hand: `.refreshable` would show the system's spinner, and here Axo
      // plays it. How far the content is past its top, and when the finger lifts.
      .scrollBounceBehavior(.always, axes: .vertical)
      .onScrollGeometryChange(for: Overscroll.self) { geometry in
        Overscroll(
          points: max(0, -(geometry.contentOffset.y + geometry.contentInsets.top)),
          height: geometry.containerSize.height)
      } action: { _, overscroll in
        // A new chat's Axo takes a long pull, to near the bottom; a chat's, a short one.
        pull.state.armTravel = feed.items.isEmpty ? PullToRefresh.longPull : PullToRefresh.shortPull
        pull.state.pulled(to: overscroll.points, height: overscroll.height, touching: pull.touching)
      }
      .onScrollPhaseChange { old, new, context in
        pull.touching = new == .interacting
        scrolled.phase = new
        if old == .interacting, new != .interacting { pull.release(refresh: refresh) }
        // Whether to follow is the reader's to decide, by where they leave the conversation.
        let geometry = context.geometry
        let atEnd = geometry.visibleRect.maxY >= geometry.contentSize.height - 60
        let decided = follow.scrollingChanged(to: Self.scrolling(new), atEnd: atEnd)
        trace("phase \(old)->\(new) atEnd=\(atEnd) following=\(follow.isFollowing) \(decided)")
        move(decided)
        keepWithinEnd()
      }
      .overlay(alignment: .top) {
        if !feed.items.isEmpty { SpinningPullMascotView(pull: pull) }
      }
    }
  }

  /// Reloads the conversation; a new chat has nothing to reload, but Axo still goes round.
  private func refresh() {
    Task {
      let started = ContinuousClock.now
      if let session { await workbench?.loadHistory(of: session.sessionId) }
      // Long enough for Axo to be slung off and come back.
      let least: Duration = .milliseconds(800)
      let took = ContinuousClock.now - started
      if took < least { try? await Task.sleep(for: least - took) }
      pull.state.finished()
    }
  }

  /// The end of the conversation as last measured, and the scroll phase; read by the moves, never
  /// drawn, so a reference the view holds without observing.
  private final class Scrolled {
    struct Ends: Equatable {
      /// The content's offset, and where it is when the last row is just above the composer.
      var offset: Double
      var topInset: Double
      var end: Double
    }
    var ends: Ends?
    var phase: ScrollPhase = .idle
    /// The end last corrected to and how many times, so one that does not land is not tried forever.
    var corrected: (end: Double, tries: Int)?
    /// Moves the scroll position; set by `ScrollingToEnd`, which holds it.
    var scroll: (_ to: (inout ScrollPosition) -> Void) -> Void = { _ in }
  }

  /// Holds the conversation's scroll position, so moving it, as following a streaming reply does
  /// on every update, redraws this alone: the transcript is built a level down, by `Built`, which
  /// is the same view as before and is not made again. And what the transcript reads (the reply
  /// growing) redraws `Built`, not the conversation around it, as `ScrollViewReader` did.
  private struct ScrollingToEnd<Content: View>: View {
    let scrolled: Scrolled
    let anchor: UnitPoint
    let content: () -> Content
    /// The row at the bottom of the screen, which holds the reader's place when older pages arrive
    /// above; or an offset at the end while following.
    @State private var position = ScrollPosition(idType: String.self)

    init(scrolled: Scrolled, anchor: UnitPoint, @ViewBuilder content: @escaping () -> Content) {
      self.scrolled = scrolled
      self.anchor = anchor
      self.content = content
    }

    var body: some View {
      let position = $position
      Built(content: content)
        .scrollPosition(position, anchor: anchor)
        .onAppear { scrolled.scroll = { to in to(&position.wrappedValue) } }
    }
  }

  private struct Built<Content: View>: View {
    let content: () -> Content
    var body: some View { content() }
  }

  /// How far the content is past its top, and how tall the scroll view is.
  private struct Overscroll: Equatable {
    var points: Double
    var height: Double
  }

  private static func scrolling(_ phase: ScrollPhase) -> ScrollFollow.Scrolling {
    switch phase {
    case .idle: .idle
    case .tracking: .touched
    case .interacting, .decelerating: .byReader
    case .animating: .byScreen
    @unknown default: .byReader
    }
  }

  /// The marker after the last row: the scroll position while following.
  private static let end = "latest"
  /// Bottom and leading: `.bottom` is also the horizontal middle, which lines a row narrower than
  /// the column up with the middle of the screen and slides the whole column sideways.
  private static let endAnchor = UnitPoint.bottomLeading

  private func move(_ move: ScrollFollow.Move) {
    switch move {
    case .stay:
      break
    case .keepAtEnd:
      // Without animating: as content grows, the end simply stays in view. Once more on the next
      // turn, after the lazy stack has measured rows it had only estimated (and `keepWithinEnd`
      // whenever the measured end moves after that).
      toEnd()
      Task { @MainActor in
        await Task.yield()
        if follow.isFollowing { toEnd() }
      }
    case .goToEnd:
      toEnd(animated: true)
    }
  }

  /// To the measured end, the last row just above the composer: an offset rather than the end
  /// marker, which SwiftUI lines up a bar's height too far.
  private func toEnd(animated: Bool = false) {
    let to: (inout ScrollPosition) -> Void
    if let ends = scrolled.ends {
      // A point in the content, from its top: the offset less the top inset. On a whole pixel, so
      // it rests in the same place every time.
      let end = (ends.end * displayScale).rounded() / displayScale + ends.topInset
      to = { $0.scrollTo(y: end) }
    } else {
      to = { $0.scrollTo(id: Self.end, anchor: Self.endAnchor) }
    }
    if animated {
      withAnimation(.snappy(duration: 0.3)) { scrolled.scroll(to) }
    } else {
      var instant = Transaction()
      instant.disablesAnimations = true
      withTransaction(instant) { scrolled.scroll(to) }
    }
  }

  /// At rest, a follower stays at the end, and nobody is left past it: nothing a finger or the
  /// screen is moving, which would fight them.
  private func keepWithinEnd() {
    guard scrolled.phase == .idle, let ends = scrolled.ends else { return }
    // At the end means on it, to the pixel: resting between pixels, the rows are drawn a
    // fraction of a point off, differently each time.
    let end = (ends.end * displayScale).rounded() / displayScale
    let past = ends.offset > end + 0.01
    let short = follow.isFollowing && ends.offset < end - 0.01
    guard past || short else { return }
    // A few tries for one end (SwiftUI may move it again as it settles), but never forever.
    if scrolled.corrected?.end != ends.end { scrolled.corrected = (ends.end, 0) }
    guard let tries = scrolled.corrected?.tries, tries < 3 else { return }
    scrolled.corrected = (ends.end, tries + 1)
    trace("ends \(Int(ends.offset)) -> \(Int(ends.end))")
    toEnd()
  }

  private func loadOlder() {
    guard let id = session?.sessionId else { return }
    Task { await workbench?.loadOlderHistory(of: id) }
  }

  /// The menu button, and the Mac's state when it is not simply online. No title: inside the
  /// chat, its name only takes room (VoiceOver still hears it, as the screen's heading).
  private var header: some View {
    ZStack {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement()
        .accessibilityLabel(session?.displayName ?? "New chat")
        .accessibilityAddTraits([.isHeader, .isStaticText])
        .accessibilityIdentifier("conversation-title")
      if let workbench, let trouble = hostTrouble(workbench) {
        Text(trouble)
          .font(.caption.weight(.medium))
          .foregroundStyle(.orange)
          .padding(.horizontal, 12).padding(.vertical, 6)
          .background(.ultraThinMaterial, in: Capsule())
          .accessibilityIdentifier("host-trouble")
      }
      HStack {
        Button(action: showSidebar) {
          VStack(spacing: 4) {
            Capsule().frame(width: 16, height: 2)
            Capsule().frame(width: 16, height: 2)
          }
          .frame(width: 44, height: 44)
          .background(.ultraThinMaterial, in: Circle())
          .overlay(Circle().stroke(ChatColors.border, lineWidth: 0.5))
        }
        .accessibilityLabel("Chats menu")
        Spacer(minLength: 0)
      }
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .padding(.horizontal, 14).padding(.bottom, 10)
  }

  /// What is wrong with the chat's Mac, if anything: offline, or reconnecting.
  private func hostTrouble(_ workbench: HostWorkbenchModel) -> String? {
    if workbench.status != .online { return "\(workbench.hostLabel) is offline" }
    if workbench.link == .reconnecting { return "Reconnecting to \(workbench.hostLabel)…" }
    if chat?.restart != nil { return "Restarting Pi…" }
    return nil
  }

  /// A chat can be written to when its Mac is online and nothing is on its way.
  private var canSend: Bool {
    workbench?.status == .online && session?.hasAgent != false
  }

  private var composerPlaceholder: String {
    guard let workbench else { return "Your Mac is offline" }
    return workbench.status == .online ? "Message Axo" : "\(workbench.hostLabel) is offline"
  }

  private func sendDraft(_ delivery: PromptDelivery) {
    Task { _ = await phone.send(delivery: delivery) }
  }

  private var bottomBar: some View {
    VStack(spacing: 10) {
      if let failure = workbench?.failure {
        Text(failure).font(.caption).foregroundStyle(.orange).padding(.horizontal, 24)
          .accessibilityIdentifier("chat-failure")
      }
      if !follow.isFollowing {
        Button { scrollToLatestRequest += 1 } label: {
          HStack(spacing: 6) {
            Image(systemName: "arrow.down")
              .font(.system(size: 20, weight: .semibold))
              .frame(width: 44, height: 44)
            if follow.hasNew {
              Text("Jump to new message").font(.callout.weight(.semibold)).padding(.trailing, 14)
            }
          }
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .accessibilityLabel(follow.hasNew ? "Jump to new message" : "Jump to latest")
      }
      HostPicker(phone: phone)
      DraftComposer(
        phone: phone, placeholder: composerPlaceholder, canSend: canSend, voice: voice, showApps: showApps,
        workbench: workbench, session: session?.sessionId, send: sendDraft)
    }
    // With the keyboard down the composer sits down in the home indicator's area, as the
    // system's own bars do, rather than above all of it; with the keyboard up, just above it.
    .padding(.bottom, keyboardIsUp ? 6 : max(6, bottomInset - 22))
    .ignoresSafeArea(.container, edges: .bottom)
  }
}

private extension View {
  /// The transcript fades under the header and composer instead of stopping at a divider line.
  @ViewBuilder
  func softScrollEdges() -> some View {
    if #available(iOS 26, *) {
      scrollEdgeEffectStyle(.soft, for: .all)
    } else {
      self
    }
  }

  /// A bar pinned to the top or bottom of the conversation. On iOS 26 the system bar reserves the
  /// space and fades the transcript under it with the scroll edge effect, so there is no opaque
  /// band hiding messages; earlier systems keep an inset with the screen's background.
  @ViewBuilder
  func conversationBar<Bar: View>(edge: VerticalEdge, @ViewBuilder _ bar: () -> Bar) -> some View {
    if #available(iOS 26, *) {
      safeAreaBar(edge: edge, spacing: 0, content: bar)
    } else {
      safeAreaInset(edge: edge, spacing: 0) { bar().background(ChatColors.background) }
    }
  }
}
