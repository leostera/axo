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
  /// Pull-to-refresh,  /// Pull-to-refresh, played by Axo: the empty chat's Axo, or a small one at the top.
  @State private var pull: ConversationPull
  /// When to follow what is new and when to leave the reader be; the list scrolls by it.
  @State private var scroll: ConversationScroll
  /// The screen's bottom inset: the home indicator's (at most a few dozen points), or the
  /// keyboard's while it is up (always far taller).
  @State private var bottomInset: CGFloat = 0
  /// The rows of a chat that does not exist yet: none.
  @State private var noFeed = ConversationFeed()
  /// What the rows do, kept apart so that a row compares equal to itself when the list redraws.
  @State private var actions = ConversationRowActions()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(SidewaysScrolling.self) private var sidewaysScrolling
  @Environment(\.assetLoader) private var assetLoader
  @AppStorage("accentColor") private var accentColor: AppAccentColor = .white
  private var keyboardIsUp: Bool { bottomInset > 100 }

  /// This chat's own state: what it reads is what redraws it, so other chats' events do not.
  private var chat: Chat? { session.flatMap { workbench?.chat($0.sessionId) } }
  /// The conversation's rows, kept as the transcript changes (see `ConversationFeed`). The list
  /// reads only them: a reply being written redraws its own row, and the list only gains rows.
  private var feed: ConversationFeed { chat?.feed ?? noFeed }

  init(
    phone: PhoneWorkbench, workbench: HostWorkbenchModel?, session: RemoteSession?, showSidebar: @escaping () -> Void,
    voice: VoicePrompt?, showApps: (() -> Void)? = nil
  ) {
    self.phone = phone
    self.workbench = workbench
    self.session = session
    self.showSidebar = showSidebar
    self.voice = voice
    self.showApps = showApps
    let pull = ConversationPull()
    _pull = State(initialValue: pull)
    _scroll = State(initialValue: ConversationScroll(pull: pull))
  }


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
  }

  /// The rows, in a list that owns where it is scrolled to (`ConversationList`); it runs under the
  /// bars, which it is told the height of.
  private var conversation: some View {
    ConversationList(
        content: .init(
          feed: feed, chat: chat, phone: phone, workbench: workbench, session: session?.sessionId, canSend: canSend,
          actions: actions, pull: pull, loadOlder: loadOlder, refresh: refresh),
        scroll: scroll, sidewaysScrolling: sidewaysScrolling, tint: accentColor.color, assetLoader: assetLoader
      )
      .ignoresSafeArea()
      // Following what is new; watched apart, so the reply growing does not redraw the list.
      .background {
        EndWatcher(
          feed: feed, chat: chat,
          changed: { scroll.move(scroll.follow.contentChangedAtEnd()) },
          // Sending something takes the reader to it.
          sent: { scroll.move(scroll.follow.sent()) })
      }
    // How far the bars (and the keyboard) cover it, measured where it would sit without them.
    .background {
      Color.clear.onGeometryChange(for: [CGFloat].self) { [$0.safeAreaInsets.top, $0.safeAreaInsets.bottom] } action: {
        scroll.insets = (top: $0[0], bottom: $0[1])
      }
    }
    .overlay(alignment: .top) {
      if !feed.items.isEmpty { SpinningPullMascotView(pull: pull) }
    }
  }

  /// Reloads  }

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
      if !scroll.isFollowing {
        Button { scroll.move(scroll.follow.jumpRequested()) } label: {
          HStack(spacing: 6) {
            Image(systemName: "arrow.down")
              .font(.system(size: 20, weight: .semibold))
              .frame(width: 44, height: 44)
            if scroll.hasNew {
              Text("Jump to new message").font(.callout.weight(.semibold)).padding(.trailing, 14)
            }
          }
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .accessibilityLabel(scroll.hasNew ? "Jump to new message" : "Jump to latest")
      }
      if let id = session?.sessionId {
        WaitingQuestions(phone: phone, session: id, canAnswer: workbench?.status == .online)
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
