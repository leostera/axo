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
  /// Settings, open on its first page or on Apps (the account panel's Apps row).
  @State private var settings: SettingsView.Opening? =
    PreviewFixture.appsOpen ? .apps : PreviewFixture.settingsOpen ? .settings : nil
  /// Settings › Apps: what the account's Sessions can use.
  @State private var apps: AppsModel
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
  /// Whether the menu lists chats as the Mac's sidebar does (Pinned, Active, Earlier) or under
  /// their Workspaces; kept across launches.
  @AppStorage("chatListMode") private var chatListMode: ChatListMode = .recent
  /// Pins, seen marks and how to group, kept on this phone (Settings › Chats).
  @State private var chatPrefs = ChatListPreferences(defaults: Self.chatListDefaults())
  /// The groups as they were when the chats showed, so a chat that just finished a message does
  /// not move under a finger reaching for a row; it moves into place the next time they show.
  /// Held, not observed: taking hold as the menu opens is what that redraw just showed, so it
  /// redraws nothing more (twice per swipe otherwise); a pin or a change of mode redraws anyway.
  @State private var held = HeldGroups()

  private final class HeldGroups {
    var groups: [ChatGroupSection]?
  }
  /// Whether Earlier is folded away, and whether it shows past its limit. Not kept: each launch
  /// starts as Settings › Chats says.
  @State private var earlierFolded: Bool?
  @State private var showingAllEarlier = false
  /// Voice prompting, one dictation at a time for the whole app (nil before iOS 26).
  @State private var voice = Dictation.makeVoicePrompt()

  init(environment: AppEnvironment) {
    self.environment = environment
    let account = environment.account
    let endpoint = environment.endpoint
    let client = AccountClient(endpoint: endpoint, tokens: account.tokens)
    #if DEBUG && targetEnvironment(simulator)
      if PreviewFixture.requested {
        pairingIssuer = PreviewPairing()
        _apps = State(initialValue: AppsModel(service: PreviewApps()))
        let feed = AccountConnection(transport: PreviewTransport(), clientID: .random())
        _workbench = State(initialValue: PhoneWorkbench(
          hosts: HostsModel(profile: PreviewPairing()), feed: feed, account: account,
          makeWorkbench: { host in
            HostWorkbenchModel(
              host: host, connection: HostConnection(account: feed, host: host.reference), feed: feed, account: account)
          }))
        return
      }
    #endif
    pairingIssuer = client
    _apps = State(initialValue: AppsModel(service: AppsClient(endpoint: endpoint, tokens: account.tokens)))
    // One socket for the whole account, as this install's client (RFD0018).
    let feed = AccountConnection(endpoint: endpoint, clientID: .installed(), tokens: account.tokens)
    // Photos and files go to the account's assets before the message that carries them (RFD0030).
    let assets = AssetsClient(endpoint: endpoint, tokens: account.tokens)
    _workbench = State(initialValue: PhoneWorkbench(
      hosts: HostsModel(profile: client), feed: feed, account: account,
      uploadAsset: { data, name, mimeType in try await assets.upload(data, name: name, mimeType: mimeType) },
      makeWorkbench: { host in
        HostWorkbenchModel(
          host: host, connection: HostConnection(account: feed, host: host.reference), feed: feed, account: account)
      }))
  }

  /// Where pins and seen marks are kept: the phone's defaults, or a blank slate for each launch of
  /// the simulator preview, so one UI test's pins never show in the next.
  private static func chatListDefaults() -> UserDefaults {
    guard PreviewFixture.requested, let preview = UserDefaults(suiteName: "preview.chatList") else { return .standard }
    preview.removePersistentDomain(forName: "preview.chatList")
    return preview
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
      // The list holds still while the chats show, and catches up when they show again.
      held.groups = layer == .chats ? liveGroups(now: .now) : nil
    }
    // The open chat's messages are seen as they arrive.
    .onChange(of: currentSession.map { ChatMenu.activity($0) }, initial: true) {
      if let currentSession, layer == .conversation { chatPrefs.markSeen(currentSession) }
    }
    .onChange(of: currentSession?.sessionId) {
      if let currentSession { chatPrefs.markSeen(currentSession) }
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
                current.playForPreview([event], in: PreviewFixture.sessionID(1))
                try? await Task.sleep(for: .milliseconds(200))
              }
            }
          }
          .font(.system(size: 12)).buttonStyle(.plain).contentShape(Rectangle())
          .padding(.top, 60)
          .accessibilityIdentifier("play-stream-elsewhere")
        }
        if PreviewFixture.live == "flood" {
          // Thirty long replies, ten a second, when a test is ready.
          Button("Play flood") {
            guard let current = workbench.current, let id = current.selectedSessionID else { return }
            Task {
              for event in PreviewFixture.floodEvents(replies: 30) {
                current.playForPreview([event], in: id)
                try? await Task.sleep(for: .milliseconds(100))
              }
            }
          }
          .font(.system(size: 12)).buttonStyle(.plain).contentShape(Rectangle())
          .padding(.top, 120)
          .accessibilityIdentifier("play-flood")
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
      PairMacSheet(
        issuer: pairingIssuer, hosts: workbench.hosts, origin: environment.endpoint.origin,
        refresh: { await workbench.refresh() })
    }
    .sheet(item: $settings) { opening in
      SettingsView(account: environment.account, apps: apps, chatList: chatPrefs, opening: opening) {
        Task {
          // End it at the relay too, so a copied token stops working; then forget it here.
          try? await AccountClient(endpoint: environment.endpoint, tokens: environment.account.tokens).signOut()
          environment.account.signOut()
        }
      }
    }
    .task {
      await workbench.start()
      if PreviewFixture.chatOpen != nil {
        // The listing is applied as the socket's hello arrives, after `start` returns: wait for it
        // (a few seconds at most) before choosing the chat to open.
        for _ in 0..<100 where sections.flatMap(\.chats).isEmpty {
          try? await Task.sleep(for: .milliseconds(30))
        }
      }
      let chats = sections.flatMap(\.chats)
      if let index = PreviewFixture.chatOpen, chats.indices.contains(index - 1) {
        workbench.select(host: chats[index - 1].host.hostId, session: chats[index - 1].session.sessionId)
        #if DEBUG && targetEnvironment(simulator)
          if let live = PreviewFixture.live, live != "stream", let current = workbench.current, let id = current.selectedSessionID {
            // Played over the chat once it is open, or opening it would replace what was played.
            for _ in 0..<100 {
              if case .loaded = current.chat(id).history { break }
              try? await Task.sleep(for: .milliseconds(30))
            }
            try? await Task.sleep(for: .milliseconds(300))
            current.playForPreview(PreviewFixture.liveEvents(live), in: id)
            if live == "stopping" { current.markStoppingForPreview(id) }
          }
        #endif
      }
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
      voice: voice,
      showApps: { settings = .apps }
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
        if chatListMode == .recent, !sections.isEmpty {
          groupedChats
        } else if chatListMode == .workspaces {
          // Pinned chats lead in Workspaces too, as in the grouped list.
          ForEach(pinnedEntries, id: \.key) { entry in chatRow(entry, showsAge: false, pinned: true) }
        }
        ForEach(chatListMode == .workspaces ? sections : []) { section in
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

  /// Every chat on every Mac in its group, as the Mac's sidebar lists them: Pinned, Active, then
  /// Earlier (see `ChatGrouping`), each with how long ago it was active.
  private func liveGroups(now: Date) -> [ChatGroupSection] {
    ChatGrouping.sections(
      ChatMenu.recent(hosts: workbench.hosts.hosts, sessionsOf: workbench.sessions(of:)),
      pins: chatPrefs.pins, seen: chatPrefs.seen, now: Int64(now.timeIntervalSince1970),
      settings: chatPrefs.settings)
  }

  /// A line of the grouped list. One flat list rather than a ForEach per group: a lazy stack
  /// kept showing a moved row as it was in its old group (unpinned) with nested ones.
  private enum GroupedItem: Identifiable {
    case header(ChatGroupSection, folded: Bool, first: Bool)
    case chat(ChatMenuEntry, pinned: Bool)
    case more(String, showAll: Bool)

    var id: String {
      switch self {
      case .header(let section, _, _): "group-\(section.group.rawValue)"
      case .chat(let entry, let pinned): "chat-\(entry.host.hostId)-\(entry.session.sessionId.rawValue)-\(pinned)"
      case .more: "more"
      }
    }
  }

  private var groupedItems: [GroupedItem] {
    let settings = chatPrefs.settings
    let groups = ChatGrouping.holding(held.groups, live: liveGroups(now: .now))
    var items: [GroupedItem] = []
    for section in groups {
      let folded = section.group == .earlier && (earlierFolded ?? settings.earlierCollapsed)
      if settings.showsGroupTitles || section.group == .earlier {
        items.append(.header(section, folded: folded, first: section.id == groups.first?.id))
      }
      guard !folded else { continue }
      let limit = section.group == .earlier && !showingAllEarlier ? settings.earlierLimit : nil
      items += section.chats.prefix(limit ?? .max).map { .chat($0, pinned: section.group == .pinned) }
      if let limit, section.chats.count > limit {
        items.append(.more("Show \(section.chats.count - limit) more", showAll: true))
      } else if section.group == .earlier, showingAllEarlier, let limit = settings.earlierLimit, section.chats.count > limit {
        items.append(.more("Show fewer", showAll: false))
      }
    }
    return items
  }

  private var groupedChats: some View {
    ForEach(groupedItems) { item in
      switch item {
      case .header(let section, let folded, let first): groupHeader(section, folded: folded, first: first)
      case .chat(let entry, let pinned): chatRow(entry, showsAge: true, pinned: pinned)
      case .more(let title, let showAll): showMoreButton(title) { showingAllEarlier = showAll }
      }
    }
  }

  /// Pinned chats, in pin order: the top of the Workspaces list.
  private var pinnedEntries: [ChatMenuEntry] {
    let all = ChatMenu.recent(hosts: workbench.hosts.hosts, sessionsOf: workbench.sessions(of:))
    return ChatGrouping.sections(
      all.filter { chatPrefs.pins.contains($0.session.sessionId) }, pins: chatPrefs.pins, seen: chatPrefs.seen,
      now: 0, settings: chatPrefs.settings
    ).first?.chats ?? []
  }

  /// A group's title; Earlier's folds it away, with how many chats it holds.
  private func groupHeader(_ section: ChatGroupSection, folded: Bool, first: Bool) -> some View {
    let foldable = section.group == .earlier
    return Button {
      guard foldable else { return }
      withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
        earlierFolded = !folded
      }
    } label: {
      HStack(spacing: 6) {
        Text(section.group.title).lineLimit(1)
        if foldable {
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.bold))
            .rotationEffect(.degrees(folded ? -90 : 0))
          if folded { Text("\(section.chats.count)").foregroundStyle(.tertiary) }
        }
        Spacer(minLength: 0)
      }
      .font(.footnote.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, MenuLayout.rowInset + MenuLayout.rowTextInset)
      .padding(.top, first ? 4 : MenuLayout.sectionTopSpacing)
      .padding(.bottom, 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.layerRow)
    .disabled(!foldable)
    .accessibilityLabel(section.group.title)
    .accessibilityValue(foldable ? (folded ? "Collapsed" : "Expanded") : "")
    .accessibilityAddTraits(.isHeader)
    .accessibilityIdentifier("chat-group-\(section.group.title.lowercased())")
  }

  private func showMoreButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button {
      withAnimation(reduceMotion ? nil : .snappy(duration: 0.25), action)
    } label: {
      Text(title)
        .font(.callout).foregroundStyle(.secondary)
        .padding(.horizontal, MenuLayout.rowTextInset)
        .frame(maxWidth: .infinity, minHeight: MenuLayout.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.layerRow)
    .padding(.horizontal, MenuLayout.rowInset)
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
    // Pinned chats are listed above the Workspaces, not again in theirs.
    ForEach((expanded ? section.chats : recent).filter { !chatPrefs.pins.contains($0.session.sessionId) },
      id: \.session.sessionId)
    { entry in
      chatRow(entry, showsAge: false)
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

  /// A chat in the menu, which opens it; a long press pins it to the top, or unpins it.
  private func chatRow(_ entry: ChatMenuEntry, showsAge: Bool, pinned: Bool = false) -> some View {
    let marker = chatPrefs.settings.unseenMarker
    let unseen = chatPrefs.seen.isUnseen(entry.session)
      && workbench.selection != PhoneWorkbench.Selection(host: entry.host.hostId, session: entry.session.sessionId)
    return Button {
      workbench.select(host: entry.host.hostId, session: entry.session.sessionId)
      show(.conversation)
    } label: {
      SessionRow(
        workbench: workbench,
        selection: PhoneWorkbench.Selection(host: entry.host.hostId, session: entry.session.sessionId),
        name: entry.session.displayName,
        status: entry.session.status,
        lastActive: showsAge ? ChatMenu.activity(entry.session) : nil,
        // In Workspaces the section's title names the Mac; the recent list mixes them.
        hostLabel: showsAge && workbench.hosts.hosts.count > 1 ? entry.host.label : nil,
        pinned: pinned,
        unseen: unseen ? marker : nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.layerRow)
    .padding(.horizontal, MenuLayout.rowInset)
    .contextMenu {
      Button(pinned ? "Unpin" : "Pin to the top", systemImage: pinned ? "pin.slash" : "pin") {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
          chatPrefs.togglePin(entry.session.sessionId)
          // A pin applies at once, even while the list holds still.
          if held.groups != nil { held.groups = liveGroups(now: .now) }
        }
      }
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
      rename: { host, name in await workbench.renameHost(host.hostId, to: name) },
      pair: { showingPairing = true },
      showApps: { settings = .apps },
      showSettings: { settings = .settings },
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
      Button {
        chatListMode = chatListMode == .workspaces ? .recent : .workspaces
        held.groups = liveGroups(now: .now)
      } label: {
        Image(systemName: chatListMode == .workspaces ? "clock" : "list.bullet.indent")
          .font(.system(size: 18, weight: .medium))
          .floatingCircle()
      }
      .accessibilityLabel(chatListMode == .workspaces ? "Show recent chats" : "Show Workspaces")
      .accessibilityIdentifier("chat-list-mode")
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
        settings = .settings
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
  /// When the chat was last active, shown as a short age in the recent list; nil in Workspaces.
  var lastActive: Date?
  /// The Mac the chat is on, when there is more than one to tell apart.
  var hostLabel: String?
  /// Pinned to the top: a pin shows at the end of the row.
  var pinned = false
  /// How activity not yet seen shows, when there is some.
  var unseen: ChatUnseenMarker?

  // Read here, in the row's own body, so the row redraws when the open chat changes: a lazy
  // stack does not re-run its rows for a change only the menu's body saw.
  private var isSelected: Bool { workbench.selection == selection }
  /// A chat whose agent waits for the person's answer needs them (RFD0029).
  private var shownStatus: RemoteSessionStatus? {
    if let session = selection.session, !workbench.questions(in: session).isEmpty { return .needsAttention }
    return status
  }

  var body: some View {
    HStack(spacing: 8) {
      if unseen?.showsDot == true {
        Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityHidden(true)
      }
      Text(name)
        .font(.callout.weight(unseen?.showsBold == true ? .semibold : .regular))
        .lineLimit(1)
        .layoutPriority(1)
      Spacer(minLength: 0)
      if let hostLabel {
        Text(hostLabel)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      SessionStatusDot(status: shownStatus)
      if let lastActive {
        // Ages only need to move once a minute.
        TimelineView(.periodic(from: .now, by: 60)) { context in
          Text(ChatMenu.age(of: lastActive, now: context.date))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .fixedSize()
        }
      }
      if pinned {
        Image(systemName: "pin.fill")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(45))
          .accessibilityHidden(true)
      }
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
      .accessibilityValue(spokenValue)
  }

  private var spokenValue: String {
    let age = lastActive.map { $0.formatted(.relative(presentation: .named)) }
    let host = hostLabel.map { "on \($0)" }
    return [pinned ? "Pinned" : "", unseen != nil ? "Unseen" : "", host ?? "", SessionStatusDot.spoken(shownStatus), age ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
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
  /// Names a Mac for the account; says why it could not, or nil once saved.
  let rename: (RemoteHost, String) async -> String?
  let pair: () -> Void
  let showApps: () -> Void
  let showSettings: () -> Void
  let refresh: () async -> Void

  /// The Mac being named, and the name typed so far.
  @State private var renaming: RemoteHost?
  @State private var newName = ""
  @State private var renameFailure: String?

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
          HStack(spacing: 0) {
            Button { newChat(host) } label: { HostRow(host: host, chats: chatsOf(host), isOpen: host.hostId == openHost) }
              .buttonStyle(.layerRow)
              .disabled(host.status != .online)
              .accessibilityHint(host.status == .online ? "Starts a new chat on this Mac" : "")
            // The network's name for a Mac is rarely what anyone calls it. An offline Mac can be
            // named too: the name is the account's, not the Mac's.
            Button {
              newName = host.label
              renaming = host
            } label: {
              Image(systemName: "pencil")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename \(host.label)")
          }
          .padding(.horizontal, MenuLayout.rowInset)
        }
        Text("Apps")
          .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
          .padding(.leading, MenuLayout.rowInset + MenuLayout.rowTextInset)
          .padding(.top, 22).padding(.bottom, 4)
          .accessibilityAddTraits(.isHeader)
        Button(action: showApps) {
          HStack(spacing: 12) {
            Image(systemName: "powerplug").font(.system(size: 17)).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
              Text("Apps").font(.callout)
              Text("Gmail, GitHub, MCP servers and more").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
          }
          .padding(.horizontal, MenuLayout.rowTextInset - 8)
          .frame(height: 52)
          .contentShape(Rectangle())
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Apps")
        }
        .buttonStyle(.layerRow)
        .padding(.horizontal, MenuLayout.rowInset)
      }
      .padding(.bottom, 12)
    }
    .scrollIndicators(.hidden)
    .softLayerEdges()
    .refreshable { await Task { await refresh() }.value }
    .alert(
      "Rename Mac",
      isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
      presenting: renaming
    ) { host in
      TextField("Name", text: $newName)
        .accessibilityIdentifier("mac-name")
      Button("Save") {
        let name = String(newName.prefix(64))
        Task { renameFailure = await rename(host, name) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Shown on every device of this account. Leave it empty for the Mac's own name.")
    }
    .alert(
      "Could not rename",
      isPresented: Binding(get: { renameFailure != nil }, set: { if !$0 { renameFailure = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(renameFailure ?? "")
    }
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

extension ClientID {
  /// This install's client id: made once and kept, so a reconnect replaces this phone's socket
  /// instead of adding one.
  static func installed(_ defaults: UserDefaults = .standard) -> ClientID {
    let key = "axo.clientId"
    if let stored = defaults.string(forKey: key).flatMap(ClientID.init(rawValue:)) { return stored }
    let made = ClientID.random()
    defaults.set(made.rawValue, forKey: key)
    return made
  }
}

#if DEBUG && targetEnvironment(simulator)
  private struct PreviewPairing: SignedInAccountLoading, HostPairingIssuing {
    func createHostPairing() async throws -> HostPairing {
      HostPairing(code: HostPairingCode(parsing: "7KQ2-M4XD")!, expiresAt: Date() + 600)
    }
    func signedInAccount() async -> SignedInAccount? { PreviewFixture.account }
  }

  /// Answers just enough of the account's socket for the app to run: it lists the sample Macs,
  /// opens their chats, lists one Mac's Workspaces, takes key presses, and refuses prompts (there
  /// is no agent behind it).
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
      let params = request["params"] as? [String: Any]
      let result: String? =
        switch method {
        case "axo.client.hello", "axo.client.refresh": PreviewFixture.listing
        case "axo.client.host.rename":
          // The name as asked for; an empty one goes back to the Mac's own.
          (params?["name"] as? String).map { name in
            let label = name.isEmpty ? "Mac-Studio.local" : name
            return String(data: try! JSONSerialization.data(withJSONObject: ["label": label]), encoding: .utf8)!
          }
        case "axo.client.session.open":
          (params?["sessionId"] as? String).flatMap(SessionID.init(rawValue:)).map(PreviewFixture.opened(_:))
        case "axo.client.command":
          switch params?["method"] as? String {
          case "axo.remote.workspace.list":
            #"{"workspaces":[{"workspaceId":"\#(UUID().uuidString)","name":"Home","home":true},{"workspaceId":"\#(UUID().uuidString)","name":"Axo"},{"workspaceId":"\#(UUID().uuidString)","name":"Website"}]}"#
          case "axo.remote.session.key": #"{"accepted":true}"#
          case "axo.remote.session.stop": #"{"stopped":true}"#
          default: nil
          }
        default: nil
        }
      let reply = result.map { #"{"jsonrpc":"2.0","id":\#(id),"result":\#($0)}"# }
        ?? #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32004,"message":"Resource not found"}}"#
      sink.yield(Data(reply.utf8))
    }

    func close() { sink.finish() }
  }
#endif
