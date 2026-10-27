import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// One chat: the replies and what was asked, newest at the bottom. With no `session` it is a new
/// chat that does not exist yet; it comes to exist when its first message is sent.
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
  /// The Workspaces to choose from for a new chat; its first message waits in the box.
  @State private var workspaceChoices: [RemoteWorkspace]?
  /// When to follow what is new and when to leave the reader be.
  @State private var follow = ScrollFollow()
  /// The message at the top of the screen; holding it keeps the view still when older pages arrive above.
  @State private var scrollAnchor: String?
  @State private var scrollToLatestRequest = 0
  /// Pull-to-refresh, played by Axo: the empty chat's Axo, or a small one at the top.
  @State private var pull = ConversationPull()
  /// The screen's bottom inset: the home indicator's (at most a few dozen points), or the
  /// keyboard's while it is up (always far taller).
  @State private var bottomInset: CGFloat = 0
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
      .confirmationDialog(
        "Start the chat in",
        isPresented: Binding(get: { workspaceChoices != nil }, set: { if !$0 { workspaceChoices = nil } }),
        titleVisibility: .visible
      ) {
        ForEach(workspaceChoices ?? [], id: \.workspaceId) { workspace in
          Button(workspace.name) {
            Task { _ = await phone.send(in: workspace.workspaceId) }
          }
        }
      }
  }

  private var conversation: some View {
    ScrollViewReader { proxy in
      let _ = RenderCount.note("Transcript")
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 30) {
          olderHistory
          if transcript.messages.isEmpty { emptyState }
          ForEach(transcript.messages) { message in
            ChatMessageView(message: message, piIsWorking: transcript.activity == .working)
          }
          // The reply as far as it has got.
          ForEach(transcript.live) { message in
            ChatMessageView(message: message, piIsWorking: true, isLive: true)
          }
          ForEach(pending) { prompt in
            PendingPromptView(
              prompt: prompt,
              editAgain: {
                if let selection = phone.selection { phone.setDraft(prompt.text, for: selection) }
                if let id = session?.sessionId { workbench?.dismissPending(prompt.id, in: id) }
              },
              dismiss: { if let id = session?.sessionId { workbench?.dismissPending(prompt.id, in: id) } })
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
          Color.clear.frame(height: 1).id("latest")
        }
        .scrollTargetLayout()
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollDismissesKeyboard(.interactively)
      .softScrollEdges()
      .scrollPosition(id: $scrollAnchor, anchor: .top)
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .onScrollGeometryChange(for: Bool.self) { geometry in
        // What is on screen reaches (nearly) the end of the content.
        geometry.visibleRect.maxY >= geometry.contentSize.height - 60
      } action: { _, nearBottom in
        follow.readerScrolled(atEnd: nearBottom)
      }
      .onChange(of: endOfConversation) { _, end in
        guard end != EndOfConversation() else { return }
        move(follow.contentChangedAtEnd(), proxy: proxy)
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
      .onScrollPhaseChange { old, new in
        pull.touching = new == .interacting
        if old == .interacting, new != .interacting { pull.release(refresh: refresh) }
      }
      .overlay(alignment: .top) {
        if !transcript.messages.isEmpty { SpinningPullMascotView(pull: pull) }
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

  private func move(_ move: ScrollFollow.Move, proxy: ScrollViewProxy) {
    switch move {
    case .stay:
      break
    case .jumpToEnd:
      // The first page: go to its end without animating, then again once the lazy stack has
      // measured what it estimated, or the end can land short of the real bottom.
      proxy.scrollTo("latest", anchor: .bottom)
      Task { @MainActor in
        await Task.yield()
        proxy.scrollTo("latest", anchor: .bottom)
        // Once more after the rows above have been measured for real.
        try? await Task.sleep(for: .milliseconds(150))
        proxy.scrollTo("latest", anchor: .bottom)
      }
    case .followToEnd:
      withAnimation { proxy.scrollTo("latest", anchor: .bottom) }
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

  private var header: some View {
    ZStack {
      VStack(spacing: 2) {
        Text(session?.displayName ?? "New chat").font(.headline).lineLimit(1)
          .accessibilityIdentifier("conversation-title")
        if let workbench {
          Text(hostLine(workbench))
            .font(.caption)
            .foregroundStyle(workbench.status == .online && workbench.link != .reconnecting ? Color.secondary : Color.orange)
        }
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

  private func hostLine(_ workbench: HostWorkbenchModel) -> String {
    if workbench.status != .online { return "\(workbench.hostLabel) · offline" }
    if workbench.link == .reconnecting { return "\(workbench.hostLabel) · reconnecting…" }
    return workbench.hostLabel
  }

  /// A chat can be written to when its Mac is online and nothing is on its way.
  private var canSend: Bool {
    workbench?.status == .online && session?.hasAgent != false
  }

  private var composerPlaceholder: String {
    guard let workbench else { return "Your Mac is offline" }
    return workbench.status == .online ? "Message Axo" : "\(workbench.hostLabel) is offline"
  }

  private func sendDraft() {
    Task {
      if case .chooseWorkspace(let choices) = await phone.send() { workspaceChoices = choices }
    }
  }

  private var bottomBar: some View {
    VStack(spacing: 10) {
      if let failure = workbench?.failure {
        Text(failure).font(.caption).foregroundStyle(.orange).padding(.horizontal, 24)
          .accessibilityIdentifier("chat-failure")
      }
      if !follow.isAtEnd {
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
      DraftComposer(phone: phone, placeholder: composerPlaceholder, canSend: canSend, voice: voice, send: sendDraft)
    }
    // With the keyboard down the composer sits in the home indicator's area as system bars do,
    // instead of above all of it plus a margin; with the keyboard up, just above it.
    .padding(.bottom, keyboardIsUp ? 8 : max(8, bottomInset - 10))
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
