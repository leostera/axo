import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// One Session's conversation: Pi's replies and what was asked, newest at the bottom.
struct ConversationView: View {
  let workbench: HostWorkbenchModel?
  let session: RemoteSession?
  let showSidebar: () -> Void
  @State private var draft = ""
  @State private var isNearBottom = true
  /// The message at the top of the screen; holding it keeps the view still when older pages arrive above.
  @State private var scrollAnchor: String?
  @State private var scrollToLatestRequest = 0

  private var transcript: ChatTranscript { session.flatMap { workbench?.chats[$0.sessionId] } ?? ChatTranscript() }
  private var historyState: HostWorkbenchModel.HistoryState? { session.flatMap { workbench?.historyStates[$0.sessionId] } }

  var body: some View {
    conversation
      .background(ChatColors.background)
      .safeAreaInset(edge: .top, spacing: 0) { header }
      .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
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
          if transcript.activity == .working {
            AgentActivityView(callingTools: transcript.messages.contains { $0.tool?.status == .running })
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
        isNearBottom = nearBottom
      }
      .onChange(of: transcript.messages.last?.id) {
        if isNearBottom { withAnimation { proxy.scrollTo("latest", anchor: .bottom) } }
      }
      .onChange(of: scrollToLatestRequest) { withAnimation { proxy.scrollTo("latest", anchor: .bottom) } }
      .refreshable { if let session { await workbench?.loadHistory(of: session.sessionId) } }
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
        ChatEmptyState(message: "Pick a session from the menu.")
      } else {
        LoadingMascotView(label: "Loading the conversation")
          .frame(height: 120).frame(maxWidth: .infinity).padding(.vertical, 70)
      }
    case .failed(let message):
      ChatEmptyState(message: message)
    case .loaded(let events, _), .loadingOlder(let events):
      ChatEmptyState(
        message: events == 0
          ? "Nothing is stored for this session yet. Pi's messages appear here as they happen."
          : "\(events) stored events, none of them messages yet.")
    }
  }

  private var header: some View {
    ZStack {
      VStack(spacing: 2) {
        Text(session?.displayName ?? "Axo").font(.headline).lineLimit(1)
        if let workbench {
          Text(workbench.status == .online ? workbench.hostLabel : "\(workbench.hostLabel) · offline")
            .font(.caption).foregroundStyle(workbench.status == .online ? Color.secondary : Color.orange)
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
        .accessibilityLabel("Sessions menu")
        Spacer(minLength: 0)
      }
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .padding(.horizontal, 14).padding(.bottom, 10)
    .background(ChatColors.background)
  }

  /// Pi can be prompted when its Mac is online and the Session has one.
  private var canPrompt: Bool {
    workbench?.status == .online && session?.hasAgent != false && session != nil
  }

  private var composerPlaceholder: String {
    guard let workbench, session != nil else { return "Pick a chat" }
    if workbench.status != .online { return "\(workbench.hostLabel) is offline" }
    return session?.hasAgent == false ? "This session has no Pi" : "Message Pi"
  }

  private func sendPrompt() {
    guard canPrompt, let workbench else { return }
    let text = draft
    Task {
      // The words stay in the box until the Mac has them, so a refusal loses nothing.
      if await workbench.sendPrompt(text), draft == text { draft = "" }
    }
  }

  private var bottomBar: some View {
    VStack(spacing: 10) {
      if let failure = workbench?.failure, !PreviewFixture.requested {
        Text(failure).font(.caption).foregroundStyle(.orange).padding(.horizontal, 24)
      }
      if !isNearBottom {
        Button { scrollToLatestRequest += 1 } label: {
          Image(systemName: "arrow.down")
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 44, height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .accessibilityLabel("Jump to latest")
      }
      ChatComposer(
        draft: $draft, placeholder: composerPlaceholder,
        canSend: canPrompt, send: sendPrompt)
    }
    .padding(.bottom, 8)
    .background(ChatColors.background)
  }
}
