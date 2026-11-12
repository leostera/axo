import AxoPhoneModel
import AxoProtocol
import AxoVoiceUI
import AxoWatchModel
import SwiftUI
import WatchKit

struct WatchChatView: View {
  let model: WatchChatModel
  let transcribeAudio: @MainActor (URL) async throws -> String
  @Environment(\.scenePhase) private var scenePhase
  @State private var choosingSession = false
  @State private var voice: VoicePrompt?
  @State private var voiceTarget: WatchChatTarget?
  @State private var startedListening: Date?
  @State private var handingOff = false
  @State private var localFailure: String?
  @State private var lastConnectedAt: Date?

  private var capturing: Bool { voice?.isBusy == true }
  private var title: String { model.selectedSession?.displayName ?? model.rememberedSessionName ?? "Axo" }

  var body: some View {
    Group {
      if let voice, capturing {
        capture(voice)
      } else {
        conversation
          .safeAreaInset(edge: .bottom) { composer }
      }
    }
    .navigationTitle(capturing ? "Axo" : title)
    .toolbar {
      if !capturing, !handingOff {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Sessions", systemImage: "list.bullet") { choosingSession = true }
            .disabled(model.workbench.isSending)
        }
      }
    }
    .sheet(isPresented: $choosingSession) { WatchSessionPicker(model: model) }
    .task(id: scenePhase) {
      if scenePhase == .active { await model.start() }
      else { model.suspend() }
    }
    .onChange(of: scenePhase) { _, phase in
      // Permission prompts may make the scene inactive. Only leaving the app discards an
      // unsubmitted recording; an explicit Send may keep finishing in the background.
      if phase == .background, voice?.state != .finishing { cancelVoice() }
    }
    .onChange(of: voice?.state) { _, state in
      if case .listening = state {
        startedListening = Date()
        WKInterfaceDevice.current().play(.start)
      } else if state == .finishing { WKInterfaceDevice.current().play(.stop) }
    }
    .onChange(of: voice?.transcript) { _, transcript in
      if let transcript { deliver(transcript) }
    }
    .onChange(of: model.target) { cancelVoice() }
    .onChange(of: model.selectedSession?.sessionId) { _, selected in
      if selected == nil, capturing { cancelVoice(); localFailure = "This session is unavailable. Nothing was sent." }
    }
    .onChange(of: model.workbench.hosts.hosts) { model.reconcile() }
    .onChange(of: model.account.state) { _, state in
      if state == .signedOut { cancelVoice(); model.stop() }
    }
    .onAppear { reportConnection() }
    .onChange(of: model.workbench.link) { reportConnection() }
  }

  private var conversation: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        if model.selectedSession != nil {
          if model.workbench.link != .connected {
            Label("Reconnecting…", systemImage: "wifi.slash").font(.caption2).foregroundStyle(.secondary)
          } else if model.selectedHost?.status != .online {
            Text("Mac offline · read-only").font(.caption2).foregroundStyle(.secondary)
          }
          if let chat = model.chat {
            if chat.transcript == nil {
              if case .loading = chat.history { ProgressView() }
              if case .failed(let message) = chat.history { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            ForEach(chat.feed.items) { item in WatchChatRow(item: item) }
            if chat.feed.working { ProgressView().accessibilityLabel("Agent working") }
            if chat.feed.question != nil {
              Label("Your answer is needed on iPhone.", systemImage: "questionmark.bubble")
                .font(.caption).foregroundStyle(.orange)
            }
          }
        } else if model.target != nil {
          // Cold launch restores the remembered identity immediately, without flashing the picker.
          Text(title).font(.headline)
          if model.workbench.hosts.phase == .loaded {
            Text("This session is unavailable.").font(.caption).foregroundStyle(.secondary)
            Button("Choose another session") { choosingSession = true }
          } else { ProgressView("Reconnecting…") }
        } else {
          Text("One session on your wrist").font(.headline)
          Text("Choose a session once. Axo brings you back here.").font(.caption).foregroundStyle(.secondary)
          Button("Choose session") { choosingSession = true }
        }
        if let failure = localFailure ?? model.failure {
          Text(failure).font(.caption).foregroundStyle(.orange)
        }
        if case .failed(let message) = voice?.state {
          Text(message).font(.caption).foregroundStyle(.orange)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4).padding(.vertical, 6)
    }
    .defaultScrollAnchor(.bottom)
  }

  @ViewBuilder private var composer: some View {
    if model.selectedSession != nil {
      HStack {
        Spacer(minLength: 0)
        if handingOff || model.workbench.isSending {
          ProgressView().frame(width: 44, height: 44).accessibilityLabel("Sending message")
        } else if model.draft != nil {
          VoiceCircle(symbol: "xmark", label: "Discard unsent message") { model.discardDraft() }
          VoiceCircle(symbol: "arrow.up", label: "Retry sending", prominent: true) { Task { await model.send() } }
            .disabled(!model.canSend)
        } else {
          VoiceCircle(symbol: "mic", label: "Talk") { startVoice() }
            .disabled(model.account.state != .signedIn)
        }
        Spacer(minLength: 0)
      }
      .padding(.bottom, 2)
    }
  }

  private func capture(_ voice: VoicePrompt) -> some View {
    VStack(spacing: 12) {
      Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
      Spacer(minLength: 0)
      if voice.isListening {
        AudioWaveform(bars: 24, height: 36) { voice.audioLevel }
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let seconds = max(0, Int(context.date.timeIntervalSince(startedListening ?? context.date)))
          Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            .accessibilityLabel("Recording duration")
        }
      } else {
        ProgressView()
        Text(voice.state == .finishing ? "Transcribing on iPhone…" : "Getting microphone ready…")
          .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
      Spacer(minLength: 0)
      HStack {
        VoiceCircle(symbol: "xmark", label: "Cancel recording") { cancelVoice() }
        Spacer()
        if voice.isListening {
          VoiceCircle(symbol: "arrow.up", label: "Stop and send", prominent: true) { voice.finish(.send) }
        }
      }
    }
    .padding(.horizontal, 4)
  }

  private func startVoice() {
    guard !capturing, !handingOff, !model.workbench.isSending, let target = model.target,
      model.selectedSession != nil else { return }
    localFailure = nil
    let capture = VoicePrompt(engine: WatchRecordingDictation(transcribe: transcribeAudio))
    voiceTarget = target
    voice = capture
    capture.start()
  }

  private func cancelVoice() {
    if let transcript = voice?.transcript { voice?.consume(transcript) }
    voice?.cancel()
    voice = nil
    voiceTarget = nil
  }

  private func deliver(_ transcript: VoiceTranscript) {
    guard let voice, transcript.delivery == .send, let target = voiceTarget, !handingOff else { return }
    voice.consume(transcript)
    handingOff = true
    Task {
      defer { handingOff = false }
      guard model.acceptTranscript(transcript.text, for: target) else {
        localFailure = "The session changed. Nothing was sent."
        return
      }
      await model.send()
      if model.draft == nil, model.failure == nil { WKInterfaceDevice.current().play(.success) }
    }
  }

  private func reportConnection() {
    if model.workbench.link == .connected { lastConnectedAt = Date() }
    WatchConnectionReport.write(link: model.workbench.link, lastConnectedAt: lastConnectedAt)
  }
}

private struct VoiceCircle: View {
  let symbol: String
  let label: String
  var prominent = false
  let action: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: symbol == "arrow.up" ? 17 : 18, weight: prominent ? .semibold : .regular))
        .foregroundStyle(prominent ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary)
        .frame(width: 44, height: 44)
        .background(prominent ? Color.primary : Color.secondary.opacity(0.15), in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
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
    let live = WatchSessionGroups.sections(hosts: model.workbench.hosts.hosts, sessionsOf: model.workbench.sessions(of:),
      seen: preferences.seen, settings: preferences.settings)
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
      .navigationTitle("Sessions")
      .onAppear { held = groups }
      .onChange(of: model.workbench.hosts.hosts) { held = groups }
    }
  }
}

private struct WatchChatRow: View {
  let item: ConversationFeed.Item

  var body: some View {
    switch item.row {
    case .message(let shown) where shown.message.role == .assistant:
      Text(shown.message.text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
    case .message(let shown) where shown.message.role == .user:
      Text(shown.message.text).font(.caption).padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    case .pending(let prompt):
      Label(pendingLabel(prompt.state), systemImage: "arrow.up").font(.caption2).foregroundStyle(.secondary)
    case .queued:
      Text("Waiting for the agent").font(.caption2).foregroundStyle(.secondary)
    default: EmptyView()
    }
  }

  private func pendingLabel(_ state: HostWorkbenchModel.PendingPrompt.State) -> String {
    switch state {
    case .sending: "Sending…"
    case .sent: "Message sent"
    case .queued, .waitingForPi: "Waiting for the agent"
    case .uncertain: "Checking delivery…"
    }
  }
}
