import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// One Session's conversation: Pi's replies and what was asked, newest at the bottom.
struct ConversationView: View {
  let workbench: HostWorkbenchModel?
  let session: RemoteSession?
  let showSidebar: () -> Void
  @State private var draft = ""
  @State private var showingTerminal = false

  private var transcript: ChatTranscript { session.flatMap { workbench?.chats[$0.sessionId] } ?? ChatTranscript() }
  private var historyState: HostWorkbenchModel.HistoryState? { session.flatMap { workbench?.historyStates[$0.sessionId] } }

  var body: some View {
    conversation
      .background(ChatColors.background)
      .safeAreaInset(edge: .top, spacing: 0) { header }
      .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
      .sheet(isPresented: $showingTerminal) {
        if let workbench { TerminalSheet(model: workbench) }
      }
  }

  private var conversation: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 30) {
          if case .truncated = historyState {
            Text("This conversation is long; the newest part is not shown here yet.")
              .font(.caption).foregroundStyle(.secondary)
          }
          if transcript.messages.isEmpty {
            switch historyState {
            case .loading, nil where session != nil:
              ProgressView("Loading the conversation…").frame(maxWidth: .infinity).padding(.vertical, 90)
            case .failed(let message):
              ChatEmptyState(message: message)
            default:
              ChatEmptyState(message: session == nil ? "Pick a session from the menu." : "Your conversation will appear here.")
            }
          }
          ForEach(transcript.messages) { message in
            ChatMessageView(message: message)
          }
          if transcript.activity == .working { AgentActivityView() }
          Color.clear.frame(height: 1).id("latest")
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollDismissesKeyboard(.interactively)
      .defaultScrollAnchor(.bottom)
      .onChange(of: transcript.messages.last?.id) { withAnimation { proxy.scrollTo("latest", anchor: .bottom) } }
      .refreshable { if let session { await workbench?.loadHistory(of: session.sessionId) } }
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
        if session?.shells.isEmpty == false {
          Button { showingTerminal = true } label: {
            Image(systemName: "terminal")
              .font(.system(size: 17, weight: .medium))
              .frame(width: 44, height: 44)
              .background(.ultraThinMaterial, in: Circle())
              .overlay(Circle().stroke(ChatColors.border, lineWidth: 0.5))
          }
          .accessibilityLabel("Terminal")
        }
      }
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .padding(.horizontal, 14).padding(.bottom, 10)
    .background(ChatColors.background)
  }

  private var bottomBar: some View {
    VStack(spacing: 10) {
      if let failure = workbench?.failure, !PreviewFixture.requested {
        Text(failure).font(.caption).foregroundStyle(.orange).padding(.horizontal, 24)
      }
      ChatComposer(
        draft: $draft, placeholder: "Read-only for now",
        canSend: false, send: {})
    }
    .padding(.bottom, 8)
    .background(ChatColors.background)
  }
}
