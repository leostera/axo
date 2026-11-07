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
  /// The message at the top of the screen; holding it keeps the view still when older pages arrive above.
  @State private var scrollAnchor: String?
  @State private var scrollToLatestRequest = 0
  /// Pull-to-refresh, played by Axo: the empty chat's Axo, or a small one at the top.
  @State private var pull = ConversationPull()
  /// The screen's bottom inset: the home indicator's (at most a few dozen points), or the
  /// keyboard's while it is up (always far taller).
  @State private var bottomInset: CGFloat = 0
  /// How what is written while the chat is on screen comes in. Held, never observed: rows ask it.
  @State private var reveal = ConversationReveal()
  /// Bumped when a reply's words are all out, so what waited behind it shows.
  @State private var revealsFinished = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var keyboardIsUp: Bool { bottomInset > 100 }

  /// This chat's own state: what it reads is what redraws it, so other chats' events do not.
  private var chat: Chat? { session.flatMap { workbench?.chat($0.sessionId) } }
  private var transcript: ChatTranscript { chat?.transcript ?? ChatTranscript() }
  private var pending: [HostWorkbenchModel.PendingPrompt] { chat?.pending ?? [] }
  private var historyState: HostWorkbenchModel.HistoryState? { chat?.history }

  var body: some View {
    let _ = RenderCount.note("Conversation")
    conversation
      .background(ChatColors.background)
      .conversationBar(edge: .top) { header }
      .conversationBar(edge: .bottom) { bottomBar }
      .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
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
    ScrollViewReader { proxy in
      let _ = RenderCount.note("Transcript")
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 30) {
          olderHistory
          if transcript.messages.isEmpty { emptyState }
          // The records, the person's messages on their way and the reply as far as it has got,
          // each in the place it keeps (see `ConversationRow`).
          ForEach(ConversationRow.rows(shown: shownMessages, pending: pending, queued: transcript.queued)) { row in
            switch row {
            case .message(let shown):
              ChatMessageView(
                message: shown.message, piIsWorking: shown.isLive || transcript.activity == .working, isLive: shown.isLive,
                entrance: entrance(of: shown))
            case .pending(let prompt):
              PendingPromptView(
                prompt: prompt,
                editAgain: {
                  if let selection = phone.selection { phone.setDraft(prompt.text, for: selection) }
                  if let id = session?.sessionId { workbench?.dismissPending(prompt.id, in: id) }
                },
                dismiss: { if let id = session?.sessionId { workbench?.dismissPending(prompt.id, in: id) } })
            case .queued(let prompt):
              QueuedPromptView(prompt: prompt)
            }
          }
          if let id = session?.sessionId {
            ForEach(phone.questions(in: id)) { question in
              if question.elicitation.input != nil {
                InputCard(question: question, canAnswer: workbench?.status == .online, failure: phone.answerFailure) { action, values in
                  Task { await phone.answer(question.id, action, values: values) }
                }
              } else {
                ElicitationCard(question: question, canAnswer: workbench?.status == .online, failure: phone.answerFailure) { action in
                  Task { await phone.answer(question.id, action) }
                }
              }
            }
          }
          if let question = transcript.question, let id = session?.sessionId {
            QuestionCard(question: question, canAnswer: canSend) { answer in
              Task { await workbench?.answer(answer, in: id) }
            }
          }
          if transcript.activity == .working, let id = session?.sessionId {
            AgentActivityView(
              callingTools: transcript.messages.contains { $0.tool?.status == .running },
              waiting: transcript.question != nil,
              stopping: chat?.isStopping == true,
              canStop: workbench?.status == .online,
              stop: { Task { await workbench?.stopReply(in: id) } })
          }
          Color.clear.frame(height: 1).id(Self.end)
        }
        .scrollTargetLayout()
        .padding(.top, 24)
        .padding(.bottom, 20)
        // Exactly as wide as the screen: a row that asked for more would otherwise widen the
        // column, and scrolling to the end would slide it sideways.
        .containerRelativeFrame(.horizontal, alignment: .leading)
      }
      // The column's margins are the scroll view's, not padding inside it: the scroll position
      // lines a row's edge up with the content's edge, and with padding inside, every row slid
      // 20 points under the left edge of the screen.
      .contentMargins(.horizontal, 20, for: .scrollContent)
      .scrollDismissesKeyboard(.interactively)
      .softScrollEdges()
      // The row at the bottom of the screen stays put when content changes elsewhere (an older
      // page arriving above keeps the reader's place); the end itself is kept by `follow`.
      .scrollPosition(id: $scrollAnchor, anchor: Self.endAnchor)
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      // The keyboard opening or the composer growing raises the bottom inset (the scroll view
      // itself keeps its size under the bars). A follower keeps the end in view, rather than the
      // last messages going under them.
      .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.bottom } action: { old, new in
        if new > old, !transcript.messages.isEmpty { move(follow.bottomInsetGrew(), proxy: proxy) }
      }
      .onChange(of: endOfConversation) { _, end in
        guard end != EndOfConversation() else { return }
        let decided = follow.contentChangedAtEnd()
        trace("content \(decided)")
        move(decided, proxy: proxy)
      }
      .onChange(of: pending.count) { previous, count in
        // Sending something takes the reader to it.
        if count > previous { move(follow.sent(), proxy: proxy) }
      }
      .onChange(of: scrollToLatestRequest) { move(follow.jumpRequested(), proxy: proxy) }
      // Pull-to-refresh, by hand: `.refreshable` would show the system's spinner, and here Axo
      // plays it. How far the content is past its top, and when the finger lifts.
      .scrollBounceBehavior(.always, axes: .vertical)
      .onScrollGeometryChange(for: Overscroll.self) { geometry in
        Overscroll(
          points: max(0, -(geometry.contentOffset.y + geometry.contentInsets.top)),
          height: geometry.containerSize.height)
      } action: { _, overscroll in
        // A new chat's Axo takes a long pull, to near the bottom; a chat's, a short one.
        pull.state.armTravel = transcript.messages.isEmpty ? PullToRefresh.longPull : PullToRefresh.shortPull
        pull.state.pulled(to: overscroll.points, height: overscroll.height, touching: pull.touching)
      }
      .onScrollPhaseChange { old, new, context in
        pull.touching = new == .interacting
        if old == .interacting, new != .interacting { pull.release(refresh: refresh) }
        // Whether to follow is the reader's to decide, by where they leave the conversation.
        let geometry = context.geometry
        let atEnd = geometry.visibleRect.maxY >= geometry.contentSize.height - 60
        let decided = follow.scrollingChanged(to: Self.scrolling(new), atEnd: atEnd)
        trace("phase \(old)->\(new) atEnd=\(atEnd) following=\(follow.isFollowing) \(decided)")
        move(decided, proxy: proxy)
      }
      .overlay(alignment: .top) {
        if !transcript.messages.isEmpty { SpinningPullMascotView(pull: pull) }
      }
    }
  }

  private var shownMessages: [ConversationReveal.Shown] {
    let _ = revealsFinished
    guard !reduceMotion else {
      return transcript.messages.map { .init(message: $0, isLive: false, presentation: .plain) }
        + transcript.live.map { .init(message: $0, isLive: true, presentation: .plain) }
    }
    return reveal.shown(sessionId: session.map { "\($0.sessionId)" }, messages: transcript.messages, live: transcript.live)
  }

  private func entrance(of shown: ConversationReveal.Shown) -> ChatMessageView.Entrance? {
    guard shown.presentation != .plain else { return nil }
    return ChatMessageView.Entrance(reveal: reveal, presentation: shown.presentation) {
      reveal.finished(shown.message.key)
      revealsFinished += 1
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

  /// How far the content is past its top, and how tall the scroll view is.
  private struct Overscroll: Equatable {
    var points: Double
    var height: Double
  }

  /// What is at the end of the conversation; when it changes, there is something new to follow.
  private struct EndOfConversation: Equatable {
    var lastMessage: String?
    var liveLength = 0
    var runningOutputLength = 0
    var asking = false
    var working = false
  }

  private var endOfConversation: EndOfConversation {
    EndOfConversation(
      lastMessage: transcript.messages.last?.id,
      liveLength: transcript.live.reduce(0) { $0 + $1.text.count },
      runningOutputLength: transcript.messages.last(where: { $0.tool?.status == .running })?.tool?.output.count ?? 0,
      asking: transcript.question != nil,
      working: transcript.activity == .working)
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

  private func move(_ move: ScrollFollow.Move, proxy: ScrollViewProxy) {
    switch move {
    case .stay:
      break
    case .keepAtEnd:
      // Without animating: as content grows, the end simply stays in view. The scroll position
      // is the end marker, so SwiftUI keeps *it* at the bottom as rows are added, rather than
      // the message that was at the bottom (which would leave the new ones below the screen).
      // Once more on the next turn, after the lazy stack has measured rows it had only
      // estimated, or the end can land short of the real bottom.
      var instant = Transaction()
      instant.disablesAnimations = true
      withTransaction(instant) {
        scrollAnchor = Self.end
        proxy.scrollTo(Self.end, anchor: Self.endAnchor)
      }
      Task { @MainActor in
        await Task.yield()
        guard follow.isFollowing else { return }
        withTransaction(instant) { proxy.scrollTo(Self.end, anchor: Self.endAnchor) }
      }
    case .goToEnd:
      withAnimation(.snappy(duration: 0.3)) {
        scrollAnchor = Self.end
        proxy.scrollTo(Self.end, anchor: Self.endAnchor)
      }
    }
  }

  /// At the top of the conversation: older messages are read as this scrolls into view.
  @ViewBuilder private var olderHistory: some View {
    switch historyState {
    case .loaded(_, true):
      Button("Load earlier messages") { loadOlder() }
        .font(.caption).frame(maxWidth: .infinity)
        .onAppear(perform: loadOlder)
    case .loadingOlder:
      LoadingMascotView(label: "Loading earlier messages").frame(height: 44).frame(maxWidth: .infinity)
    default:
      EmptyView()
    }
  }

  private func loadOlder() {
    guard let id = session?.sessionId else { return }
    Task { await workbench?.loadOlderHistory(of: id) }
  }

  @ViewBuilder private var emptyState: some View {
    switch historyState {
    case nil, .loading:
      if session == nil {
        ChatEmptyState(message: canSend ? "Send a message to start a chat." : "Your Mac is offline.", pull: pull)
      } else {
        LoadingMascotView(label: "Loading the conversation")
          .frame(height: 120).frame(maxWidth: .infinity).padding(.vertical, 70)
      }
    case .failed(let message):
      ChatEmptyState(message: message, pull: pull)
    case .loaded(let events, _), .loadingOlder(let events):
      ChatEmptyState(
        message: events == 0
          ? "Nothing here yet."
          : "\(events) stored events, none of them messages yet.",
        pull: pull)
    }
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
