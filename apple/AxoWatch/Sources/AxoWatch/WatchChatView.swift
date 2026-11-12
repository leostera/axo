import AxoPhoneModel
import AxoProtocol
import AxoWatchModel
import SwiftUI
import WatchKit

struct WatchChatView: View {
  let model: WatchChatModel
  @State private var choosingSession = false
  @State private var lastConnectedAt: Date?
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    ScrollViewReader { scroll in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if let session = model.selectedSession {
            Text(session.displayName).font(.headline)
            Text(model.selectedHost?.label ?? "Mac").font(.caption2).foregroundStyle(.secondary)
            if model.workbench.link != .connected {
              Label("Reconnecting…", systemImage: "wifi.slash").font(.caption)
            } else if model.selectedHost?.status != .online {
              Text("Mac offline · read-only").font(.caption).foregroundStyle(.secondary)
            }
            if let chat = model.chat {
              if case .loading = chat.history { ProgressView("Loading…") }
              if case .failed(let message) = chat.history { Text(message).font(.caption).foregroundStyle(.orange) }
              ForEach(chat.feed.items) { item in WatchChatRow(item: item) }
              if chat.feed.working { ProgressView("Working…").font(.caption) }
              if chat.feed.question != nil {
                Label("Your answer is needed. Open Axo on your iPhone.", systemImage: "questionmark.bubble")
                  .font(.caption).foregroundStyle(.orange)
              }
            }
          } else {
            Text("One session on your wrist").font(.headline)
            Text("Choose an existing agent session. Axo remembers it on this Watch.")
              .font(.caption).foregroundStyle(.secondary)
            if case .failed(let message) = model.workbench.hosts.phase { Text(message).font(.caption).foregroundStyle(.orange) }
            Button("Choose session") { choosingSession = true }
          }
          if let failure = model.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
          Color.clear.frame(height: 1).id("latest")
        }
        .padding(.horizontal, 6)
      }
      .defaultScrollAnchor(.bottom)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Session", systemImage: "list.bullet") { choosingSession = true }
            .disabled(model.workbench.isSending)
        }
      }
      .safeAreaInset(edge: .bottom) {
        if let target = model.target, model.selectedSession != nil {
          HStack {
            TextFieldLink(prompt: Text("Message for this session")) {
              Label("Dictate", systemImage: "mic.fill")
            } onSubmit: { [target] text in
              if model.acceptTranscript(text, for: target) { WKInterfaceDevice.current().play(.click) }
            }
            .buttonStyle(.borderedProminent).tint(.mint)
            .disabled(model.workbench.isSending || model.account.state != .signedIn)
            Button("Latest", systemImage: "arrow.down") { scroll.scrollTo("latest", anchor: .bottom) }
              .labelStyle(.iconOnly)
          }
          .padding(.horizontal, 4)
        }
      }
    }
    .sheet(isPresented: $choosingSession) { WatchSessionPicker(model: model) }
    .sheet(isPresented: Binding(get: { model.draft != nil }, set: { if !$0 { model.discardDraft() } })) {
      WatchDraftReview(model: model)
    }
    .task(id: scenePhase) {
      if scenePhase == .active { await model.start() }
      else { model.suspend() }
    }
    .onAppear { reportConnection() }
    .onChange(of: model.workbench.link) { reportConnection() }
    .onChange(of: model.workbench.hosts.hosts) { model.reconcile() }
    .onChange(of: model.account.state) { _, state in
      if state == .signedOut { model.stop() }
    }
  }

  private func reportConnection() {
    if model.workbench.link == .connected { lastConnectedAt = Date() }
    WatchConnectionReport.write(link: model.workbench.link, lastConnectedAt: lastConnectedAt)
  }
}

private struct WatchSessionPicker: View {
  let model: WatchChatModel
  @Environment(\.dismiss) private var dismiss
  @State private var preferences: ChatListPreferences
  @State private var held: [ChatGroupSection]?

  init(model: WatchChatModel) {
    self.model = model
    let defaults = UserDefaults(suiteName: "axo.watch.sidebar.\(model.accountID.uuidString.lowercased())") ?? .standard
    _preferences = State(initialValue: ChatListPreferences(defaults: defaults))
  }

  private var groups: [ChatGroupSection] {
    let live = WatchSessionGroups.sections(
      hosts: model.workbench.hosts.hosts, sessionsOf: model.workbench.sessions(of:),
      seen: preferences.seen, settings: preferences.settings)
    // As on the phone, keep rows under the reader's finger while this picker is open.
    return ChatGrouping.holding(held, live: live)
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(groups) { section in
          Section(section.group.title) {
            ForEach(section.chats, id: \.key) { entry in
              Button {
                if model.select(host: entry.host, session: entry.session) {
                  preferences.markSeen(entry.session)
                  dismiss()
                }
              } label: {
                VStack(alignment: .leading, spacing: 3) {
                  Text(entry.session.displayName).lineLimit(2)
                  Text(entry.host.label + (entry.host.status == .online ? "" : " · Offline"))
                    .font(.caption2).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
        if groups.isEmpty {
          switch model.workbench.hosts.phase {
          case .idle, .loading: ProgressView("Loading sessions…")
          case .failed(let message): Text(message).font(.caption).foregroundStyle(.orange)
          case .loaded: Text("No agent sessions yet. Start one on your Mac.").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Choose session")
      .onAppear { held = groups }
      .onChange(of: model.workbench.hosts.hosts) { held = groups }
    }
  }
}

private struct WatchDraftReview: View {
  let model: WatchChatModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Review message").font(.headline)
        Text(model.selectedSession?.displayName ?? "Session unavailable").font(.caption).foregroundStyle(.secondary)
        Text(model.draft?.text ?? "").font(.body)
        if let failure = model.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        Button("Send", systemImage: "paperplane.fill") { Task { await model.send() } }
          .disabled(!model.canSend).tint(.mint)
        if model.workbench.isSending { ProgressView("Sending…") }
        else if !model.canSend { Text("Waiting for the session connection.").font(.caption).foregroundStyle(.secondary) }
        Button("Discard", role: .cancel) { model.discardDraft() }.disabled(model.workbench.isSending)
      }
      .padding(.horizontal)
    }
    .interactiveDismissDisabled(model.workbench.isSending)
  }
}

private struct WatchChatRow: View {
  let item: ConversationFeed.Item

  var body: some View {
    switch item.row {
    case .message(let shown) where shown.message.role == .user || shown.message.role == .assistant:
      VStack(alignment: .leading, spacing: 4) {
        Text(shown.message.role == .user ? "You" : "Axo").font(.caption2).foregroundStyle(.secondary)
        Text(shown.message.text).font(.body)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    case .pending(let prompt):
      VStack(alignment: .leading, spacing: 4) {
        Text("You · pending").font(.caption2).foregroundStyle(.secondary)
        Text(prompt.text).font(.body)
      }
    case .queued(let prompt):
      VStack(alignment: .leading, spacing: 4) {
        Text("You · queued").font(.caption2).foregroundStyle(.secondary)
        Text(prompt.text).font(.body)
      }
    default: EmptyView() // Tool output and private reasoning do not crowd the wrist conversation.
    }
  }
}
