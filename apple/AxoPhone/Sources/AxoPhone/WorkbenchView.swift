import AxoClient
import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// Which panel slides out: none, the chats, or (one more swipe) the account and its Macs.
private enum MenuLevel { case closed, chats, hosts }

// Proportions measured from the original sidebar reference on a compact phone.
private enum MenuLayout {
  static let widthFraction: CGFloat = 0.79
  static let maximumWidth: CGFloat = 360
  static let cornerRadius: CGFloat = 42
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

/// The phone's whole screen: the conversation, with the Macs and their sessions in a menu that
/// the conversation slides aside to show.
struct WorkbenchView: View {
  let environment: AppEnvironment
  @State private var workbench: PhoneWorkbench
  @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
  /// Which panel slides out: closed, the chats, or (one more swipe) the account and its Macs.
  @State private var menuLevel: MenuLevel = PreviewFixture.hostsOpen ? .hosts : PreviewFixture.menuOpen ? .chats : .closed
  /// The panel last shown; it stays while the menu closes, so closing does not swap panels.
  @State private var openPanel: MenuLevel = PreviewFixture.hostsOpen ? .hosts : .chats
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var showingSettings = PreviewFixture.settingsOpen
  @State private var showingSearch = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("appearance") private var appearance: AppAppearance = .system
  @AppStorage("accentColor") private var accentColor: AppAccentColor = .white

  init(environment: AppEnvironment) {
    self.environment = environment
    let account = environment.account
    let endpoint = environment.endpoint
    let client = AccountClient(endpoint: endpoint, tokens: account.tokens)
    #if DEBUG && targetEnvironment(simulator)
      if PreviewFixture.requested {
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

  private var isCompact: Bool { horizontalSizeClass == .compact }


  // The layout, the gesture and its areas of contact are the original app's, unchanged. The
  // sliding is `SlidingMenu`'s alone: it re-runs on every frame of a drag, and what it moves,
  // built here, is not rebuilt.
  var body: some View {
    let _ = RenderCount.note("Workbench")
    SlidingMenu(
      level: isCompact ? menuLevel : .closed,
      enabled: isCompact,
      animation: menuAnimation,
      show: show,
      close: closeMenu,
      panel: { menuPanel }
    ) {
      NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
        // On a compact screen the menu is the sliding panel; a second copy here would sit
        // hidden under the conversation, where VoiceOver and taps could still find it.
        Group {
          if isCompact { Color.clear } else { menuPanel }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 300)
      } detail: {
        conversation
          .navigationBarBackButtonHidden(true)
          .toolbar(.hidden, for: .navigationBar)
      }
      .navigationSplitViewStyle(.balanced)
    }
    .background(ChatColors.background.ignoresSafeArea())
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
        preferredCompactColumn = .detail
        closeMenu()
      }
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
      let chats = sections.flatMap(\.sessions)
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
    .onChange(of: scenePhase) { previous, phase in
      // A socket left open in the background dies unnoticed; let it go, and come back fresh.
      switch phase {
      case .background: workbench.suspend()
      case .active where previous == .background: Task { await workbench.resume() }
      default: break
      }
    }
  }

  private var conversation: some View {
    ConversationView(
      phone: workbench,
      workbench: workbench.current,
      session: currentSession,
      showSidebar: showMenu
    )
    .id(currentSession?.sessionId)
  }

  // MARK: - The menu

  private var sidebar: some View {
    RenderCount.note("Menu")
    return VStack(spacing: 0) {
      menuHeader
      // A plain stack rather than a List: List's section headers and row minimums are far
      // taller than a menu of chat names needs.
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if case .failed(let message) = workbench.hosts.phase {
            Text(message).font(.caption).foregroundStyle(.orange)
              .padding(.horizontal, MenuLayout.rowInset + MenuLayout.rowTextInset)
          }
          ForEach(sections) { section in
            Text(section.title)
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .padding(.leading, MenuLayout.rowInset + MenuLayout.rowTextInset)
              .padding(.trailing, MenuLayout.rowInset)
              .padding(.top, section.id == sections.first?.id ? 4 : MenuLayout.sectionTopSpacing)
              .padding(.bottom, 2)
              .accessibilityAddTraits(.isHeader)
            ForEach(section.sessions, id: \.session.sessionId) { entry in
              Button {
                workbench.select(host: entry.host.hostId, session: entry.session.sessionId)
                preferredCompactColumn = .detail
                closeMenu()
              } label: {
                SessionRow(
                  workbench: workbench,
                  selection: PhoneWorkbench.Selection(host: entry.host.hostId, session: entry.session.sessionId),
                  name: entry.session.displayName,
                  status: entry.session.status)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .padding(.horizontal, MenuLayout.rowInset)
            }
            if section.sessions.isEmpty {
              Text("No chats yet")
                .font(.callout).foregroundStyle(.tertiary)
                .padding(.horizontal, MenuLayout.rowInset + MenuLayout.rowTextInset)
                .frame(height: MenuLayout.rowHeight)
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
      .background(ChatColors.background)
      .refreshable { await workbench.refresh() }
      .accessibilityIdentifier("workbench-menu")
    }
    .background(ChatColors.background.ignoresSafeArea())
    .safeAreaInset(edge: .bottom, spacing: 0) { menuFooter }
    .toolbar(.hidden, for: .navigationBar)
  }

  private struct Entry {
    let host: RemoteHost
    let session: RemoteSession
  }

  private struct MenuSection: Identifiable {
    let id: String
    let title: String
    let sessions: [Entry]
  }

  /// The chats, grouped as the original menu grouped them: by Workspace. Bare terminals have no
  /// chat in them and are not listed. With several Macs, a Workspace's Mac is named in its title.
  private var sections: [MenuSection] {
    let hosts = workbench.hosts.hosts
    var order: [String] = []
    var grouped: [String: (title: String, sessions: [Entry])] = [:]
    for host in hosts {
      for session in workbench.sessions(of: host).sorted(by: { $0.sessionId < $1.sessionId })
      where session.hasAgent != false {
        let workspace = session.workspaceName ?? "Chats"
        let key = "\(host.hostId.uuidString)/\(workspace)"
        if grouped[key] == nil {
          order.append(key)
          grouped[key] = (hosts.count > 1 ? "\(workspace) · \(host.label)" : workspace, [])
        }
        grouped[key]!.sessions.append(Entry(host: host, session: session))
      }
    }
    // The open Mac's Workspaces with no chats in them yet are listed too, so a new chat's place
    // is visible before it exists.
    if let current = workbench.current, let host = hosts.first(where: { $0.hostId == current.reference.hostId }) {
      for workspace in current.workspaceList {
        let key = "\(host.hostId.uuidString)/\(workspace.name)"
        if grouped[key] == nil {
          order.append(key)
          grouped[key] = (hosts.count > 1 ? "\(workspace.name) · \(host.label)" : workspace.name, [])
        }
      }
    }
    return order.map { MenuSection(id: $0, title: grouped[$0]!.title, sessions: grouped[$0]!.sessions) }
  }

  /// The chats menu, or one swipe further, the account and its Macs.
  @ViewBuilder private var menuPanel: some View {
    ZStack {
      if openPanel == .hosts {
        HostsPanel(
          hosts: workbench.hosts,
          openHost: workbench.current?.reference.hostId,
          chatsOf: { workbench.sessions(of: $0).filter { $0.hasAgent != false }.count },
          back: { withAnimation(menuAnimation) { show(.chats) } },
          newChat: { host in
            workbench.select(host: host.hostId, session: nil)
            preferredCompactColumn = .detail
            closeMenu()
          },
          showSettings: { showingSettings = true },
          refresh: { await workbench.refresh() })
          .transition(.move(edge: .leading).combined(with: .opacity))
      } else {
        sidebar
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .clipped()
  }

  /// Opens `level`, or closes the menu; a closing menu keeps the panel it showed.
  private func show(_ level: MenuLevel) {
    menuLevel = level
    if level != .closed { openPanel = level }
  }

  private var menuHeader: some View {
    HStack(spacing: 12) {
      OwnMascotView(loading: workbench.hosts.phase == .loading)
        .frame(height: 34)
      Spacer(minLength: 8)
      // The account and its Macs are also one more swipe to the right.
      Button {
        withAnimation(menuAnimation) { show(.hosts) }
      } label: {
        Image(systemName: "person.crop.circle")
          .font(.system(size: 20, weight: .medium))
          .frame(width: 44, height: 44)
          .background(Color.primary.opacity(0.08), in: Circle())
          .overlay { Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5) }
      }
      .accessibilityLabel("Account and Macs")
      Button {
        showingSearch = true
      } label: {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 19, weight: .medium))
          .frame(width: 44, height: 44)
          .background(Color.primary.opacity(0.08), in: Circle())
          .overlay {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
          }
      }
      .accessibilityLabel("Search chats")
    }
    .buttonStyle(.plain)
    .padding(.leading, MenuLayout.contentLeading)
    .padding(.trailing, MenuLayout.contentTrailing)
    .padding(.top, 0)
    .padding(.bottom, 0)
    .background(ChatColors.background)
  }

  private var menuFooter: some View {
    HStack(spacing: 16) {
      Button {
        workbench.beginNewChat()
        preferredCompactColumn = .detail
        closeMenu()
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
          .frame(width: MenuLayout.controlSize, height: MenuLayout.controlSize)
          .background {
            Circle()
              .fill(Color.primary.opacity(0.08))
              .padding(1)
          }
          .overlay {
            Circle()
              .inset(by: 1)
              .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
          }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Settings")
    }
    .buttonStyle(.plain)
    .padding(.leading, MenuLayout.contentLeading)
    .padding(.trailing, MenuLayout.contentTrailing)
    .padding(.top, 10)
    .padding(.bottom, 0)
    .background(ChatColors.background)
  }

  private func showMenu() {
    guard isCompact else {
      columnVisibility = .all
      preferredCompactColumn = .sidebar
      return
    }
    withAnimation(menuAnimation) { show(.chats) }
  }

  private func closeMenu() {
    if isCompact {
      withAnimation(menuAnimation) { show(.closed) }
    } else {
      columnVisibility = .detailOnly
      preferredCompactColumn = .detail
    }
  }

  private var menuAnimation: Animation? {
    reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88)
  }
}

/// The conversation, slid aside to show the menu under it. This alone follows the finger: it
/// re-runs on every frame of a drag, while `panel` and `content`, built by its parent, are the
/// same values each time and are not redrawn.
private struct SlidingMenu<Panel: View, Content: View>: View {
  /// What is open; always `.closed` on a wide screen, where the menu is a column instead.
  let level: MenuLevel
  /// A wide screen has the menu as a column, and nothing to slide.
  let enabled: Bool
  let animation: Animation?
  let show: (MenuLevel) -> Void
  let close: () -> Void
  @ViewBuilder let panel: Panel
  @ViewBuilder let content: Content
  @State private var dragOffset: CGFloat = 0

  private var presented: Bool { level != .closed }

  var body: some View {
    let _ = RenderCount.note("Sliding")
    GeometryReader { geometry in
      let revealDistance = min(geometry.size.width * MenuLayout.widthFraction, MenuLayout.maximumWidth)
      let offset = min(max((presented ? revealDistance : 0) + dragOffset, 0), revealDistance)
      let progress = min(max(offset / max(revealDistance, 1), 0), 1)

      ZStack(alignment: .leading) {
        // Only there while it shows (or is being dragged into view): a closed menu left under
        // the conversation would still answer taps and VoiceOver where the conversation is.
        if presented || offset > 0 {
          panel
            .frame(width: revealDistance)
            .frame(maxHeight: .infinity)
            .background(ChatColors.background.ignoresSafeArea())
            .accessibilityHidden(!presented)
            // Above the content: its hidden navigation bars stay where they were when the
            // conversation slides aside, and would take taps meant for the top of the menu.
            .zIndex(1)
        }

        content
          .background {
            RoundedRectangle(cornerRadius: MenuLayout.cornerRadius * progress, style: .continuous)
              .fill(ChatColors.background)
              .overlay {
                RoundedRectangle(cornerRadius: MenuLayout.cornerRadius * progress, style: .continuous)
                  .fill(ChatColors.surface.opacity(progress))
              }
              .overlay {
                RoundedRectangle(cornerRadius: MenuLayout.cornerRadius * progress, style: .continuous)
                  .stroke(Color.primary.opacity(progress * 0.22), lineWidth: 0.5)
              }
              .shadow(color: .black.opacity(progress * 0.22), radius: 16, x: -6)
              .ignoresSafeArea()
          }
          .overlay {
            Color(uiColor: .tertiarySystemBackground)
              .opacity(progress * 0.64)
              .allowsHitTesting(presented)
              .accessibilityHidden(true)
          }
          .accessibilityHidden(presented)
          .offset(x: offset)
          .allowsHitTesting(!presented)

        if presented {
          // The slice of conversation still showing: a tap there closes the menu. Its shape is set
          // before it moves: set after `offset`, it stays where the view was laid out, over the
          // menu's left edge, and swallows taps on the menu's buttons there.
          Color.clear
            .frame(width: max(geometry.size.width - revealDistance, 0))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .offset(x: revealDistance)
            .accessibilityHidden(true)
            .zIndex(2)
        }
      }
      .simultaneousGesture(gesture(revealDistance: revealDistance))
    }
  }

  private func gesture(revealDistance: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { value in
        guard enabled, abs(value.translation.width) > abs(value.translation.height) else { return }
        switch level {
        case .chats:
          // Left closes the menu (the conversation follows the finger); right goes on to the Macs.
          dragOffset = min(0, max(-revealDistance, value.translation.width))
        case .hosts:
          dragOffset = 0
        case .closed:
          if value.startLocation.x <= 32, value.translation.width > 0 {
            dragOffset = min(revealDistance, value.translation.width)
          }
        }
      }
      .onEnded { value in
        guard enabled, abs(value.translation.width) > abs(value.translation.height) else {
          dragOffset = 0
          return
        }
        withAnimation(animation) {
          switch level {
          case .chats:
            if value.translation.width < -80 { show(.closed) }
            else if value.translation.width > 80 { show(.hosts) }
          case .hosts:
            if value.translation.width < -80 { show(.chats) }
          case .closed:
            if value.startLocation.x <= 32, value.translation.width > 80 { show(.chats) }
          }
          dragOffset = 0
        }
      }
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

/// One swipe past the chats: who is signed in, and their Macs.
private struct HostsPanel: View {
  let hosts: HostsModel
  let openHost: UUID?
  let chatsOf: (RemoteHost) -> Int
  let back: () -> Void
  let newChat: (RemoteHost) -> Void
  let showSettings: () -> Void
  let refresh: () async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        Button(action: back) {
          Image(systemName: "chevron.left")
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
            .background(Color.primary.opacity(0.08), in: Circle())
        }
        .accessibilityLabel("Back to chats")
        Text("Account").font(.title3.weight(.semibold))
        Spacer(minLength: 0)
      }
      .buttonStyle(.plain)
      .padding(.leading, MenuLayout.contentLeading - 8)
      .padding(.trailing, MenuLayout.contentTrailing)

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
            Text(hosts.phase == .loading
              ? "Loading…"
              : "No Macs yet. On a Mac, open Axo → Settings → Remote Access and link it with a pairing code.")
              .font(.callout).foregroundStyle(.secondary)
              .padding(.horizontal, MenuLayout.rowInset + MenuLayout.rowTextInset)
          }
          ForEach(hosts.hosts, id: \.hostId) { host in
            Button { newChat(host) } label: { HostRow(host: host, chats: chatsOf(host), isOpen: host.hostId == openHost) }
              .buttonStyle(.plain)
              .disabled(host.status != .online)
              .padding(.horizontal, MenuLayout.rowInset)
              .accessibilityHint(host.status == .online ? "Starts a new chat on this Mac" : "")
          }
        }
        .padding(.bottom, 12)
      }
      .scrollIndicators(.hidden)
      .refreshable { await refresh() }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ChatColors.background.ignoresSafeArea())
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        Spacer(minLength: 0)
        Button(action: showSettings) {
          Image(systemName: "gearshape")
            .font(.system(size: 19, weight: .medium))
            .frame(width: MenuLayout.controlSize, height: MenuLayout.controlSize)
            .background(Circle().fill(Color.primary.opacity(0.08)).padding(1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
      }
      .padding(.leading, MenuLayout.contentLeading)
      .padding(.trailing, MenuLayout.contentTrailing)
      .padding(.top, 10)
      .background(ChatColors.background)
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
  private struct PreviewListing: HostListing, PiHistoryLoading {
    func hosts() async throws -> [RemoteHost] { PreviewFixture.hosts }
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
          #"{"workspaces":[{"workspaceId":"\#(UUID().uuidString)","name":"Axo"},{"workspaceId":"\#(UUID().uuidString)","name":"Website"}]}"#
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
