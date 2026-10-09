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
        case settings
    }

    enum Sheet: String, Identifiable {
        case search
        case createWorkspace
        case createSession
        var id: String { rawValue }
    }

    struct LoginRequest: Identifiable {
        let id = UUID()
        let endpoint: RelayEndpoint
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
    var route: Route?
    var sheet: Sheet?
    var notice: String?
    var connectionError: String?
    var loginRequest: LoginRequest?
    private(set) var isLoadingPage = false
    private(set) var pageError: String?
    private var pageRequests: [String: PageRequest] = [:]
    private var createRequests: [String: String] = [:]
    private var pendingCreatedSessionID: AxoSessionID?
    private var hasUserNavigated = false
    private var drafts: [AxoSessionID: String] = [:]
    private var submittedDrafts: [String: SubmittedDraft] = [:]
    private var savedEndpoint: String

    var endpointText: String {
        get { savedEndpoint }
        set {
            guard savedEndpoint != newValue else { return }
            savedEndpoint = newValue
            UserDefaults.standard.set(newValue, forKey: "relayEndpoint")
            connectionError = nil
            client.disconnect()
        }
    }

    var endpoint: RelayEndpoint? { try? RelayEndpoint(endpointText) }
    var canCreate: Bool { catalog.hostOnline && client.canSendWorkbenchCommands }

    var connectionStatus: String {
        switch client.link {
        case .disconnected: "Sign in to connect to your Mac."
        case .connecting: "Connecting to your relay…"
        case .macOffline: "Mac offline — nothing is queued."
        case .failed(let message): message
        case .online: "Connected to Mac."
        }
    }

    init() {
        let client = ConversationClient()
        self.client = client
        self.voice = VoicePromptFactory.make()
        self.savedEndpoint = RelayEndpoint.restoredOrigin(UserDefaults.standard.string(forKey: "relayEndpoint"))
        if UserDefaults.standard.string(forKey: "relayEndpoint") != savedEndpoint {
            UserDefaults.standard.set(savedEndpoint, forKey: "relayEndpoint")
        }

        #if DEBUG
        if ChatPreviewData.enabled {
            route = .preview
        } else if ProcessInfo.processInfo.arguments.contains("--axo-workbench-preview") {
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
        guard case .conversation(let id) = route else { return }
        let session = catalog.session(id: id)
        client.selectSession(id, conversationID: session?.conversationId)
        UserDefaults.standard.set(id.rawValue.uuidString, forKey: "axo.selectedPhoneSessionID")
        notice = nil
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
        requestPage(revision: nil, cursor: nil)
    }

    private func requestPage(revision: Int?, cursor: String?) {
        let id = UUID().uuidString
        pageRequests[id] = PageRequest(revision: revision, cursor: cursor)
        isLoadingPage = true
        pageError = nil
        guard client.sendWorkbenchCommand(.catalogPage(id: id, revision: revision, cursor: cursor)) else {
            pageRequests.removeValue(forKey: id)
            isLoadingPage = false
            pageError = "Connect to the relay before loading more workspaces and sessions."
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
            if let expectedRevision = request.revision, expectedRevision == catalog.revision, page.revision != expectedRevision {
                pageRequests.removeAll()
                pageError = "The catalog changed while paging. Refreshing from the latest revision."
                refreshCatalog()
                return
            }
            if request.cursor != nil && page.revision != request.revision {
                pageRequests.removeAll()
                pageError = "The catalog changed while paging. Refreshing from the latest revision."
                refreshCatalog()
                return
            }
        }

        do {
            let revisionChanged = try catalog.apply(page)
            if revisionChanged { pageRequests.removeAll() }
            isLoadingPage = false
            pageError = nil
            restoreSelectionIfAvailable()
            removeMissingSelectionIfCatalogIsComplete()
            selectCreatedSessionIfAvailable()
            if catalog.nextCursor != nil { loadNextPage() }
        } catch {
            isLoadingPage = false
            pageError = "The relay returned an inconsistent catalog. Refresh and try again."
        }
    }

    private func restoreSelectionIfAvailable() {
        guard !hasUserNavigated, route == nil else { return }
        if let saved = UserDefaults.standard.string(forKey: "axo.selectedPhoneSessionID"),
           let uuid = UUID(uuidString: saved) {
            let id = AxoSessionID(uuid)
            if let session = catalog.session(id: id) {
                route = .conversation(id)
                client.selectSession(id, conversationID: session.conversationId)
                hasUserNavigated = true
                return
            }
            if catalog.nextCursor != nil { return }
            UserDefaults.standard.removeObject(forKey: "axo.selectedPhoneSessionID")
        }
        if catalog.nextCursor == nil { hasUserNavigated = true }
    }

    private func removeMissingSelectionIfCatalogIsComplete() {
        guard catalog.nextCursor == nil, case .conversation(let id) = route,
              catalog.session(id: id) == nil else { return }
        route = nil
        client.selectSession(nil, conversationID: nil)
        UserDefaults.standard.removeObject(forKey: "axo.selectedPhoneSessionID")
        notice = "That session is no longer in the Mac catalog."
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

    func createWorkspace(name rawName: String) {
        guard canCreate else { notice = "The Mac is offline. Nothing was created or queued."; return }
        do {
            let name = try WorkspaceStore.validName(rawName)
            let id = UUID().uuidString
            createRequests[id] = "workspace"
            guard client.sendWorkbenchCommand(.createWorkspace(id: id, name: name)) else {
                createRequests.removeValue(forKey: id)
                notice = "The relay is disconnected. Nothing was created or queued."
                return
            }
            sheet = nil
            notice = "Waiting for the Mac to confirm workspace creation…"
        } catch { notice = "Workspace names must be nonempty and at most 120 UTF-8 bytes." }
    }

    func createSession(workspaceID: WorkspaceID, name rawName: String) {
        guard canCreate else { notice = "The Mac is offline. Nothing was created or queued."; return }
        do {
            let name = try WorkspaceStore.validName(rawName)
            let id = UUID().uuidString
            createRequests[id] = "session"
            guard client.sendWorkbenchCommand(.createSession(id: id, workspaceID: workspaceID, name: name)) else {
                createRequests.removeValue(forKey: id)
                notice = "The relay is disconnected. Nothing was created or queued."
                return
            }
            sheet = nil
            notice = "Waiting for the Mac to confirm session creation…"
        } catch { notice = "Session names must be nonempty and at most 120 UTF-8 bytes." }
    }

    private func receive(_ acknowledgement: SubscriptionAcknowledgement) {
        guard acknowledgement.sessionID == client.selectedSessionID else { return }
        if !acknowledgement.hostOnline { notice = "Mac offline. Selection is local; nothing will be started." }
    }

    private func receive(_ acknowledgement: CreationAcknowledgement) {
        guard createRequests.removeValue(forKey: acknowledgement.id) != nil else { return }
        pendingCreatedSessionID = acknowledgement.sessionID
        notice = "Created on Mac. Loading the updated catalog…"
        refreshCatalog()
    }

    private func receiveError(id: String?, sessionID: AxoSessionID?, message: String) {
        if let id, pageRequests.removeValue(forKey: id) != nil {
            isLoadingPage = false
            pageError = message
        }
        if let id, createRequests.removeValue(forKey: id) != nil {
            notice = message
        }
        if sessionID == nil || sessionID == client.selectedSessionID { notice = message }
    }

    func signIn() {
        connectionError = nil
        guard let endpoint else { connectionError = "Enter a valid HTTPS endpoint."; return }
        loginRequest = LoginRequest(endpoint: endpoint)
    }

    func reconnect() {
        connectionError = nil
        guard let endpoint else { connectionError = "Enter a valid HTTPS endpoint."; return }
        guard let token = AccessCredential.load(host: endpoint.baseURL.host!) else { signIn(); return }
        client.connect(endpoint: endpoint, authorizationCookie: token)
    }

    func authenticated(_ token: String, for endpoint: RelayEndpoint) {
        do {
            try AccessCredential.save(token, host: endpoint.baseURL.host!)
            loginRequest = nil
            client.connect(endpoint: endpoint, authorizationCookie: token)
        } catch { connectionError = "Could not save Access credentials securely." }
    }
}
