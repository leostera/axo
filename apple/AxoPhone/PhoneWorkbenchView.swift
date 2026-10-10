import AxoCore
import SwiftUI

// Proportions measured from the supplied sidebar reference on a compact phone.
private enum SessionMenuLayout {
    static let sidebarWidthFraction: CGFloat = 0.79
    static let maximumSidebarWidth: CGFloat = 360
    static let foregroundCornerRadius: CGFloat = 42
    static let contentLeading: CGFloat = 32
    static let contentTrailing: CGFloat = 24
    static let rowInset: CGFloat = 10
    static let rowTextInset: CGFloat = 22
    static let rowHeight: CGFloat = 44
    static let selectedRowVerticalInset: CGFloat = 3
    static let controlSize: CGFloat = 44
}

@MainActor
struct PhoneWorkbenchView: View {
    @State private var model = PhoneWorkbenchState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var isSessionMenuPresented = false
    @State private var menuDragOffset: CGFloat = 0
    @State private var previewDraft = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage("accentColor") private var accentColor: AppAccentColor = .white

    private var previewConversationTitle: String {
        #if DEBUG
        ChatPreviewData.enabled ? "Axo" : "New session"
        #else
        "New session"
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            let revealDistance = min(
                geometry.size.width * SessionMenuLayout.sidebarWidthFraction,
                SessionMenuLayout.maximumSidebarWidth
            )
            let foregroundOffset = horizontalSizeClass == .compact
                ? min(max((isSessionMenuPresented ? revealDistance : 0) + menuDragOffset, 0), revealDistance)
                : 0
            let revealProgress = min(max(foregroundOffset / max(revealDistance, 1), 0), 1)

            ZStack(alignment: .leading) {
                if horizontalSizeClass == .compact {
                    sidebar
                        .frame(width: revealDistance)
                        .frame(maxHeight: .infinity)
                        .background(ChatColors.background.ignoresSafeArea())
                        .accessibilityHidden(!isSessionMenuPresented)
                }

                NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 260, ideal: 300)
                } detail: {
                    detail
                        .navigationBarBackButtonHidden(true)
                        .toolbar(.hidden, for: .navigationBar)
                        .accessibilityHidden(horizontalSizeClass == .compact && isSessionMenuPresented)
                }
                .navigationSplitViewStyle(.balanced)
                .background {
                    RoundedRectangle(
                        cornerRadius: SessionMenuLayout.foregroundCornerRadius * revealProgress,
                        style: .continuous
                    )
                    .fill(ChatColors.background)
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: SessionMenuLayout.foregroundCornerRadius * revealProgress,
                            style: .continuous
                        )
                        .fill(ChatColors.surface.opacity(revealProgress))
                    }
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: SessionMenuLayout.foregroundCornerRadius * revealProgress,
                            style: .continuous
                        )
                        .stroke(Color.primary.opacity(revealProgress * 0.22), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(revealProgress * 0.22), radius: 16, x: -6)
                    .ignoresSafeArea()
                }
                .overlay {
                    Color(uiColor: .tertiarySystemBackground)
                        .opacity(revealProgress * 0.64)
                        .allowsHitTesting(horizontalSizeClass == .compact && isSessionMenuPresented)
                        .accessibilityHidden(true)
                }
                .accessibilityHidden(horizontalSizeClass == .compact && isSessionMenuPresented)
                .offset(x: foregroundOffset)
                .allowsHitTesting(!(horizontalSizeClass == .compact && isSessionMenuPresented))

                if horizontalSizeClass == .compact && isSessionMenuPresented {
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
            .simultaneousGesture(sessionMenuGesture(revealDistance: revealDistance))
        }
        .preferredColorScheme(appearance.colorScheme)
        .tint(accentColor.color)
        .sheet(item: sheetBinding) { sheet in
            switch sheet {
            case .search:
                NavigationStack {
                    PhoneCatalogSearchView(model: model) { item in
                        model.selectSearchResult(item)
                        guard case .conversation = model.route else { return false }
                        model.sheet = nil
                        closeSessionMenu()
                        preferredCompactColumn = .detail
                        return true
                    }
                }
            case .createWorkspace:
                CreateWorkspaceSheet(canCreate: model.canCreate, create: model.createWorkspace)
            case .createSession:
                CreateSessionSheet(workspaces: model.catalog.workspaces, canCreate: model.canCreate, create: model.createSession)
            case .settings:
                PhoneSettingsView()
            }
        }
        .task { model.start() }
        .onChange(of: model.route) { _, route in
            if case .conversation = route {
                preferredCompactColumn = .detail
                closeSessionMenu()
            }
        }
        .onChange(of: model.client.lastAcknowledgedID) { _, id in
            model.acknowledgeSubmittedDraft(id)
        }
    }

    private var sheetBinding: Binding<PhoneWorkbenchState.Sheet?> {
        Binding(get: { model.sheet }, set: { model.sheet = $0 })
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            menuHeader
            List {
                ForEach(model.catalog.workspaces) { workspace in
                    Section {
                        let sessions = model.catalog.sessions(in: workspace.id)
                        if sessions.isEmpty {
                            Text("No sessions yet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(sessions) { session in
                            Button {
                                model.select(.conversation(session.id))
                                preferredCompactColumn = .detail
                                closeSessionMenu()
                            } label: {
                                PhoneSessionRow(session: session, isSelected: isSelected(session))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(
                                top: 0,
                                leading: SessionMenuLayout.rowInset,
                                bottom: 0,
                                trailing: SessionMenuLayout.rowInset
                            ))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .disabled(model.voice.isBusy)
                        }
                    } header: {
                        Text(workspace.kind == .standalone ? "Sessions" : workspace.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .textCase(nil)
                            .padding(.leading, 16)
                    }
                }

                if model.catalog.workspaces.isEmpty {
                    Text(model.isLoadingPage ? "Loading sessions…" : "Your sessions will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let persistenceError = model.persistenceError {
                    Text(persistenceError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let pageError = model.pageError {
                    Text(pageError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let notice = model.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden)
            .background(ChatColors.background)
            .refreshable { await model.reloadCatalog() }
            .accessibilityIdentifier("workbench-menu")
        }
        .background(ChatColors.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { menuFooter }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var menuHeader: some View {
        HStack(spacing: 12) {
            Text("Axo")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("workbench-menu-title")
            Spacer(minLength: 8)
            Button {
                model.sheet = .search
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .overlay {
                        Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    }
            }
            .accessibilityLabel("Search sessions")
            .disabled(model.voice.isBusy)
        }
        .buttonStyle(.plain)
        .padding(.leading, SessionMenuLayout.contentLeading)
        .padding(.trailing, SessionMenuLayout.contentTrailing)
        .padding(.top, 0)
        .padding(.bottom, 0)
        .background(ChatColors.background)
    }

    private var menuFooter: some View {
        HStack(spacing: 16) {
            Menu {
                Button {
                    model.sheet = model.catalog.workspaces.isEmpty ? .createWorkspace : .createSession
                } label: {
                    Label("New session", systemImage: "square.and.pencil")
                }
                Button {
                    model.sheet = .createWorkspace
                } label: {
                    Label("New workspace", systemImage: "folder.badge.plus")
                }
            } label: {
                Label("Session", systemImage: "square.and.pencil")
                    .font(.headline)
                    .frame(minHeight: SessionMenuLayout.controlSize)
                    .padding(.horizontal, 11)
                    .background(Color.primary, in: Capsule())
                    .foregroundStyle(ChatColors.background)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New session")

            Spacer(minLength: 0)

            Button {
                model.sheet = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: SessionMenuLayout.controlSize, height: SessionMenuLayout.controlSize)
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
        .padding(.leading, SessionMenuLayout.contentLeading)
        .padding(.trailing, SessionMenuLayout.contentTrailing)
        .padding(.top, 10)
        .padding(.bottom, 0)
        .background(ChatColors.background)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.route {
        case .conversation(let id):
            if let session = model.catalog.session(id: id) {
                conversation(session: session)
                    .id(id)
            } else {
                emptyConversation(sessionName: "New session")
            }
        case .preview:
            previewConversation
        case nil:
            emptyConversation(sessionName: "New session")
        }
    }

    private func conversation(session: CatalogSession) -> some View {
        ConversationView(
            client: model.client,
            voice: model.voice,
            draft: model.draftBinding(for: session.id),
            sessionName: session.name,
            showSidebar: showMenu,
            onPromptSubmitted: { commandID, text, attachmentIDs in
                model.recordSubmittedDraft(id: commandID, sessionID: session.id, text: text, attachmentIDs: attachmentIDs)
            }
        )
    }

    private var previewConversation: some View {
        ConversationView(
            client: model.client,
            voice: model.voice,
            draft: $previewDraft,
            sessionName: previewConversationTitle,
            showSidebar: showMenu,
            onPromptSubmitted: { _, _, _ in }
        )
    }

    private func emptyConversation(sessionName: String) -> some View {
        ConversationView(
            client: model.client,
            voice: model.voice,
            draft: $previewDraft,
            sessionName: sessionName,
            showSidebar: showMenu,
            onPromptSubmitted: { _, _, _ in }
        )
    }

    private func isSelected(_ session: CatalogSession) -> Bool {
        model.route == .conversation(session.id)
    }

    private func showMenu() {
        guard horizontalSizeClass == .compact else {
            columnVisibility = .all
            preferredCompactColumn = .sidebar
            return
        }
        withAnimation(menuAnimation) {
            isSessionMenuPresented = true
            menuDragOffset = 0
        }
    }

    private func closeSessionMenu() {
        if horizontalSizeClass == .compact {
            withAnimation(menuAnimation) {
                isSessionMenuPresented = false
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

    private func sessionMenuGesture(revealDistance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard horizontalSizeClass == .compact, !model.voice.isBusy,
                      abs(value.translation.width) > abs(value.translation.height) else { return }

                if isSessionMenuPresented {
                    menuDragOffset = min(0, max(-revealDistance, value.translation.width))
                } else if value.startLocation.x <= 32, value.translation.width > 0 {
                    menuDragOffset = min(revealDistance, value.translation.width)
                }
            }
            .onEnded { value in
                guard horizontalSizeClass == .compact, !model.voice.isBusy,
                      abs(value.translation.width) > abs(value.translation.height) else {
                    menuDragOffset = 0
                    return
                }

                withAnimation(menuAnimation) {
                    if isSessionMenuPresented {
                        if value.translation.width < -80 { isSessionMenuPresented = false }
                    } else if value.startLocation.x <= 32, value.translation.width > 80 {
                        isSessionMenuPresented = true
                    }
                    menuDragOffset = 0
                }
            }
    }
}

private struct PhoneSessionRow: View {
    let session: CatalogSession
    let isSelected: Bool

    private var status: String {
        switch session.availability {
        case .running: "Running"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    var body: some View {
        Text(session.name)
            .font(.body)
            .lineLimit(1)
            .padding(.horizontal, SessionMenuLayout.rowTextInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: SessionMenuLayout.rowHeight)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemBackground))
                        .padding(.vertical, SessionMenuLayout.selectedRowVerticalInset)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(session.name), \(status)")
            .accessibilityIdentifier("session-\(session.id.rawValue.uuidString)")
    }
}

private struct PhoneCatalogSearchView: View {
    let model: PhoneWorkbenchState
    let selectResult: (CatalogPage.Item) -> Bool
    @FocusState private var searchFocused: Bool
    @State private var query = ""

    private struct Result: Identifiable {
        let item: CatalogPage.Item
        let id: String

        init(item: CatalogPage.Item) {
            self.item = item
            switch item {
            case .workspace(let workspace): id = "workspace:\(workspace.id.rawValue.uuidString)"
            case .session(let session): id = "session:\(session.id.rawValue.uuidString)"
            }
        }
    }

    private var results: [Result] {
        model.catalog.searchNames(query).map(Result.init)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Workspace or session name", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .accessibilityIdentifier("catalog-search-field")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Clear search")
                    }
                }
            }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Search workspaces and sessions", systemImage: "magnifyingglass", description: Text("Search by workspace or session name."))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(results) { result in
                    Button {
                        searchFocused = false
                        query = ""
                        _ = selectResult(result.item)
                    } label: {
                        searchRow(result.item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("catalog-result-\(result.id)")
                }
            }
            Text("Search uses loaded workspace and session names only—not conversation text.")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("catalog-search-scope")
            if model.catalog.nextCursor != nil {
                Text("Results cover the catalog pages loaded so far. Pull down on the session menu to refresh.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("catalog-search")
    }

    @ViewBuilder
    private func searchRow(_ item: CatalogPage.Item) -> some View {
        switch item {
        case .workspace(let workspace):
            Label(workspace.name, systemImage: "folder")
        case .session(let session):
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name).font(.body)
                if let workspace = model.catalog.workspace(id: session.workspaceId) {
                    Text(workspace.name).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
