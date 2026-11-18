import AxoClient
import AxoMobileModel
import AxoProtocol
import SwiftUI

private enum WorkbenchDetail { case conversation, apps }

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
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var splitVisibility: NavigationSplitViewVisibility = .all
  @State private var sidebarShowsHosts = PreviewFixture.hostsOpen
  @State private var showingInfo = false
  @State private var detail: WorkbenchDetail = .conversation
  @State private var appsPath: [AppsRoute] = []
  /// Settings, open on its first page or on Apps (the account panel's Apps row).
  @State private var settings: SettingsView.Opening? =
    PreviewFixture.appsOpen ? nil : PreviewFixture.settingsOpen ? .settings : nil
  /// Settings › Apps: what the account's Sessions can use.
  @State private var apps: AppsModel
  @State private var showingRequests = false
  @State private var showingSearch = false
  @State private var showingPairing = false
  /// Asks the relay for codes that link a Mac (the preview's stand-in in the simulator preview).
  private let pairingIssuer: any HostPairingIssuing
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("appearance") private var appearance: AppAppearance = .system
  @AppStorage("accentColor") private var accentColor: AppAccentColor = .white
  /// Pins, seen marks and how to group, kept on this phone (Settings › Chats).
  @State private var chatPrefs = ChatListPreferences(defaults: Self.chatListDefaults())
  @State private var signOutFailed = false
  /// The groups as they were when the chats showed, so a chat that just finished a message does
  /// not move under a finger reaching for a row; it moves into place the next time they show.
  /// Held, not observed: taking hold as the menu opens is what that redraw just showed, so it
  /// redraws nothing more (twice per swipe otherwise); pinning redraws anyway.
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
  /// Downloads the pictures tools came back with that are kept in the account's assets.
  private let assetLoader: AssetLoader

  init(environment: AppEnvironment) {
    self.environment = environment
    let account = environment.account
    let endpoint = environment.endpoint
    let client = AccountClient(endpoint: endpoint, tokens: account.tokens)
    #if DEBUG && targetEnvironment(simulator)
      if PreviewFixture.requested {
        assetLoader = AssetLoader { _ in PreviewFixture.picture }
        pairingIssuer = PreviewPairing()
        _apps = State(initialValue: AppsModel(service: PreviewApps()))
        let feed = AccountConnection(transport: PreviewTransport(), clientID: .random())
        let uploads = PreviewAttachmentUploads(mode: ProcessInfo.processInfo.environment["AXO_MOBILE_PREVIEW_UPLOAD"])
        _workbench = State(initialValue: PhoneWorkbench(
          hosts: HostsModel(profile: PreviewPairing()), feed: feed, account: account,
          uploadAsset: { data, name, mimeType in try await uploads.upload(data, name: name, mimeType: mimeType) },
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
    assetLoader = AssetLoader { hex in try await assets.download(hex: hex) }
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
    // AXO_PHONE_PREVIEW_UNSEEN=1: this phone started keeping track long ago, so every chat has
    // activity nobody here saw.
    if ProcessInfo.processInfo.environment["AXO_PHONE_PREVIEW_UNSEEN"] == "1" {
      preview.set(0, forKey: ChatListPreferences.Key.seenBaseline)
    }
    return preview
  }

  private var currentSession: RemoteSession? {
    workbench.current?.selectedSession
  }

  // The layers are built here, once per change to what they show; `LayerStack` alone moves
  // them, on every frame of a swipe.
  var body: some View {
    let _ = RenderCount.note("Workbench")
    Group {
      if horizontalSizeClass == .regular {
        NavigationSplitView(columnVisibility: $splitVisibility) {
          WorkbenchSidebarPager(showingHosts: $sidebarShowsHosts, chats: sidebar, hosts: accountLayer)
          .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
          .toolbar(.hidden, for: .navigationBar)
        } detail: {
          regularDetail
        }
        .navigationSplitViewStyle(.balanced)
      } else {
        ZStack {
          LayerStack(
            showing: Binding(get: { layer.rawValue }, set: { layer = Layer(rawValue: $0) ?? .conversation }),
            home: Layer.conversation.rawValue,
            edgeNames: Layer.allCases.map(\.edgeName),
            layers: [
              AnyView(accountLayer), AnyView(sidebar), AnyView(conversation),
              AnyView(SessionInfoPanel(workbench: workbench.current, session: currentSession)
                .layerBar(edge: .top) {
                  HStack {
                    Spacer()
                    if detail == .conversation, layer == .info {
                      RequestsBell(phone: workbench, open: { showingRequests = true })
                    }
                  }.padding(.horizontal, 14)
                }),
            ]
          )
          .opacity(detail == .conversation ? 1 : 0)
          .allowsHitTesting(detail == .conversation)
          .accessibilityHidden(detail != .conversation)
          if detail == .apps {
            NavigationStack(path: $appsPath) { appsContent }
          }
        }
      }
    }
    .background(ChatColors.background.ignoresSafeArea())
    .environment(\.assetLoader, assetLoader)
    .sheet(isPresented: $showingRequests) {
      RequestsInbox(phone: workbench, client: AccountClient(endpoint: environment.endpoint, tokens: environment.account.tokens))
    }
    .modifier(RequestNotificationsModifier(phone: workbench, account: environment.account, showingRequests: $showingRequests))
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
      if let currentSession, conversationIsVisible { chatPrefs.markSeen(currentSession) }
    }
    .onChange(of: currentSession?.sessionId) {
      if let currentSession, conversationIsVisible { chatPrefs.markSeen(currentSession) }
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
              let requested = Int(ProcessInfo.processInfo.environment["AXO_PHONE_PREVIEW_STREAM_STEPS"] ?? "") ?? 20
              for event in PreviewFixture.streamEvents(steps: min(200, max(1, requested))) {
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
          Button("Play flood") { playFlood() }
          .font(.system(size: 12)).buttonStyle(.plain).contentShape(Rectangle())
          .padding(.top, 120)
          .accessibilityIdentifier("play-flood")
          // Played by itself, for looking at it by hand: AXO_PHONE_PREVIEW_AUTOPLAY=1.
          .task {
            guard ProcessInfo.processInfo.environment["AXO_PHONE_PREVIEW_AUTOPLAY"] == "1" else { return }
            try? await Task.sleep(for: .seconds(2))
            playFlood()
          }
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
      SettingsView(account: environment.account, hosts: workbench.hosts, apps: apps, chatList: chatPrefs, opening: opening,
        openAppsInWorkbench: usesAppsPane ? { openApps() } : nil) {
        let revision = environment.account.credentialRevision
        Task {
          let token = try? await environment.account.tokens.sessionToken()
          guard environment.account.credentialRevision == revision else { return }
          // Durably invalidate any staged/shared import before ending the local credential.
          guard environment.account.signOut() else { signOutFailed = true; return }
          if let token {
            try? await AccountClient(endpoint: environment.endpoint, tokens: StaticSessionToken(token)).signOut()
          }
        }
      }
    }
    .task {
      await workbench.start()
      if PreviewFixture.appsOpen { openApps() }
      if PreviewFixture.chatOpen != nil {
        // The listing is applied as the socket's hello arrives, after `start` returns: wait for it
        // (a few seconds at most) before choosing the chat to open.
        for _ in 0..<100 where menuEntries.isEmpty {
          try? await Task.sleep(for: .milliseconds(30))
        }
      }
      if let selection = PreviewFixture.chatSelection {
        workbench.select(host: selection.host, session: selection.session)
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
            if live == "elicitation" {
              // Asked a moment later, once the reader may have scrolled up into the history.
              try? await Task.sleep(for: .seconds(3))
              let now = Int64(Date().timeIntervalSince1970 * 1000)
              workbench.askForPreview(
                Elicitation(
                  id: "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5a", sessionId: id,
                  message: "Delete the branch feat/old-ui? It has 3 unmerged commits.",
                  createdAt: now, expiresAt: now + 300_000),
                host: selection.host)
            }
          }
        #endif
      }
      await PreviewFixture.attach(to: workbench)
    }
    .alert("Could not sign out", isPresented: $signOutFailed) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(environment.account.signInFailure ?? "Unlock this device and try again.")
    }
    .onDisappear { keepInterruptedVoice() }
    .onChange(of: workbench.selection) { keepInterruptedVoice() }
    .onChange(of: scenePhase) { _, phase in
      // A socket left open in the background dies unnoticed; let it go, and come back fresh.
      switch phase {
      case .background:
        // A locked screen is not an explicit Cancel. Hand recognized words to this chat
        // synchronously, before suspending its connection or SwiftUI stops rendering updates.
        keepInterruptedVoice()
        workbench.suspend()
      // From the background the scene passes through inactive first; the model knows whether
      // it let go and has anything to resume.
      case .active: Task { await workbench.resume() }
      default: break
      }
    }
  }

  private var usesAppsPane: Bool {
    horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad
  }

  private var conversationIsVisible: Bool {
    detail == .conversation && (horizontalSizeClass == .regular || layer == .conversation)
  }

  /// Only the sidebar pages. Apps replaces detail; info adds a nonmodal trailing column.
  private var regularDetail: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        NavigationStack(path: $appsPath) {
          ZStack {
            // Keep the same editor/transcript mounted while browsing Apps.
            conversation
              .opacity(detail == .conversation ? 1 : 0)
              .allowsHitTesting(detail == .conversation)
              .accessibilityHidden(detail != .conversation)
            if detail == .apps {
              appsContent
            }
          }
          .toolbar(detail == .apps ? .visible : .hidden, for: .navigationBar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        if detail == .conversation, showingInfo {
          Divider()
          SessionInfoPanel(workbench: workbench.current, session: currentSession)
            .layerBar(edge: .top) {
              HStack {
                Text("Chat info").font(.headline)
                Spacer()
                Button { toggleInfo() } label: {
                  Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("Close chat info")
              }
              .padding(.horizontal, 14)
            }
            .frame(width: min(320, max(240, geometry.size.width * 0.35)))
            .transition(.move(edge: .trailing))
        }
      }
    }
  }

  private var appsContent: some View {
    AppsView(model: apps)
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button { show(.conversation) } label: {
            Label("Back to conversation", systemImage: "bubble.left")
          }
          RequestsBell(phone: workbench, open: { showingRequests = true })
        }
      }
  }

  private func toggleInfo() {
    withAnimation(reduceMotion ? nil : .snappy) { showingInfo.toggle() }
  }

  private func openApps() {
    guard usesAppsPane else { settings = .apps; return }
    workbench.retirePendingSend()
    keepInterruptedVoice()
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    settings = nil
    detail = .apps
  }

  private var conversation: some View {
    ConversationView(
      phone: workbench,
      workbench: workbench.current,
      session: currentSession,
      showSidebar: {
        if horizontalSizeClass == .regular {
          splitVisibility = splitVisibility == .detailOnly ? .all : .detailOnly
        } else {
          show(.chats)
        }
      },
      voice: voice,
      showApps: openApps,
      showRequests: detail == .conversation && (horizontalSizeClass == .regular || layer == .conversation)
        ? { showingRequests = true } : nil,
      showInfo: horizontalSizeClass == .regular ? { toggleInfo() } : nil,
      presented: detail == .conversation
    )
    .id(currentSession?.sessionId)
  }

  private func keepInterruptedVoice() {
    voice?.interrupt()
    guard let voice, let transcript = voice.transcript, let destination = transcript.destination,
      voice.consume(transcript) else { return }
    workbench.setDraft(transcript.appending(to: workbench.draft(for: destination)), for: destination)
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
        if !menuEntries.isEmpty { groupedChats }
        if menuEntries.isEmpty {
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

  private var selectedChatKey: ChatMenuEntry.Key? {
    guard let selection = workbench.selection, let session = selection.session else { return nil }
    return .init(host: selection.host, session: session)
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
      let limit = section.group == .earlier && !showingAllEarlier ? settings.earlierLimit : nil
      let visible = ChatGrouping.visible(section.chats, folded: folded, limit: limit, keeping: selectedChatKey)
      items += visible.map { .chat($0, pinned: section.group == .pinned) }
      if !folded, limit != nil, section.chats.count > visible.count {
        items.append(.more("Show \(section.chats.count - visible.count) more", showAll: true))
      } else if !folded, section.group == .earlier, showingAllEarlier, let limit = settings.earlierLimit, section.chats.count > limit {
        items.append(.more("Show fewer", showAll: false))
      }
    }
    return items
  }

  private var groupedChats: some View {
    ForEach(groupedItems) { item in
      switch item {
      case .header(let section, let folded, let first): groupHeader(section, folded: folded, first: first)
      case .chat(let entry, let pinned): chatRow(entry, pinned: pinned)
      case .more(let title, let showAll): showMoreButton(title) { showingAllEarlier = showAll }
      }
    }
  }

  /// "Mark all read": every chat seen on this phone at once. Shown only while one has activity
  /// nobody here looked at.
  @ViewBuilder private var markAllRead: some View {
    let all = ChatMenu.recent(hosts: workbench.hosts.hosts, sessionsOf: workbench.sessions(of:))
    let unseen = all.filter { chatPrefs.seen.isUnseen($0.session) }.count
    if unseen > 0 {
      Button {
        chatPrefs.markAllSeen(all.map(\.session))
        // Seen chats leave Active now, not on the list's next slow regrouping.
        held.groups = liveGroups(now: .now)
      } label: {
        Image(systemName: "checkmark")
          .font(.system(size: 17, weight: .semibold))
          .floatingCircle(diameter: MenuLayout.controlSize)
      }
      .accessibilityLabel("Mark all read")
      .accessibilityValue("\(unseen) \(unseen == 1 ? "chat" : "chats")")
      .accessibilityIdentifier("mark-all-read")
      .transition(.opacity)
    }
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

  /// A chat in the menu, which opens it; a long press pins it to the top, or unpins it.
  private func chatRow(_ entry: ChatMenuEntry, pinned: Bool = false) -> some View {
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
        lastActive: ChatMenu.activity(entry.session),
        hostLabel: workbench.hosts.hosts.count > 1 ? entry.host.label : nil,
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

  private var menuEntries: [ChatMenuEntry] {
    ChatMenu.recent(hosts: workbench.hosts.hosts, sessionsOf: workbench.sessions(of:))
  }

  /// The account and its Macs, under the chats.
  private var accountLayer: some View {
    HostsPanel(
      hosts: workbench.hosts,
      openHost: detail == .apps ? nil : workbench.current?.reference.hostId,
      chatsOf: { workbench.sessions(of: $0).filter { $0.hasAgent != false }.count },
      newChat: { host in
        workbench.select(host: host.hostId, session: nil)
        show(.conversation)
      },
      rename: { host, name in await workbench.renameHost(host.hostId, to: name) },
      pair: { showingPairing = true },
      showApps: openApps,
      showSettings: { settings = .settings },
      refresh: { await workbench.refresh() },
      requests: detail == .conversation && horizontalSizeClass != .regular && layer == .account
        ? RequestsBell(phone: workbench, open: { showingRequests = true }) : nil,
      appsSelected: detail == .apps,
      backToChats: horizontalSizeClass == .regular ? { sidebarShowsHosts = false } : nil)
  }

  /// Moves the stack to `layer`, as a swipe would.
  private func show(_ layer: Layer) {
    if layer == .conversation {
      detail = .conversation
      appsPath = []
      if let currentSession { chatPrefs.markSeen(currentSession) }
    }
    if horizontalSizeClass == .regular, layer == .account || layer == .chats {
      withAnimation(reduceMotion ? nil : .snappy) { sidebarShowsHosts = layer == .account }
      return
    }
    withAnimation(reduceMotion ? nil : .interpolatingSpring(duration: 0.42, bounce: 0.08)) { self.layer = layer }
  }

  private var menuHeader: some View {
    HStack(spacing: 6) {
      OwnMascotView(loading: workbench.hosts.phase == .loading)
        .frame(maxWidth: 34).frame(height: 34)
      Spacer(minLength: 0)
      // The account and its Macs are also one more swipe to the right.
      Button {
        show(.account)
      } label: {
        Image(systemName: "person.crop.circle")
          .font(.system(size: 20, weight: .medium))
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel("Account and \(HostPresentation.collectionName(workbench.hosts.hosts))")
      Button {
        showingSearch = true
      } label: {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 19, weight: .medium))
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel("Search chats")
      .keyboardShortcut("k", modifiers: .command)
      if detail == .conversation, horizontalSizeClass != .regular, layer == .chats {
        RequestsBell(phone: workbench, open: { showingRequests = true })
      }
    }
    .buttonStyle(.plain)
    .padding(.leading, 16)
    .padding(.trailing, 12)
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
      .keyboardShortcut("n", modifiers: .command)

      Spacer(minLength: 0)

      markAllRead

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
    .padding(.leading, UIDevice.current.userInterfaceIdiom == .pad ? 12 : MenuLayout.contentLeading)
    .padding(.trailing, UIDevice.current.userInterfaceIdiom == .pad ? 12 : MenuLayout.contentTrailing)
    .padding(.top, 10)
  }
}

/// A chat in the menu: its name, with a filled row behind the open one.
private struct SessionRow: View {
  let workbench: PhoneWorkbench
  let selection: PhoneWorkbench.Selection
  let name: String
  let status: RemoteSessionStatus?
  /// When the chat was last active, shown as a short age in the recent list; nil in folders.
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
      .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var spokenValue: String {
    let age = lastActive.map { $0.formatted(.relative(presentation: .named)) }
    let host = hostLabel.map { "on \($0)" }
    return [isSelected ? "Selected" : "", pinned ? "Pinned" : "", unseen != nil ? "Unseen" : "", host ?? "", SessionStatusDot.spoken(shownStatus), age ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
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
      Circle().fill(Color.red).frame(width: 8, height: 8)
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
  let requests: RequestsBell?
  var appsSelected = false
  var backToChats: (() -> Void)? = nil

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
        Text(HostPresentation.collectionName(hosts.hosts))
          .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
          .padding(.leading, MenuLayout.rowInset + MenuLayout.rowTextInset)
          .padding(.bottom, 4)
          .accessibilityAddTraits(.isHeader)
        if hosts.hosts.isEmpty {
          Text(hosts.phase == .loading ? "Loading…" : "No hosts yet. Pair one to chat with it from here.")
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
          .accessibilityAddTraits(appsSelected ? .isSelected : [])
          .background {
            if appsSelected {
              RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06))
            }
          }
        }
        .buttonStyle(.layerRow)
        .padding(.horizontal, MenuLayout.rowInset)
      }
      .padding(.bottom, 12)
    }
    .scrollIndicators(.hidden)
    .softLayerEdges()
    .accessibilityIdentifier("hosts-panel")
    .refreshable { await Task { await refresh() }.value }
    .alert(
      renaming.map { HostPresentation.isKnownMac($0) ? "Rename Mac" : "Rename host" } ?? "Rename host",
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
      Text("Shown on every device of this account. Leave it empty for the machine’s own name.")
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
      // Conversations are to the right, both in the compact layers and the iPad sidebar.
      HStack {
        Text(backToChats == nil ? "Account" : HostPresentation.collectionName(hosts.hosts)).font(.title3.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 0)
        if let requests { requests }
        if let backToChats {
          Button(action: backToChats) {
            Image(systemName: "chevron.right").frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Back to chats")
        }
      }
      .frame(minHeight: 44)
      .padding(.leading, MenuLayout.contentLeading)
      .padding(.trailing, 12)
    }
    .layerBar(edge: .bottom) {
      HStack(spacing: 16) {
        // Where the chats have their Chat button: the way to add what this layer lists.
        Button(action: pair) {
          Label(HostPresentation.collectionName(hosts.hosts) == "Macs" ? "Pair a Mac" : "Pair a host", systemImage: "plus")
            .font(.headline)
            .frame(minHeight: MenuLayout.controlSize)
            .padding(.horizontal, 11)
            .background(Color.primary, in: Capsule())
            .foregroundStyle(ChatColors.background)
        }
        .accessibilityLabel(HostPresentation.collectionName(hosts.hosts) == "Macs" ? "Pair a Mac" : "Pair a host")
        Spacer(minLength: 0)
        Button(action: showSettings) {
          Image(systemName: "gearshape")
            .font(.system(size: 19, weight: .medium))
            .floatingCircle(diameter: MenuLayout.controlSize)
        }
        .accessibilityLabel("Settings")
      }
      .buttonStyle(.plain)
      .padding(.leading, UIDevice.current.userInterfaceIdiom == .pad ? 12 : MenuLayout.contentLeading)
      .padding(.trailing, UIDevice.current.userInterfaceIdiom == .pad ? 12 : MenuLayout.contentTrailing)
      .padding(.top, 10)
    }
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
      Image(systemName: host.symbol)
        .font(.system(size: 17))
        .accessibilityLabel(host.model?.name ?? "Mac")
        .accessibilityIdentifier("host-symbol-\(host.symbol)")
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
  /// opens their chats, takes key presses, and refuses prompts to a
  /// chat whose agent is idle (there is no agent behind it). A chat listed as working takes them,
  /// queued in its log, as a busy Pi does (RFD0033); every chat lists its Pi's commands and
  /// models, switches them, and restarts.
  private struct PreviewTransport: AxoTransport {
    func connect() async throws -> any AxoMessageChannel { PreviewChannel() }
  }

  private final class PreviewChannel: AxoMessageChannel, @unchecked Sendable {
    let messages: AsyncStream<Data>
    private let sink: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    /// Each chat's last cursor, for the records written here.
    private var cursors: [String: Int] = [:]

    init() { (messages, sink) = AsyncStream.makeStream() }

    /// A prompt to a working chat, written to its log as queued.
    private func queue(_ params: [String: Any]?) -> Bool {
      // The first chat is the one listed as working.
      guard let params, let session = params["sessionId"] as? String, let id = SessionID(rawValue: session),
        PreviewFixture.number(of: id) == 1
      else { return false }
      let data: [String: Any] = [
        "commandId": params["commandId"] ?? "", "delivery": params["delivery"] ?? "followUp", "text": params["text"] ?? "",
        "attachments": [],
      ]
      let cursor = lock.withLock {
        let next = (cursors[session] ?? PreviewFixture.records(for: id).count) + 1
        cursors[session] = next
        return next
      }
      let entry: [String: Any] = ["type": "custom", "id": "q\(cursor)", "customType": "axo.command.queued", "data": data]
      let line = String(data: try! JSONSerialization.data(withJSONObject: entry), encoding: .utf8)!
      let record: [String: Any] = [
        "cursor": cursor, "id": "q\(cursor)", "format": "pi/3", "line": line, "hash": "sha256:" + String(repeating: "0", count: 64),
      ]
      notify("axo.client.session.records", ["sessionId": session, "epoch": 1, "records": [record], "cursor": cursor])
      return true
    }

    /// Lists a chat again, going away and coming back, as a restart does.
    private func restart(_ params: [String: Any]?) {
      guard let session = params?["sessionId"] as? String, let number = SessionID(rawValue: session).flatMap(PreviewFixture.number(of:))
      else { return }
      Task { [weak self] in
        for (pause, status) in [(0.6, "unavailable"), (1.2, "starting"), (1.5, "ready")] {
          try? await Task.sleep(for: .seconds(pause))
          guard let self, let listed = PreviewFixture.session(number, status: status) else { return }
          let json = #"{"hostId":"\#(listed.host.uuidString.lowercased())","sessions":[\#(listed.json)]}"#
          self.sink.yield(Data(#"{"jsonrpc":"2.0","method":"axo.client.sessions","params":\#(json)}"#.utf8))
        }
      }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
      let notice: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
      sink.yield(try! JSONSerialization.data(withJSONObject: notice))
    }

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
          case "axo.remote.session.key": #"{"accepted":true}"#
          case "axo.remote.session.stop": #"{"stopped":true}"#
          case "axo.remote.session.prompt": queue(params?["params"] as? [String: Any]) ? #"{"accepted":true}"# : nil
          case "axo.remote.session.commands": PreviewFixture.commands
          case "axo.remote.session.models": PreviewFixture.models
          case "axo.remote.session.model.set": #"{"saved":true}"#
          case "axo.remote.session.restart":
            { restart(params?["params"] as? [String: Any]); return #"{"restarted":true}"# }()
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

#if DEBUG && targetEnvironment(simulator)
  extension WorkbenchView {
    /// Thirty long replies, ten a second, into the chat on screen.
    fileprivate func playFlood() {
      guard let current = workbench.current, let id = current.selectedSessionID else { return }
      Task {
        for event in PreviewFixture.floodEvents(replies: 30) {
          current.playForPreview([event], in: id)
          try? await Task.sleep(for: .milliseconds(100))
        }
      }
    }
  }
#endif
