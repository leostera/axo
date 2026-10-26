import AxoClient
import AxoPhoneModel
import AxoProtocol
import SwiftUI

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
  @State private var menuPresented = PreviewFixture.menuOpen
  @State private var menuDragOffset: CGFloat = 0
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

  // The layout, the gesture and its areas of contact are the original app's, unchanged.
  var body: some View {
    GeometryReader { geometry in
      let revealDistance = min(geometry.size.width * MenuLayout.widthFraction, MenuLayout.maximumWidth)
      let foregroundOffset = isCompact
        ? min(max((menuPresented ? revealDistance : 0) + menuDragOffset, 0), revealDistance)
        : 0
      let revealProgress = min(max(foregroundOffset / max(revealDistance, 1), 0), 1)

      ZStack(alignment: .leading) {
        if isCompact {
          sidebar
            .frame(width: revealDistance)
            .frame(maxHeight: .infinity)
            .background(ChatColors.background.ignoresSafeArea())
            .accessibilityHidden(!menuPresented)
        }

        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
          sidebar
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
          conversation
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .accessibilityHidden(isCompact && menuPresented)
        }
        .navigationSplitViewStyle(.balanced)
        .background {
          RoundedRectangle(cornerRadius: MenuLayout.cornerRadius * revealProgress, style: .continuous)
            .fill(ChatColors.background)
            .overlay {
              RoundedRectangle(cornerRadius: MenuLayout.cornerRadius * revealProgress, style: .continuous)
                .fill(ChatColors.surface.opacity(revealProgress))
            }
            .overlay {
              RoundedRectangle(cornerRadius: MenuLayout.cornerRadius * revealProgress, style: .continuous)
                .stroke(Color.primary.opacity(revealProgress * 0.22), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(revealProgress * 0.22), radius: 16, x: -6)
            .ignoresSafeArea()
        }
        .overlay {
          Color(uiColor: .tertiarySystemBackground)
            .opacity(revealProgress * 0.64)
            .allowsHitTesting(isCompact && menuPresented)
            .accessibilityHidden(true)
        }
        .accessibilityHidden(isCompact && menuPresented)
        .offset(x: foregroundOffset)
        .allowsHitTesting(!(isCompact && menuPresented))

        if isCompact && menuPresented {
          Color.clear
            .frame(width: max(geometry.size.width - revealDistance, 0))
            .frame(maxHeight: .infinity)
            .offset(x: revealDistance)
            .contentShape(Rectangle())
            .allowsHitTesting(true)
            .accessibilityHidden(true)
            .zIndex(2)
        }
      }
      .simultaneousGesture(menuGesture(revealDistance: revealDistance))
    }
    .background(ChatColors.background.ignoresSafeArea())
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
      }
    }
  }

  private var conversation: some View {
    ConversationView(
      workbench: workbench.current,
      session: currentSession,
      draft: draftBinding,
      isSending: workbench.isSending,
      showSidebar: showMenu,
      send: { await workbench.send() },
      sendIn: { await workbench.send(in: $0) }
    )
    .id(currentSession?.sessionId)
  }

  /// The open chat's box, kept per chat by the workbench.
  private var draftBinding: Binding<String> {
    guard let selection = workbench.selection else { return .constant("") }
    return Binding(
      get: { workbench.draft(for: selection) },
      set: { workbench.setDraft($0, for: selection) })
  }

  // MARK: - The menu

  private var sidebar: some View {
    VStack(spacing: 0) {
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
                  name: entry.session.displayName)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .padding(.horizontal, MenuLayout.rowInset)
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
    return order.map { MenuSection(id: $0, title: grouped[$0]!.title, sessions: grouped[$0]!.sessions) }
  }

  private var menuHeader: some View {
    HStack(spacing: 12) {
      OwnMascotView(loading: workbench.hosts.phase == .loading)
        .frame(height: 34)
      Spacer(minLength: 8)
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
    withAnimation(menuAnimation) {
      menuPresented = true
      menuDragOffset = 0
    }
  }

  private func closeMenu() {
    if isCompact {
      withAnimation(menuAnimation) {
        menuPresented = false
        menuDragOffset = 0
      }
    } else {
      columnVisibility = .detailOnly
      preferredCompactColumn = .detail
    }
  }

  private var menuAnimation: Animation? {
    reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88)
  }

  private func menuGesture(revealDistance: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { value in
        guard isCompact, abs(value.translation.width) > abs(value.translation.height) else { return }

        if menuPresented {
          menuDragOffset = min(0, max(-revealDistance, value.translation.width))
        } else if value.startLocation.x <= 32, value.translation.width > 0 {
          menuDragOffset = min(revealDistance, value.translation.width)
        }
      }
      .onEnded { value in
        guard isCompact, abs(value.translation.width) > abs(value.translation.height) else {
          menuDragOffset = 0
          return
        }

        withAnimation(menuAnimation) {
          if menuPresented {
            if value.translation.width < -80 { menuPresented = false }
          } else if value.startLocation.x <= 32, value.translation.width > 80 {
            menuPresented = true
          }
          menuDragOffset = 0
        }
      }
  }
}

/// A chat in the menu: its name, with a filled row behind the open one.
private struct SessionRow: View {
  let workbench: PhoneWorkbench
  let selection: PhoneWorkbench.Selection
  let name: String

  // Read here, in the row's own body, so the row redraws when the open chat changes: a lazy
  // stack does not re-run its rows for a change only the menu's body saw.
  private var isSelected: Bool { workbench.selection == selection }

  var body: some View {
    Text(name)
      .font(.callout)
      .lineLimit(1)
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
  }
}

#if DEBUG && targetEnvironment(simulator)
  private struct PreviewListing: HostListing, PiHistoryLoading {
    func hosts() async throws -> [RemoteHost] { PreviewFixture.hosts }
    func piEvents(of host: RemoteHostRef, session: SessionID, before cursor: Int64, limit: Int) async throws -> PiEventPage {
      cursor == 0 ? PiEventPage(events: PreviewFixture.events(for: session).reversed(), next: nil) : PiEventPage(events: [], next: nil)
    }
  }

  /// Answers just enough of the relay for a Mac to open.
  private struct PreviewTransport: AxoTransport {
    func connect() async throws -> any AxoMessageChannel { throw AxoClientError.connectionFailed("preview") }
  }
#endif
