import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// One chat: the replies and what was asked, newest at the bottom. With no `session` it is a new
/// chat that does not exist yet; it comes to exist when its first message is sent.
struct ConversationView: View {
  let workbench: HostWorkbenchModel?
  let session: RemoteSession?
  /// What is typed in this chat's box; kept by the workbench, so it survives switching chats.
  @Binding var draft: String
  /// A message is on its way.
  let isSending: Bool
  let showSidebar: () -> Void
  let send: () async -> PhoneWorkbench.SendOutcome
  let sendIn: (UUID) async -> PhoneWorkbench.SendOutcome
  /// The Workspaces to choose from for a new chat; its first message waits in the box.
  @State private var workspaceChoices: [RemoteWorkspace]?
  /// When to follow what is new and when to leave the reader be.
  @State private var follow = ScrollFollow()
  /// The message at the top of the screen; holding it keeps the view still when older pages arrive above.
  @State private var scrollAnchor: String?
  @State private var scrollToLatestRequest = 0

  private var transcript: ChatTranscript { session.flatMap { workbench?.chats[$0.sessionId] } ?? ChatTranscript() }
  private var pending: [HostWorkbenchModel.PendingPrompt] {
    session.flatMap { workbench?.pendingPrompts[$0.sessionId] } ?? []
  }
  private var historyState: HostWorkbenchModel.HistoryState? { session.flatMap { workbench?.historyStates[$0.sessionId] } }

  var body: some View {
    conversation
      .background(ChatColors.background)
      .safeAreaInset(edge: .top, spacing: 0) { header }
      .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
      .confirmationDialog(
        "Start the chat in",
        isPresented: Binding(get: { workspaceChoices != nil }, set: { if !$0 { workspaceChoices = nil } }),
        titleVisibility: .visible
      ) {
        ForEach(workspaceChoices ?? [], id: \.workspaceId) { workspace in
          Button(workspace.name) {
            Task { _ = await sendIn(workspace.workspaceId) }
          }
        }
      }
  }

  private var conversation: some View {
    ScrollViewReader { proxy in
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
                draft = prompt.text
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
              stopping: workbench?.stopping.contains(id) == true,
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
      .refreshable { if let session { await workbench?.loadHistory(of: session.sessionId) } }
    }
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
        ChatEmptyState(message: canSend ? "Send a message to start a chat." : "Your Mac is offline.")
      } else {
        LoadingMascotView(label: "Loading the conversation")
          .frame(height: 120).frame(maxWidth: .infinity).padding(.vertical, 70)
      }
    case .failed(let message):
      ChatEmptyState(message: message)
    case .loaded(let events, _), .loadingOlder(let events):
      ChatEmptyState(
        message: events == 0
          ? "Nothing here yet."
          : "\(events) stored events, none of them messages yet.")
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
    .background(ChatColors.background)
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
      if case .chooseWorkspace(let choices) = await send() { workspaceChoices = choices }
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
      ChatComposer(
        draft: $draft, placeholder: composerPlaceholder,
        canSend: canSend && !isSending, send: sendDraft)
    }
    .padding(.bottom, 8)
    .background(ChatColors.background)
  }
}
