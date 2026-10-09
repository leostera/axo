import AxoCore
import SwiftUI

@MainActor
struct PhoneWorkbenchView: View {
    @State private var model = PhoneWorkbenchState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var previewDraft = ""
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage("accentColor") private var accentColor: AppAccentColor = .white

    private var previewConversationTitle: String {
        #if DEBUG
        ChatPreviewData.enabled ? "Axo" : "New session"
        #else
        "New session"
        #endif
    }

    private var selection: Binding<PhoneWorkbenchState.Route?> {
        Binding(
            get: { model.route },
            set: { route in
                guard let route else { return }
                model.select(route)
                preferredCompactColumn = .detail
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            detail
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
        }
        .navigationSplitViewStyle(.balanced)
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
            if case .conversation = route { preferredCompactColumn = .detail }
        }
        .onChange(of: model.client.lastAcknowledgedID) { _, id in
            model.acknowledgeSubmittedDraft(id)
        }
    }

    private var sheetBinding: Binding<PhoneWorkbenchState.Sheet?> {
        Binding(get: { model.sheet }, set: { model.sheet = $0 })
    }

    private var sidebar: some View {
        List(selection: selection) {
            ForEach(model.catalog.workspaces) { workspace in
                Section(workspace.name) {
                    let sessions = model.catalog.sessions(in: workspace.id)
                    if sessions.isEmpty {
                        Text("No sessions yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sessions) { session in
                        NavigationLink(value: PhoneWorkbenchState.Route.conversation(session.id)) {
                            PhoneSessionRow(session: session)
                        }
                        .disabled(model.voice.isBusy)
                    }
                }
            }

            if model.catalog.workspaces.isEmpty {
                Text(model.isLoadingPage ? "Loading sessions…" : "Your sessions will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                model.sheet = .createWorkspace
            } label: {
                Label("New workspace", systemImage: "folder.badge.plus")
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
        .scrollContentBackground(.hidden)
        .background(ChatColors.background)
        .refreshable { await model.reloadCatalog() }
        .safeAreaInset(edge: .top, spacing: 0) { menuHeader }
        .safeAreaInset(edge: .bottom, spacing: 0) { menuFooter }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("workbench-menu")
    }

    private var menuHeader: some View {
        HStack(spacing: 12) {
            Text("Axo")
                .font(.largeTitle.weight(.semibold))
                .accessibilityIdentifier("workbench-menu-title")
            Spacer(minLength: 8)
            Button {
                model.sheet = .search
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(.secondary.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("Search sessions")
            .disabled(model.voice.isBusy)
            Button {
                preferredCompactColumn = .detail
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(.secondary.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("Close session menu")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(ChatColors.background)
    }

    private var menuFooter: some View {
        HStack(spacing: 16) {
            Button {
                model.sheet = model.catalog.workspaces.isEmpty ? .createWorkspace : .createSession
            } label: {
                Label("Session", systemImage: "square.and.pencil")
                    .font(.headline)
                    .frame(minHeight: 48)
                    .padding(.horizontal, 22)
                    .background(accentColor.color, in: Capsule())
                    .foregroundStyle(accentColor.foregroundColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New session")

            Spacer(minLength: 0)

            Button {
                model.sheet = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 50, height: 50)
                    .background(.secondary.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 8)
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

    private func showMenu() {
        columnVisibility = .all
        preferredCompactColumn = .sidebar
    }
}

private struct PhoneSessionRow: View {
    let session: CatalogSession

    private var status: String {
        switch session.availability {
        case .running: "Running"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(session.name).lineLimit(1)
            Spacer(minLength: 4)
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
