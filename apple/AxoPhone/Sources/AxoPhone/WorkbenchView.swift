import AxoClient
import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// The phone's screens, stacked, the bottom first. At rest the conversation covers the rest;
/// a swipe right shows the chats under it, and another the account and its Macs under those.
/// A swipe left on the conversation pulls the chat's info in over it from the right.
private enum Layer: Int, CaseIterable {
  case account, chats, conversation, info

  /// What the strip of this layer, beside the one showing, says it does.
  var edgeName: String {
    switch self {
    case .account: "Back to account"
    case .chats: "Back to chats"
    case .conversation: "Back to conversation"
    case .info: "Chat info"
    }
  }
}

// Proportions measured from the original sidebar reference on a compact phone.
private enum MenuLayout {
  static let contentLeading: CGFloat = 32
  static let contentTrailing: CGFloat = 24
  static let rowInset: CGFloat = 10
  static let rowTextInset: CGFloat = 22
  /// Compact: a long list of chats should fit without scrolling much.
  static let rowHeight: CGFloat = 34
  static let selectedRowVerticalInset: CGFloat = 1
  static let sectionTopSpacing: CGFloat = 14
  static let controlSize: CGFloat = 44
}

/// The phone's whole screen: three layers, the conversation on top of the chats on top of the
/// account and its Macs (see `Layer` and `LayerStack`).
struct WorkbenchView: View {
  let environment: AppEnvironment
  @State private var workbench: PhoneWorkbench
  @State private var layer: Layer = PreviewFixture.hostsOpen ? .account : PreviewFixture.menuOpen ? .chats : .conversation
  @Environment(\.scenePhase) private var scenePhase
  @State private var showingSettings = PreviewFixture.settingsOpen
  @State private var showingSearch = false
  @State private var showingPairing = false
  /// Asks the relay for codes that link a Mac (the preview's stand-in in the simulator preview).
  private let pairingIssuer: any HostPairingIssuing
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("appearance") private var appearance: AppAppearance = .system
  @AppStorage("accentColor") private var accentColor: AppAccentColor = .white
  /// The Workspaces folded away in the menu, by section id, one a line; kept across launches.
  @AppStorage("collapsedWorkspaces") private var collapsedWorkspaceList = ""
  /// The Workspaces showing their older chats too. Not kept: that is a look back, not a way the
  /// menu stays.
  @State private var showingOlder: Set<String> = []
  /// Voice prompting, one dictation at a time for the whole app (nil before iOS 26).
  @State private var voice = Dictation.makeVoicePrompt()

  init(environment: AppEnvironment) {
    self.environment = environment
    let account = environment.account
    let endpoint = environment.endpoint
    let client = AccountClient(endpoint: endpoint, tokens: account.tokens)
    #if DEBUG && targetEnvironment(simulator)
      if PreviewFixture.requested {
        pairingIssuer = PreviewListing()
        _workbench = State(initialValue: PhoneWorkbench(
          hosts: HostsModel(listing: PreviewListing(), account: account),
          makeWorkbench: { host in
            HostWorkbenchModel(
              host: host, connection: HostConnection(transport: PreviewTransport(), host: host.reference),
              history: PreviewListing(), account: account)
          }))
        return
      }
    #endif
    pairingIssuer = client
    _workbench = State(initialValue: PhoneWorkbench(
      hosts: HostsModel(listing: client, account: account),
      makeWorkbench: { host in
        HostWorkbenchModel(
          host: host,
          connection: HostConnection(endpoint: endpoint, host: host.reference, tokens: account.tokens),
          history: client, account: account)
      }))
  }

  private var currentSession: RemoteSession? {
    workbench.current?.selectedSession
  }

  // The layers are built here, once per change to what they show; `LayerStack` alone moves
  // them, on every frame of a swipe.
  var body: some View {
    let _ = RenderCount.note("Workbench")
    LayerStack(
      showing: Binding(get: { layer.rawValue }, set: { layer = Layer(rawValue: $0) ?? .conversation }),
      home: Layer.conversation.rawValue,
      edgeNames: Layer.allCases.map(\.edgeName),
      layers: [
        AnyView(accountLayer), AnyView(sidebar), AnyView(conversation),
        AnyView(SessionInfoPanel(workbench: workbench.current, session: currentSession)),
      ]
    )
    .background(ChatColors.background.ignoresSafeArea())
    .onChange(of: layer) { _, layer in
      // The keyboard belongs to the conversation's box; it goes when the conversation does.
      if layer != .conversation {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
      }
    }
    .overlay(alignment: .trailing) {
      if RenderCount.enabled { RenderCountLabel() }
      #if DEBUG && targetEnvironment(simulator)
        if PreviewFixture.live == "stream" {
          // Starts the stream when a test is ready to count it.
          Button("Play stream") {
            guard let current = workbench.current, let id = current.selectedSessionID else { return }
            Task {
              // Five updates a second, as pi-axo sends them.
              for event in PreviewFixture.streamEvents(steps: 20) {
                current.playForPreview([event], in: id)
                try? await Task.sleep(for: .milliseconds(200))
              }
            }
          }
          .font(.system(size: 12)).buttonStyle(.plain).contentShape(Rectangle())
          .accessibilityIdentifier("play-stream")
          // The same reply, in a chat that is not open (the first one, working on the Mac).
          Button("Play stream elsewhere") {
            guard let current = workbench.current else { return }
            Task {
              for event in PreviewFixture.streamEvents(steps: 20) {
                current.playForPreview([event], in: 1)
                try? await Task.sleep(for: .milliseconds(200))
              }
            }
          }
          .font(.system(size: 12)).buttonStyle(.plain).contentShape(Rectangle())
          .padding(.top, 60)
          .accessibilityIdentifier("play-stream-elsewhere")
        }
      #endif
    }
    .preferredColorScheme(appearance.colorScheme)
    .tint(accentColor.color)
    .sheet(isPresented: $showingSearch) {
      SessionSearchView(hosts: workbench.hosts.hosts, sessionsOf: workbench.sessions(of:)) { host, session in
        workbench.select(host: host.hostId, session: session.sessionId)
        show(.conversation)
      }
    }
    .sheet(isPresented: $showingPairing) {
      PairMacSheet(issuer: pairingIssuer, hosts: workbench.hosts)
    }
    .sheet(isPresented: $showingSettings) {
      SettingsView(account: environment.account) {
        Task {
          // End it at the relay too, so a copied token stops working; then forget it here.
          try? await AccountClient(endpoint: environment.endpoint, tokens: environment.account.tokens).signOut()
          environment.account.signOut()
        }
      }
    }
    .task {
      await workbench.start()
      let chats = sections.flatMap(\.chats)
      if let index = PreviewFixture.chatOpen, chats.indices.contains(index - 1) {
        workbench.select(host: chats[index - 1].host.hostId, session: chats[index - 1].session.sessionId)
        #if DEBUG && targetEnvironment(simulator)
          if let live = PreviewFixture.live, live != "stream", let current = workbench.current, let id = current.selectedSessionID {
            try? await Task.sleep(for: .milliseconds(300))
            current.playForPreview(PreviewFixture.liveEvents(live), in: id)
            if live == "stopping" { current.markStoppingForPreview(id) }
          }
        #endif
      }
    }
    // The open Mac came back as a new run: list it again, which opens the new run.
    .onChange(of: workbench.current?.newRunOnline) { _, restarted in
      if restarted == true { Task { await workbench.refresh() } }
    }
    .onChange(of: scenePhase) { _, phase in
      // A socket left open in the background dies unnoticed; let it go, and come back fresh.
      switch phase {
      case .background:
        // Listening stops with the screen; what was heard is not kept.
        voice?.cancel()
        workbench.suspend()
      // From the background the scene passes through inactive first; the model knows whether
      // it let go and has anything to resume.
      case .active: Task { await workbench.resume() }
      default: break
      }
    }
  }

  private var conversation: some View {
    ConversationView(
      phone: workbench,
      workbench: workbench.current,
      session: currentSession,
      showSidebar: { show(.chats) },
      voice: voice
    )
    .id(currentSession?.sessionId)
    // Words said for one chat never land in another.
    .onChange(of: currentSession?.sessionId) { voice?.cancel() }
  }

  // MARK: - The menu

  private var sidebar: some View {
    RenderCount.note("Menu")
    // A plain stack rather than a List: List's section headers and row minimums are far taller
    // than a menu of chat names needs.
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        if case .failed(let message) = workbench.hosts.phase {
          Text(message).font(.caption).foregroundStyle(.orange)
            .padding(.horizontal, MenuLayout.rowInset + MenuLayout.rowTextInset)
        }
        ForEach(sections) { section in
          switch section.kind {
          case .project:
            let collapsed = collapsedWorkspaces.contains(section.id)
            sectionHeader(section, collapsed: collapsed, first: section.id == sections.first?.id)
            if !collapsed { sectionChats(section) }
          case .home:
            // Home's chats are the everyday ones: listed under the projects, newest first,
            // with no title to fold them away.
            Color.clear.frame(height: section.id == sections.first?.id ? 4 : MenuLayout.sectionTopSpacing + 8)
            sectionChats(section)
          }
        }
        if sections.isEmpty {
          if workbench.hosts.hosts.isEmpty, workbench.hosts.phase == .loaded {
            ContentUnavailableView(
              "No Macs yet", systemImage: "laptopcomputer",
              description: Text("On a Mac, open Axo → Settings → Remote Access and link it with a pairing code."))
          } else {
            Text(workbench.hosts.phase == .loading ? "Loading chats…" : "Your chats will appear here.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .padding(.horizontal, MenuLayout.rowInset + MenuLayout.rowTextInset)
          }
        }
      }
      .padding(.top, 8)
      .padding(.bottom, 12)
    }
    .scrollIndicators(.hidden)
    .softLayerEdges()
    .background(ChatColors.background.ignoresSafeArea())
    // SwiftUI cancels a refresh's task when the list redraws under it (which the refresh itself
    // causes); a reload of its own finishes, so the pull never ends in a cancellation.
    .refreshable { await Task { await workbench.refresh() }.value }
    .accessibilityIdentifier("workbench-menu")
    .layerBar(edge: .top) { menuHeader }
    .layerBar(edge: .bottom) { menuFooter }
  }

  private var collapsedWorkspaces: Set<String> {
    Set(collapsedWorkspaceList.split(separator: "\n").map(String.init))
  }

  private func toggleCollapsed(_ id: String) {
    var collapsed = collapsedWorkspaces
    if collapsed.remove(id) == nil { collapsed.insert(id) }
    collapsedWorkspaceList = collapsed.sorted().joined(separator: "\n")
  }

  /// A Workspace's title, which folds it away; a dot says a chat in a folded one is busy.
  private func sectionHeader(_ section: ChatMenuSection, collapsed: Bool, first: Bool) -> some View {
    Button {
      withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { toggleCollapsed(section.id) }
    } label: {
      HStack(spacing: 6) {
        Text(section.title).lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.bold))
          .rotationEffect(.degrees(collapsed ? -90 : 0))
        Spacer(minLength: 0)
        if collapsed, section.isBusy { Circle().fill(Color.orange).frame(width: 6, height: 6) }
      }
      .font(.footnote.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.leading, MenuLayout.rowInset + MenuLayout.rowTextInset)
      .padding(.trailing, MenuLayout.rowInset + MenuLayout.rowTextInset)
      .padding(.top, first ? 4 : MenuLayout.sectionTopSpacing)
      .padding(.bottom, 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.layerRow)
    .accessibilityLabel(section.title)
    .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
    .accessibilityHint(collapsed ? "Shows its chats" : "Hides its chats")
    .accessibilityAddTraits(.isHeader)
    .accessibilityIdentifier("workspace-section")
  }

  /// An open Workspace's chats: those active in the last 8 hours (and busy ones, and the open one),
  /// then the rest when asked for.
  @ViewBuilder private func sectionChats(_ section: ChatMenuSection) -> some View {
    let recent = section.recentChats(now: .now) { entry in
      workbench.selection == PhoneWorkbench.Selection(host: entry.host.hostId, session: entry.session.sessionId)
    }
    let olderCount = section.chats.count - recent.count
    let expanded = showingOlder.contains(section.id)
    ForEach(expanded ? section.chats : recent, id: \.session.sessionId) { entry in
            Button {
              workbench.select(host: entry.host.hostId, session: entry.session.sessionId)
              show(.conversation)
            } label: {
              SessionRow(
                workbench: workbench,
                selection: PhoneWorkbench.Selection(host: entry.host.hostId, session: entry.session.sessionId),
                name: entry.session.displayName,
                status: entry.session.status)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.layerRow)
            .padding(.horizontal, MenuLayout.rowInset)
          }
    if olderCount > 0 {
      Button {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
          if expanded { showingOlder.remove(section.id) } else { showingOlder.insert(section.id) }
        }
      } label: {
        Text(expanded ? "Show fewer" : "Show \(olderCount) older \(olderCount == 1 ? "chat" : "chats")")
          .font(.callout).foregroundStyle(.secondary)
          .padding(.horizontal, MenuLayout.rowTextInset)
          .frame(maxWidth: .infinity, minHeight: MenuLayout.rowHeight, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.layerRow)
      .padding(.horizontal, MenuLayout.rowInset)
    }
    if section.chats.isEmpty, section.kind == .project {
      Text("No chats yet")
        .font(.callout).foregroundStyle(.tertiary)
        .padding(.horizontal, MenuLayout.rowInset + MenuLayout.rowTextInset)
        .frame(height: MenuLayout.rowHeight)
    }
  }

  /// The chats, by Workspace, the most recently active first (see `ChatMenu`).
  private var sections: [ChatMenuSection] {
    let hosts = workbench.hosts.hosts
    let open = workbench.current.flatMap { current in hosts.first { $0.hostId == current.reference.hostId } }
    return ChatMenu.sections(
      hosts: hosts, sessionsOf: workbench.sessions(of:), openHost: open,
      workspaces: workbench.current?.workspaceList ?? [])
  }

  /// The account and its Macs, under the chats.
  private var accountLayer: some View {
    HostsPanel(
      hosts: workbench.hosts,
      openHost: workbench.current?.reference.hostId,
      chatsOf: { workbench.sessions(of: $0).filter { $0.hasAgent != false }.count },
      newChat: { host in
        workbench.select(host: host.hostId, session: nil)
        show(.conversation)
      },
      pair: { showingPairing = true },
      showSettings: { showingSettings = true },
      refresh: { await workbench.refresh() })
  }

  /// Moves the stack to `layer`, as a swipe would.
  private func show(_ layer: Layer) {
    withAnimation(reduceMotion ? nil : .interpolatingSpring(duration: 0.42, bounce: 0.08)) { self.layer = layer }
  }

  private var menuHeader: some View {
    HStack(spacing: 12) {
      OwnMascotView(loading: workbench.hosts.phase == .loading)
        .frame(height: 34)
      Spacer(minLength: 8)
      // The account and its Macs are also one more swipe to the right.
      Button {
        show(.account)
      } label: {
        Image(systemName: "person.crop.circle")
          .font(.system(size: 20, weight: .medium))
          .floatingCircle()
      }
      .accessibilityLabel("Account and Macs")
      Button {
        showingSearch = true
      } label: {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 19, weight: .medium))
          .floatingCircle()
      }
      .accessibilityLabel("Search chats")
    }
    .buttonStyle(.plain)
    .padding(.leading, MenuLayout.contentLeading)
    .padding(.trailing, MenuLayout.contentTrailing)
  }

  private var menuFooter: some View {
    HStack(spacing: 16) {
      Button {
        workbench.beginNewChat()
        show(.conversation)
      } label: {
        Label("Chat", systemImage: "square.and.pencil")
          .font(.headline)
          .frame(minHeight: MenuLayout.controlSize)
          .padding(.horizontal, 11)
          .background(Color.primary, in: Capsule())
          .foregroundStyle(ChatColors.background)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("New chat")

      Spacer(minLength: 0)

      Button {
        showingSettings = true
      } label: {
        Image(systemName: "gearshape")
          .font(.system(size: 19, weight: .medium))
          .floatingCircle(diameter: MenuLayout.controlSize)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Settings")
    }
    .buttonStyle(.plain)
    .padding(.leading, MenuLayout.contentLeading)
    .padding(.trailing, MenuLayout.contentTrailing)
    .padding(.top, 10)
  }
}

/// A chat in the menu: its name, with a filled row behind the open one.
private struct SessionRow: View {
  let workbench: PhoneWorkbench
  let selection: PhoneWorkbench.Selection
  let name: String
  let status: RemoteSessionStatus?

  // Read here, in the row's own body, so the row redraws when the open chat changes: a lazy
  // stack does not re-run its rows for a change only the menu's body saw.
  private var isSelected: Bool { workbench.selection == selection }

  var body: some View {
    HStack(spacing: 8) {
      Text(name)
        .font(.callout)
        .lineLimit(1)
      Spacer(minLength: 0)
      SessionStatusDot(status: status)
    }
      .padding(.horizontal, MenuLayout.rowTextInset)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: MenuLayout.rowHeight)
      .background {
        if isSelected {
          // A tint of the text colour, so it shows on the light menu as well as the dark one.
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .padding(.vertical, MenuLayout.selectedRowVerticalInset)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(name)
      .accessibilityValue(SessionStatusDot.spoken(status))
  }
}

/// Whether a chat's agent is busy or needs the person, at the end of its row.
private struct SessionStatusDot: View {
  let status: RemoteSessionStatus?

  static func spoken(_ status: RemoteSessionStatus?) -> String {
    switch status {
    case .working: "Working"
    case .needsAttention: "Needs your attention"
    case .starting: "Starting"
    case .unavailable: "Stopped"
    case .ready, nil: ""
    }
  }

  var body: some View {
    switch status {
    case .working:
      Circle().fill(Color.orange).frame(width: 7, height: 7)
        .phaseAnimator([1.0, 0.35]) { dot, opacity in dot.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.8) }
    case .needsAttention:
      Circle().fill(Color.blue).frame(width: 8, height: 8)
    case .unavailable:
      Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.secondary)
    case .starting, .ready, nil:
      EmptyView()
    }
  }
}

/// Under the chats: who is signed in, and their Macs.
private struct HostsPanel: View {
  let hosts: HostsModel
  let openHost: UUID?
  let chatsOf: (RemoteHost) -> Int
  let newChat: (RemoteHost) -> Void
  let pair: () -> Void
  let showSettings: () -> Void
  let refresh: () async -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        account
          .padding(.horizontal, MenuLayout.rowInset + MenuLayout.rowTextInset)
          .padding(.top, 18).padding(.bottom, 22)
        Text("Macs")
          .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
          .padding(.leading, MenuLayout.rowInset + MenuLayout.rowTextInset)
          .padding(.bottom, 4)
          .accessibilityAddTraits(.isHeader)
        if hosts.hosts.isEmpty {
          Text(hosts.phase == .loading ? "Loading…" : "No Macs yet. Pair one to chat with it from here.")
            .font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, MenuLayout.rowInset + MenuLayout.rowTextInset)
        }
        ForEach(hosts.hosts, id: \.hostId) { host in
          Button { newChat(host) } label: { HostRow(host: host, chats: chatsOf(host), isOpen: host.hostId == openHost) }
            .buttonStyle(.layerRow)
            .disabled(host.status != .online)
            .padding(.horizontal, MenuLayout.rowInset)
            .accessibilityHint(host.status == .online ? "Starts a new chat on this Mac" : "")
        }
      }
      .padding(.bottom, 12)
    }
    .scrollIndicators(.hidden)
    .softLayerEdges()
    .refreshable { await Task { await refresh() }.value }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ChatColors.background.ignoresSafeArea())
    .layerBar(edge: .top) {
      // No way back here: the chats are the strip at the edge, a tap or a swipe left away.
      Text("Account").font(.title3.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.leading, MenuLayout.contentLeading)
        .padding(.trailing, MenuLayout.contentTrailing)
        .accessibilityAddTraits(.isHeader)
    }
    .layerBar(edge: .bottom) {
      HStack(spacing: 16) {
        // Where the chats have their Chat button: the way to add what this layer lists.
        Button(action: pair) {
          Label("Pair a Mac", systemImage: "laptopcomputer.and.arrow.down")
            .font(.headline)
            .frame(minHeight: MenuLayout.controlSize)
            .padding(.horizontal, 11)
            .background(Color.primary, in: Capsule())
            .foregroundStyle(ChatColors.background)
        }
        .accessibilityLabel("Pair a Mac")
        Spacer(minLength: 0)
        Button(action: showSettings) {
          Image(systemName: "gearshape")
            .font(.system(size: 19, weight: .medium))
            .floatingCircle(diameter: MenuLayout.controlSize)
        }
        .accessibilityLabel("Settings")
      }
      .buttonStyle(.plain)
      .padding(.leading, MenuLayout.contentLeading)
      .padding(.trailing, MenuLayout.contentTrailing)
      .padding(.top, 10)
    }
    .accessibilityIdentifier("hosts-panel")
  }

  @ViewBuilder private var account: some View {
    let profile = hosts.signedIn?.profile
    HStack(spacing: 14) {
      Text(initials(profile))
        .font(.headline)
        .frame(width: 46, height: 46)
        .background(Color.primary.opacity(0.1), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(profile?.name ?? profile?.email ?? "Signed in").font(.headline).lineLimit(1)
        if let email = profile?.email, profile?.name != nil {
          Text(email).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        Text("Signed in with Cloudflare").font(.caption).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func initials(_ profile: SignedInAccount.Profile?) -> String {
    let source = profile?.name ?? profile?.email ?? "?"
    let words = source.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." })
    return String(words.prefix(2).compactMap(\.first)).uppercased()
  }
}

private struct HostRow: View {
  let host: RemoteHost
  let chats: Int
  let isOpen: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "laptopcomputer")
        .font(.system(size: 17))
        .foregroundStyle(host.status == .online ? Color.primary : Color.secondary)
        .frame(width: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(host.label).font(.callout.weight(isOpen ? .semibold : .regular)).lineLimit(1)
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      Circle().fill(host.status == .online ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
    }
    .padding(.horizontal, MenuLayout.rowTextInset - 8)
    .frame(height: 52)
    .background {
      if isOpen {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06))
      }
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(host.label)
    .accessibilityValue("\(host.status == .online ? "Online" : "Offline"), \(detail)")
  }

  private var detail: String {
    let count = chats == 1 ? "1 chat" : "\(chats) chats"
    guard host.status != .online else { return count }
    let seen = (try? Date(host.lastSeenAt, strategy: .iso8601)).map {
      "last seen " + $0.formatted(.relative(presentation: .named))
    }
    return [count, seen ?? "offline"].joined(separator: " · ")
  }
}

#if DEBUG && targetEnvironment(simulator)
  private struct PreviewListing: HostListing, PiHistoryLoading, HostPairingIssuing {
    func hosts() async throws -> [RemoteHost] { PreviewFixture.hosts }
    func createHostPairing() async throws -> HostPairing {
      HostPairing(code: HostPairingCode(parsing: "7KQ2-M4XD")!, expiresAt: Date() + 600)
    }
    func signedInAccount() async -> SignedInAccount? { PreviewFixture.account }
    func piEvents(of host: RemoteHostRef, session: SessionID, before cursor: Int64, limit: Int) async throws -> PiEventPage {
      cursor == 0 ? PiEventPage(events: PreviewFixture.events(for: session).reversed(), next: nil) : PiEventPage(events: [], next: nil)
    }
  }

  /// Answers just enough of the relay for a Mac to open: it agrees, subscribes, lists one
  /// Workspace, takes key presses, and refuses prompts (there is no Pi behind it).
  private struct PreviewTransport: AxoTransport {
    func connect() async throws -> any AxoMessageChannel { PreviewChannel() }
  }

  private final class PreviewChannel: AxoMessageChannel, @unchecked Sendable {
    let messages: AsyncStream<Data>
    private let sink: AsyncStream<Data>.Continuation

    init() { (messages, sink) = AsyncStream.makeStream() }

    func send(_ message: Data) async throws {
      guard let request = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
        let id = request["id"] as? Int, let method = request["method"] as? String
      else { return }
      let result: String? =
        switch method {
        case "axo.protocol.negotiate": #"{"protocolVersion":1,"methods":[]}"#
        case "axo.host.subscribe": #"{"subscriptionId":"\#(UUID().uuidString)"}"#
        case "axo.remote.workspace.list":
          #"{"workspaces":[{"workspaceId":"\#(UUID().uuidString)","name":"Home","home":true},{"workspaceId":"\#(UUID().uuidString)","name":"Axo"},{"workspaceId":"\#(UUID().uuidString)","name":"Website"}]}"#
        case "axo.remote.session.key": #"{"accepted":true}"#
        default: nil
        }
      let reply = result.map { #"{"jsonrpc":"2.0","id":\#(id),"result":\#($0)}"# }
        ?? #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32004,"message":"Resource not found"}}"#
      sink.yield(Data(reply.utf8))
    }

    func close() { sink.finish() }
  }
#endif
