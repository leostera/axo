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
  static let rowHeight: CGFloat = 44
  static let selectedRowVerticalInset: CGFloat = 3
  static let controlSize: CGFloat = 44
}

/// The phone's whole screen: the conversation, with the Macs and their sessions in a menu that
/// the conversation slides aside to show.
struct WorkbenchView: View {
  let environment: AppEnvironment
  @State private var workbench: PhoneWorkbench
  @State private var menuPresented = PreviewFixture.menuOpen
  @State private var menuDragOffset: CGFloat = 0
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

  var body: some View {
    GeometryReader { geometry in
      let reveal = min(geometry.size.width * MenuLayout.widthFraction, MenuLayout.maximumWidth)
      let offset = min(max((menuPresented ? reveal : 0) + menuDragOffset, 0), reveal)
      let progress = min(max(offset / max(reveal, 1), 0), 1)

      ZStack(alignment: .leading) {
        sidebar
          .frame(width: reveal)
          .frame(maxHeight: .infinity)
          .background(ChatColors.background.ignoresSafeArea())
          .accessibilityHidden(!menuPresented)

        ConversationView(workbench: workbench.current, session: currentSession, showSidebar: showMenu)
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
          .clipShape(RoundedRectangle(cornerRadius: MenuLayout.cornerRadius * progress, style: .continuous))
          .overlay {
            Color(uiColor: .tertiarySystemBackground)
              .opacity(progress * 0.64)
              .allowsHitTesting(menuPresented)
              .accessibilityHidden(true)
              .onTapGesture { closeMenu() }
          }
          .accessibilityHidden(menuPresented)
          .offset(x: offset)
          .allowsHitTesting(!menuPresented)

        if menuPresented {
          Color.clear
            .frame(width: max(geometry.size.width - reveal, 0))
            .frame(maxHeight: .infinity)
            .offset(x: reveal)
            .contentShape(Rectangle())
            .onTapGesture { closeMenu() }
            .accessibilityHidden(true)
            .zIndex(2)
        }
      }
      .simultaneousGesture(menuGesture(reveal: reveal))
    }
    .preferredColorScheme(appearance.colorScheme)
    .tint(accentColor.color)
    .sheet(isPresented: $showingSearch) {
      SessionSearchView(hosts: workbench.hosts.hosts) { host, session in
        workbench.select(host: host.hostId, session: session.sessionId)
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
    .task { await workbench.start() }
  }

  // MARK: - The menu

  private var sidebar: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        OwnMascotView(loading: workbench.hosts.phase == .loading)
          .frame(height: 34)
        Spacer(minLength: 8)
        Button { showingSearch = true } label: {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 19, weight: .medium))
            .frame(width: MenuLayout.controlSize, height: MenuLayout.controlSize)
            .background(Color.primary.opacity(0.08), in: Circle())
            .overlay { Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search sessions")
      }
      .padding(.leading, MenuLayout.contentLeading)
      .padding(.trailing, MenuLayout.contentTrailing)
      .frame(minHeight: 56)
      .background(ChatColors.background)

      List {
        if case .failed(let message) = workbench.hosts.phase {
          Text(message).font(.caption).foregroundStyle(.orange)
        }
        ForEach(workbench.hosts.hosts, id: \.hostId) { host in
          hostSection(host)
        }
        if workbench.hosts.hosts.isEmpty, workbench.hosts.phase == .loaded {
          ContentUnavailableView(
            "No Macs yet", systemImage: "laptopcomputer",
            description: Text("On a Mac, open Axo → Settings → Remote Access and link it with a pairing code."))
        }
      }
      .listStyle(.plain)
      .environment(\.defaultMinListRowHeight, 1)
      .scrollContentBackground(.hidden)
      .background(ChatColors.background)
      .refreshable { await workbench.refresh() }
    }
    .background(ChatColors.background.ignoresSafeArea())
    .safeAreaInset(edge: .bottom, spacing: 0) { menuFooter }
  }

  private func hostSection(_ host: RemoteHost) -> some View {
    Section {
      if host.sessions.isEmpty {
        Text("No sessions yet").font(.subheadline).foregroundStyle(.secondary)
      }
      ForEach(sortedSessions(of: host), id: \.sessionId) { session in
        sessionButton(session, on: host)
      }
    } header: {
      hostHeader(host)
    }
  }

  private func sortedSessions(of host: RemoteHost) -> [RemoteSession] {
    host.sessions.sorted { $0.sessionId < $1.sessionId }
  }

  private func sessionButton(_ session: RemoteSession, on host: RemoteHost) -> some View {
    let selected = workbench.selection == PhoneWorkbench.Selection(host: host.hostId, session: session.sessionId)
    return Button {
      workbench.select(host: host.hostId, session: session.sessionId)
      closeMenu()
    } label: {
      SessionRow(session: session, isSelected: selected)
    }
    .buttonStyle(.plain)
    .listRowInsets(EdgeInsets(top: 0, leading: MenuLayout.rowInset, bottom: 0, trailing: MenuLayout.rowInset))
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }

  private func hostHeader(_ host: RemoteHost) -> some View {
    let dot: Color = host.status == .online ? .green : Color.secondary.opacity(0.5)
    return HStack(spacing: 8) {
      Circle().fill(dot).frame(width: 8, height: 8)
      Text(host.label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).textCase(nil)
    }
    .padding(.leading, 16)
  }

  private var menuFooter: some View {
    HStack(spacing: 16) {
      Button {
        Task {
          // Stay in the menu when the Mac refuses, where the reason is shown.
          if await workbench.startChat() { closeMenu() }
        }
      } label: {
        Label("Chat", systemImage: "square.and.pencil")
          .font(.headline)
          .frame(minHeight: MenuLayout.controlSize)
          .padding(.horizontal, 11)
          .background(Color.primary, in: Capsule())
          .foregroundStyle(ChatColors.background)
      }
      .disabled(workbench.newChatHost == nil)
      .opacity(workbench.newChatHost == nil ? 0.4 : 1)
      .accessibilityLabel("New chat")

      Spacer(minLength: 0)

      Button { showingSettings = true } label: {
        Image(systemName: "gearshape")
          .font(.system(size: 19, weight: .medium))
          .frame(width: MenuLayout.controlSize, height: MenuLayout.controlSize)
          .background { Circle().fill(Color.primary.opacity(0.08)).padding(1) }
          .overlay { Circle().inset(by: 1).stroke(Color.primary.opacity(0.12), lineWidth: 0.5) }
      }
      .accessibilityLabel("Settings")
    }
    .buttonStyle(.plain)
    .padding(.leading, MenuLayout.contentLeading)
    .padding(.trailing, MenuLayout.contentTrailing)
    .padding(.top, 10)
    .background(ChatColors.background)
    .overlay(alignment: .top) { menuFailure }
  }

  /// Why a chat could not be started or a Mac could not be reached, where the menu's own buttons are.
  @ViewBuilder private var menuFailure: some View {
    if let failure = workbench.current?.failure {
      Text(failure)
        .font(.caption).foregroundStyle(.orange)
        .padding(.horizontal, MenuLayout.contentLeading)
        .offset(y: -22)
    }
  }

  private func showMenu() {
    withAnimation(menuAnimation) {
      menuPresented = true
      menuDragOffset = 0
    }
  }

  private func closeMenu() {
    withAnimation(menuAnimation) {
      menuPresented = false
      menuDragOffset = 0
    }
  }

  private var menuAnimation: Animation? {
    reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88)
  }

  private func menuGesture(reveal: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { value in
        guard abs(value.translation.width) > abs(value.translation.height) else { return }
        if menuPresented {
          menuDragOffset = min(0, max(-reveal, value.translation.width))
        } else if value.startLocation.x <= 32, value.translation.width > 0 {
          menuDragOffset = min(reveal, value.translation.width)
        }
      }
      .onEnded { value in
        guard abs(value.translation.width) > abs(value.translation.height) else {
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

private struct SessionRow: View {
  let session: RemoteSession
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 8) {
      Text(session.emoji ?? "").frame(width: session.emoji == nil ? 0 : 22)
      Text(session.displayName).font(.body).lineLimit(1)
      Spacer(minLength: 0)
      if session.status == .working { ProgressView().controlSize(.small) }
      if session.status == .needsAttention { Circle().fill(.orange).frame(width: 8, height: 8) }
    }
    .padding(.horizontal, MenuLayout.rowTextInset)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: MenuLayout.rowHeight)
    .contentShape(Rectangle())
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
          .fill(Color(uiColor: .tertiarySystemBackground))
          .padding(.vertical, MenuLayout.selectedRowVerticalInset)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(session.displayName)
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
