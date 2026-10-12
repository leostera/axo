import AxoCore
import AxoVoice
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class PhoneWorkbenchState {
    enum Route: Hashable {
        case conversation(AxoSessionID)
        case preview
    }

    enum Sheet: String, Identifiable {
        case search
        case createWorkspace
        case createSession
        case settings
        var id: String { rawValue }
    }

    private struct PageRequest {
        let revision: Int?
        let cursor: String?
    }

    private struct SubmittedDraft {
        let sessionID: AxoSessionID
        let text: String
        let attachmentIDs: [String]
    }

    let client: ConversationClient
    let voice: VoicePrompt
    private(set) var catalog = WorkbenchCatalog()
    var route: Route? = .preview
    var sheet: Sheet?
    var notice: String?
    private(set) var isLoadingPage = false
    private(set) var pageError: String?
    private var pageRequests: [String: PageRequest] = [:]
    private var pageTimeouts: [String: Task<Void, Never>] = [:]
    private var catalogRefreshContinuation: CheckedContinuation<Void, Never>?
    private var createRequests: [String: String] = [:]
    private var pendingCreatedSessionID: AxoSessionID?
    private var hasUserNavigated = false
    private var hasStarted = false
    private var drafts: [AxoSessionID: String] = [:]
    private var submittedDrafts: [String: SubmittedDraft] = [:]
    private var savedEndpoint: String

    private var endpoint: RelayEndpoint? { try? RelayEndpoint(savedEndpoint) }
    var canCreate: Bool { catalog.hostOnline && client.canSendWorkbenchCommands }

    init() {
        let client = ConversationClient()
        self.client = client
        self.voice = VoicePromptFactory.make()
        self.savedEndpoint = RelayEndpoint.restoredOrigin(UserDefaults.standard.string(forKey: "relayEndpoint"))
        if UserDefaults.standard.string(forKey: "relayEndpoint") != savedEndpoint {
            UserDefaults.standard.set(savedEndpoint, forKey: "relayEndpoint")
        }

        #if DEBUG
        if ChatPreviewData.isPerformancePreview {
            catalog = ChatPreviewData.performanceCatalog()
            ChatPreviewData.preparePerformanceMessages()
            if let session = catalog.sessions.first {
                route = .conversation(session.id)
                client.selectSession(session.id, conversationID: session.conversationId)
            }
        } else if ChatPreviewData.enabled {
            route = .preview
        } else if ProcessInfo.processInfo.arguments.contains("--axo-workbench-preview") {
            route = nil
            UserDefaults.standard.removeObject(forKey: "axo.selectedPhoneSessionID")
            let fixture = #"{"type":"catalog_page","revision":1,"items":[{"kind":"workspace","workspace":{"id":"11111111-1111-4111-8111-111111111111","name":"Axo Project","kind":"project"}},{"kind":"workspace","workspace":{"id":"33333333-3333-4333-8333-333333333333","name":"Research","kind":"standalone"}},{"kind":"session","session":{"id":"22222222-2222-4222-8222-222222222222","workspaceId":"11111111-1111-4111-8111-111111111111","name":"Phone shell","conversationId":"pi-phone-shell","availability":"running"}},{"kind":"session","session":{"id":"44444444-4444-4444-8444-444444444444","workspaceId":"33333333-3333-4333-8333-333333333333","name":"Research notes","availability":"stopped"}}],"nextCursor":null,"hostOnline":false}"#
            if case .catalogPage(let page) = try? RelayEvent.decode(Data(fixture.utf8)) { _ = try? catalog.apply(page) }
        }
        #endif
        client.receiveCatalogPage = { [weak self] page in self?.receive(page) }
        client.receiveSubscription = { [weak self] acknowledgement in self?.receive(acknowledgement) }
        client.receiveCreationAcknowledgement = { [weak self] acknowledgement in self?.receive(acknowledgement) }
        client.receiveCommandError = { [weak self] id, sessionID, message in self?.receiveError(id: id, sessionID: sessionID, message: message) }
    }

    func sessionDraft(_ id: AxoSessionID) -> String { drafts[id] ?? "" }

    func setSessionDraft(_ text: String, for id: AxoSessionID) {
        drafts[id] = text
    }

    func draftBinding(for id: AxoSessionID) -> Binding<String> {
        Binding(get: { self.sessionDraft(id) }, set: { self.setSessionDraft($0, for: id) })
    }

    func recordSubmittedDraft(id: String, sessionID: AxoSessionID, text: String, attachmentIDs: [String]) {
        submittedDrafts[id] = SubmittedDraft(sessionID: sessionID, text: text, attachmentIDs: attachmentIDs)
    }

    func acknowledgeSubmittedDraft(_ id: String?) {
        guard let id, let submitted = submittedDrafts.removeValue(forKey: id) else { return }
        if drafts[submitted.sessionID] == submitted.text { drafts[submitted.sessionID] = "" }
        client.files?.acknowledgeDrafts(ids: submitted.attachmentIDs)
    }

    func select(_ route: Route?) {
        guard !voice.isBusy else {
            notice = "Finish or cancel voice capture before changing workspaces or sessions."
            return
        }
        hasUserNavigated = true
        self.route = route
        switch route {
        case .conversation(let id):
            let session = catalog.session(id: id)
            client.selectSession(id, conversationID: session?.conversationId)
            persistSelectedSession(id)
            notice = nil
        case .preview, nil:
            client.selectSession(nil, conversationID: nil)
        }
    }

    func selectSearchResult(_ item: CatalogPage.Item) {
        switch item {
        case .session(let session): select(.conversation(session.id))
        case .workspace(let workspace):
            if let firstSession = catalog.sessions(in: workspace.id).first { select(.conversation(firstSession.id)) }
            else { notice = "This workspace does not have a session yet." }
        }
    }

    func loadNextPage() {
        guard let revision = catalog.revision, let cursor = catalog.nextCursor, !isLoadingPage else { return }
        requestPage(revision: revision, cursor: cursor)
    }

    func refreshCatalog() {
        guard client.canSendWorkbenchCommands else {
            reconnect()
            return
        }
        requestPage(revision: nil, cursor: nil)
    }

    func reloadCatalog() async {
        guard !isLoadingPage else { return }
        await withCheckedContinuation { continuation in
            catalogRefreshContinuation = continuation
            refreshCatalog()
            if !isLoadingPage { finishCatalogRefresh() }
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        #if DEBUG
        if ChatPreviewData.enabled { return }
        if ProcessInfo.processInfo.arguments.contains("--axo-workbench-preview") {
            restoreSelectionIfAvailable()
            return
        }
        #endif
        restoreSelectionIfAvailable()
        reconnect()
    }

    private func requestPage(revision: Int?, cursor: String?) {
        let id = UUID().uuidString
        pageRequests[id] = PageRequest(revision: revision, cursor: cursor)
        isLoadingPage = true
        pageError = nil
        pageTimeouts[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.timeOutPage(id)
        }
        guard client.sendWorkbenchCommand(.catalogPage(id: id, revision: revision, cursor: cursor)) else {
            pageRequests.removeValue(forKey: id)
            pageTimeouts.removeValue(forKey: id)?.cancel()
            isLoadingPage = false
            pageError = nil
            finishCatalogRefresh()
            return
        }
    }

    private func receive(_ page: CatalogPage) {
        if page.requestId == nil, catalog.revision == page.revision {
            catalog.updateHostOnline(page.hostOnline)
            return
        }
        if let requestID = page.requestId {
            guard let request = pageRequests.removeValue(forKey: requestID) else { return }
            pageTimeouts.removeValue(forKey: requestID)?.cancel()
            if let expectedRevision = request.revision, expectedRevision == catalog.revision, page.revision != expectedRevision {
                cancelPageRequests()
                pageError = "The catalog changed while paging. Refreshing from the latest revision."
                refreshCatalog()
                return
            }
            if request.cursor != nil && page.revision != request.revision {
                cancelPageRequests()
                pageError = "The catalog changed while paging. Refreshing from the latest revision."
                refreshCatalog()
                return
            }
        }

        do {
            let revisionChanged = try catalog.apply(page)
            if revisionChanged { cancelPageRequests() }
            isLoadingPage = false
            pageError = nil
            restoreSelectionIfAvailable()
            removeMissingSelectionIfCatalogIsComplete()
            selectCreatedSessionIfAvailable()
            if catalog.nextCursor != nil { loadNextPage() }
            else { finishCatalogRefresh() }
        } catch {
            isLoadingPage = false
            pageError = "The relay returned an inconsistent catalog. Refresh and try again."
            finishCatalogRefresh()
        }
    }

    private func restoreSelectionIfAvailable() {
        guard !hasUserNavigated, route == nil || route == .preview else { return }
        if let saved = UserDefaults.standard.string(forKey: "axo.selectedPhoneSessionID"),
           let uuid = UUID(uuidString: saved) {
            let id = AxoSessionID(uuid)
            if let session = catalog.session(id: id) {
                activateOnStartup(session)
                return
            }
            if catalog.nextCursor != nil { return }
            UserDefaults.standard.removeObject(forKey: "axo.selectedPhoneSessionID")
        }
        guard catalog.nextCursor == nil else { return }
        if let first = catalog.sessions.first { activateOnStartup(first) }
    }

    private func removeMissingSelectionIfCatalogIsComplete() {
        guard catalog.nextCursor == nil, case .conversation(let id) = route,
              catalog.session(id: id) == nil else { return }
        route = nil
        client.selectSession(nil, conversationID: nil)
        UserDefaults.standard.removeObject(forKey: "axo.selectedPhoneSessionID")
        notice = "That session is no longer in the Mac catalog."
    }

    private func activateOnStartup(_ session: CatalogSession) {
        route = .conversation(session.id)
        client.selectSession(session.id, conversationID: session.conversationId)
        persistSelectedSession(session.id)
        hasUserNavigated = true
    }

    private func persistSelectedSession(_ id: AxoSessionID) {
        #if DEBUG
        guard !ChatPreviewData.isPerformancePreview else { return }
        #endif
        UserDefaults.standard.set(id.rawValue.uuidString, forKey: "axo.selectedPhoneSessionID")
    }

    private func cancelPageRequests() {
        pageRequests.removeAll()
        for timeout in pageTimeouts.values { timeout.cancel() }
        pageTimeouts.removeAll()
    }

    private func timeOutPage(_ id: String) {
        guard pageRequests.removeValue(forKey: id) != nil else { return }
        pageTimeouts.removeValue(forKey: id)?.cancel()
        isLoadingPage = false
        pageError = "The session list could not be refreshed right now."
        finishCatalogRefresh()
    }

    private func finishCatalogRefresh() {
        catalogRefreshContinuation?.resume()
        catalogRefreshContinuation = nil
    }

    private func selectCreatedSessionIfAvailable() {
        guard let id = pendingCreatedSessionID, catalog.session(id: id) != nil else {
            guard pendingCreatedSessionID != nil, catalog.nextCursor != nil else { return }
            loadNextPage()
            return
        }
        pendingCreatedSessionID = nil
        hasUserNavigated = false
        select(.conversation(id))
    }

    func createWorkspace(name: WorkbenchName) {
        guard canCreate else { notice = "Axo is reconnecting. Nothing was queued."; return }
        let id = UUID().uuidString
        createRequests[id] = "workspace"
        guard client.sendWorkbenchCommand(.createWorkspace(id: id, name: name.value)) else {
            createRequests.removeValue(forKey: id)
            notice = "Axo is reconnecting. Nothing was queued."
            return
        }
        sheet = nil
        notice = "Waiting for the Mac to confirm workspace creation…"
    }

    func createSession(workspaceID: WorkspaceID, name: WorkbenchName) {
        guard canCreate else { notice = "Axo is reconnecting. Nothing was queued."; return }
        let id = UUID().uuidString
        createRequests[id] = "session"
        guard client.sendWorkbenchCommand(.createSession(id: id, workspaceID: workspaceID, name: name.value)) else {
            createRequests.removeValue(forKey: id)
            notice = "Axo is reconnecting. Nothing was queued."
            return
        }
        sheet = nil
        notice = "Waiting for the Mac to confirm session creation…"
    }

    private func receive(_ acknowledgement: SubscriptionAcknowledgement) {
        guard acknowledgement.sessionID == client.selectedSessionID else { return }
        let needsCatalogRefresh = catalog.revision == nil || (!catalog.hostOnline && acknowledgement.hostOnline)
        catalog.updateHostOnline(acknowledgement.hostOnline)
        if needsCatalogRefresh && !isLoadingPage {
            requestPage(revision: nil, cursor: nil)
        }
    }

    private func receive(_ acknowledgement: CreationAcknowledgement) {
        guard createRequests.removeValue(forKey: acknowledgement.id) != nil else { return }
        pendingCreatedSessionID = acknowledgement.sessionID
        notice = "Created on Mac. Loading the updated catalog…"
        refreshCatalog()
    }

    private func receiveError(id: String?, sessionID: AxoSessionID?, message: String) {
        if let id, pageRequests.removeValue(forKey: id) != nil {
            pageTimeouts.removeValue(forKey: id)?.cancel()
            isLoadingPage = false
            pageError = message
            finishCatalogRefresh()
        }
        if let id, createRequests.removeValue(forKey: id) != nil {
            notice = message
        }
        if sessionID == nil || sessionID == client.selectedSessionID { notice = message }
    }

    func reconnect() {
        guard let endpoint,
              let host = endpoint.baseURL.host,
              let token = AccessCredential.load(host: host) else { return }
        client.connect(endpoint: endpoint, authorizationCookie: token)
    }

}
