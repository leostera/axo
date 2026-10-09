import AxoCore
import SwiftUI

@MainActor
struct PhoneWorkbenchView: View {
    @State private var model = PhoneWorkbenchState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var expandedWorkspaceIDs: Set<WorkspaceID> = []
    @State private var previewDraft = ""
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selection: Binding<PhoneWorkbenchState.Route?> {
        Binding(get: { model.route }, set: { model.select($0) })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(appearance.colorScheme)
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
            }
        }
        .sheet(item: loginBinding) { request in
            NavigationStack {
                AccessLogin(endpoint: request.endpoint, onAuthenticated: { token in
                    model.authenticated(token, for: request.endpoint)
                }, onFailure: { model.connectionError = $0 })
                    .navigationTitle("Cloudflare Access")
                    .navigationBarTitleDisplayMode(.inline)
                    .safeAreaInset(edge: .bottom) {
                        if let error = model.connectionError {
                            Text(error).foregroundStyle(.red).font(.caption).padding()
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { model.loginRequest = nil }
                        }
                    }
            }
        }
        .onChange(of: model.client.lastAcknowledgedID) { _, id in
            model.acknowledgeSubmittedDraft(id)
        }
    }

    private var sheetBinding: Binding<PhoneWorkbenchState.Sheet?> {
        Binding(get: { model.sheet }, set: { model.sheet = $0 })
    }

    private var loginBinding: Binding<PhoneWorkbenchState.LoginRequest?> {
        Binding(get: { model.loginRequest }, set: { model.loginRequest = $0 })
    }

    private var sidebar: some View {
        List(selection: selection) {
            Section("Workspaces") {
                if model.catalog.workspaces.isEmpty {
                    Text(model.client.canSendWorkbenchCommands ? "No workspaces in the catalog yet." : "Connect to your Mac to load workspaces.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(model.catalog.workspaces) { workspace in
                    DisclosureGroup(isExpanded: workspaceExpansionBinding(for: workspace.id)) {
                        let sessions = model.catalog.sessions(in: workspace.id)
                        if sessions.isEmpty {
                            Text("No sessions yet").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(sessions) { session in
                            NavigationLink(value: PhoneWorkbenchState.Route.conversation(session.id)) {
                                PhoneSessionRow(session: session)
                            }
                            .disabled(model.voice.isBusy)
                        }
                    } label: {
                        Label(workspace.name, systemImage: workspace.kind == .project ? "folder" : "square.grid.2x2")
                            .lineLimit(1)
                    }
                    .accessibilityIdentifier("workspace-\(workspace.id.rawValue.uuidString)")
                }
            }

            Section("Axo") {
                Button {
                    model.sheet = .search
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .disabled(model.voice.isBusy)
                NavigationLink(value: PhoneWorkbenchState.Route.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
                .disabled(model.voice.isBusy)
            }

            if let pageError = model.pageError {
                Text(pageError).font(.caption).foregroundStyle(.orange)
            }
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if let cursor = model.catalog.nextCursor {
                Button(action: model.loadNextPage) {
                    HStack {
                        if model.isLoadingPage { ProgressView() }
                        Text(model.isLoadingPage ? "Loading catalog…" : "Load more workspaces and sessions")
                    }
                }
                .disabled(model.isLoadingPage)
                .accessibilityIdentifier("load-more-catalog")
                .accessibilityHint("More catalog entries are available.")
                .id(cursor)
            }
        }
        .listStyle(.sidebar)
        .onAppear { expandedWorkspaceIDs.formUnion(model.catalog.workspaces.map(\.id)) }
        .onChange(of: model.catalog.workspaces.map(\.id)) { oldIDs, newIDs in
            expandedWorkspaceIDs.formUnion(newIDs.filter { !oldIDs.contains($0) })
        }
        .navigationTitle("Axo")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New session", systemImage: "plus.bubble") { model.sheet = .createSession }
                        .disabled(!model.canCreate || model.catalog.workspaces.isEmpty)
                    Button("New workspace", systemImage: "folder.badge.plus") { model.sheet = .createWorkspace }
                        .disabled(!model.canCreate)
                    Divider()
                    Button("Refresh catalog", systemImage: "arrow.clockwise", action: model.refreshCatalog)
                        .disabled(!model.client.canSendWorkbenchCommands)
                } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Create workspace or session")
            }
        }
    }

    private func workspaceExpansionBinding(for id: WorkspaceID) -> Binding<Bool> {
        Binding(
            get: { expandedWorkspaceIDs.contains(id) },
            set: { isExpanded in
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                    if isExpanded { expandedWorkspaceIDs.insert(id) }
                    else { expandedWorkspaceIDs.remove(id) }
                }
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch model.route {
        case .conversation(let id):
            if let session = model.catalog.session(id: id) {
                ConversationView(
                    client: model.client,
                    voice: model.voice,
                    endpointText: endpointBinding,
                    draft: model.draftBinding(for: id),
                    sessionName: session.name,
                    showSidebar: {
                        columnVisibility = .all
                        preferredCompactColumn = .sidebar
                    },
                    onPromptSubmitted: { commandID, text, attachmentIDs in
                        model.recordSubmittedDraft(id: commandID, sessionID: id, text: text, attachmentIDs: attachmentIDs)
                    }
                )
                .id(id)
            } else {
                ContentUnavailableView("Session not in this catalog page", systemImage: "questionmark.folder", description: Text("Refresh the catalog or load more entries to find this session."))
                    .toolbar {
                        Button("Refresh") { model.refreshCatalog() }
                    }
            }
        case .preview:
            previewConversation
        case .settings:
            PhoneSettingsView(model: model)
        case nil:
            #if DEBUG
            if ChatPreviewData.enabled { previewConversation }
            else { welcome }
            #else
            welcome
            #endif
        }
    }

    private var endpointBinding: Binding<String> {
        Binding(get: { model.endpointText }, set: { model.endpointText = $0 })
    }

    private var previewConversation: some View {
        ConversationView(
            client: model.client,
            voice: model.voice,
            endpointText: endpointBinding,
            draft: $previewDraft,
            sessionName: "Axo",
            showSidebar: { columnVisibility = .all },
            onPromptSubmitted: { _, _, _ in }
        )
    }

    private var welcome: some View {
        PhoneWorkbenchWelcomeView(
            connectionStatus: model.connectionStatus,
            isCatalogEmpty: model.catalog.revision != nil && model.catalog.workspaces.isEmpty,
            isLoadingCatalog: model.isLoadingPage,
            canCreateWorkspace: model.canCreate,
            openSettings: { model.select(.settings) },
            showSidebar: {
                columnVisibility = .all
                preferredCompactColumn = .sidebar
            },
            refreshCatalog: model.refreshCatalog,
            createWorkspace: { model.sheet = .createWorkspace }
        )
    }
}

private struct PhoneSessionRow: View {
    let session: CatalogSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: String {
        switch session.availability {
        case .running: "Running"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    private var symbol: String {
        switch session.availability {
        case .running: "circle.fill"
        case .stopped: "circle"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(session.availability == .failed ? .orange : .secondary)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.name), \(status)")
        .accessibilityIdentifier("session-\(session.id.rawValue.uuidString)")
    }
}

private struct PhoneWorkbenchWelcomeView: View {
    let connectionStatus: String
    let isCatalogEmpty: Bool
    let isLoadingCatalog: Bool
    let canCreateWorkspace: Bool
    let openSettings: () -> Void
    let showSidebar: () -> Void
    let refreshCatalog: () -> Void
    let createWorkspace: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    private var title: String {
        if isCatalogEmpty && canCreateWorkspace { "Start with a workspace" }
        else if isCatalogEmpty { "Your workbench, wherever you are" }
        else { "Choose a session to jump back in" }
    }

    private var message: String {
        if isCatalogEmpty && canCreateWorkspace {
            "Create a workspace, then open one of your Mac’s Pi sessions from anywhere."
        } else if isCatalogEmpty {
            "Connect to your Mac and your workspaces and Pi sessions will appear here."
        } else {
            "Your conversations are ready in the Axo sidebar. Pick up right where you left off."
        }
    }

    private var primaryAction: (title: String, action: () -> Void) {
        if isCatalogEmpty && canCreateWorkspace { ("Create workspace", createWorkspace) }
        else if isCatalogEmpty { ("Connection settings", openSettings) }
        else { ("Browse workspaces", showSidebar) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 42)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 30, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 78, height: 78)
                    .background(.tint.opacity(0.09), in: Circle())
                    .overlay(Circle().stroke(.tint.opacity(0.14), lineWidth: 1))
                    .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.86)
                    .opacity(hasAppeared ? 1 : 0)
                    .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.74), value: hasAppeared)
                    .accessibilityHidden(true)

                VStack(spacing: 9) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("workbench-welcome-title")
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Label(connectionStatus, systemImage: "circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.08), in: Capsule())
                }
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared || reduceMotion ? 0 : 10)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.34).delay(0.08), value: hasAppeared)

                VStack(spacing: 10) {
                    Button(action: primaryAction.action) {
                        Label(primaryAction.title, systemImage: isCatalogEmpty && canCreateWorkspace ? "plus" : "rectangle.3.group")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if isLoadingCatalog {
                        ProgressView("Loading workspaces…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    } else {
                        Button("Refresh catalog", systemImage: "arrow.clockwise", action: refreshCatalog)
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                    }
                }
                .frame(maxWidth: 320)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared || reduceMotion ? 0 : 12)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.34).delay(0.16), value: hasAppeared)
                Spacer(minLength: 42)
            }
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity, minHeight: 420)
            .padding(24)
        }
        .accessibilityIdentifier("workbench-welcome")
        .navigationTitle("Axo")
        .onAppear { hasAppeared = true }
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
                Text("Results cover the catalog pages loaded so far. Load more from the workspace list to include the rest.")
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
