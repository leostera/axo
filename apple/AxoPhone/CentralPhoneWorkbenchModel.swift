import AxoCore
import AxoProtocol
import Foundation
import Observation

@MainActor
@Observable
final class CentralPhoneWorkbenchModel {
    private(set) var machines: [MachineSummary] = []
    private(set) var isDiscovering = false
    private(set) var isLoadingCatalog = false
    private(set) var isConnected = false
    private(set) var accessMessage: String?
    private(set) var notice: String?
    private(set) var selectedMachineID: UUID?
    private(set) var catalog: CentralCatalog?
    private(set) var catalogNotice: String?
    private(set) var conversationSessionID: UUID?
    private(set) var conversationPresentationID: UUID?
    private(set) var conversationObservation: CentralResponse?
    private(set) var conversationHistory: [CentralPiCanonicalProjection] = []
    private(set) var conversationNotice: String?
    private(set) var isLoadingConversation = false
    private(set) var conversationSubmissionSupported = false
    private var connectedMachineID: UUID?
    private var controlPlane: AxoControlPlaneSession?
    private var selectionOperation = UUID()
    private var discoveryOperation = UUID()
    private var authorizationOperation = UUID()
    private var conversationOperation = UUID()
    private var reconcilingInputIDs = Set<UUID>()
    private var conversationEditorBinding: CentralPiBindingTarget?
    private let conversationInputs = CentralInputBuffers()

    private let endpoint: AxoControlPlaneEndpoint
    private let persistsCredentials: Bool
    private var accessCookie: AxoControlPlaneAccessCookie?

    init(endpoint: AxoControlPlaneEndpoint = .production,
         credential: AxoControlPlaneAccessCookie? = nil, persistsCredentials: Bool = true) {
        self.endpoint = endpoint
        self.persistsCredentials = persistsCredentials
        if let credential { use(credential); return }
        #if DEBUG
        if isPreview { loadPreview(); return }
        #endif
        guard let host = endpoint.baseURL.host,
              let credential = ControlPlaneAccessCredential.load(host: host) else { return }
        use(credential)
    }

    var isSignedIn: Bool { accessCookie != nil }
    var selectedMachine: MachineSummary? { machines.first { $0.machineId == selectedMachineID } }

    /// One indivisible graph, scoped to the selected live host and store. Never
    /// expose independently cached workspace/runtime pages or an offline graph.
    var selectedCatalog: CentralCatalog? {
        guard isConnected, let machine = selectedMachine, machine.online, let catalog,
              catalog.source.machine.machineId == machine.machineId,
              catalog.source.machine.hostGeneration == machine.hostGeneration else { return nil }
        return catalog
    }
    var isRuntimeGenerationStale: Bool {
        guard let machine = selectedMachine, let catalog else { return false }
        return !machine.online || catalog.source.machine.machineId != machine.machineId || catalog.source.machine.hostGeneration != machine.hostGeneration
    }
    var selectedRuntimes: [TerminalSnapshot] { selectedCatalog?.terminals ?? [] }
    var selectedWorkspaces: [CentralWorkspace] { selectedCatalog?.workspaces ?? [] }
    var selectedWorkSessions: [CentralSessionView] { selectedCatalog?.sessions ?? [] }
    func sessions(in workspaceId: UUID?) -> [CentralSessionView] { selectedCatalog?.sessionsByWorkspace[workspaceId] ?? [] }
    var selectedWorkRevision: CentralRevision? { selectedCatalog?.revision }
    func conversationText(for target: CentralPiBindingTarget, presentationID: UUID) -> String {
        guard canEditConversation(presentationID: presentationID, binding: target) else { return "" }
        return conversationInputs.text(for: CentralEditingTarget(target))
    }
    var canSubmitConversation: Bool {
        guard isConnected, conversationSubmissionSupported, let source = selectedCatalog?.source,
              let response = conversationObservation, response.source == source,
              case .piObservation(.live(let target, let state)) = response.payload,
              target.sessionId == conversationSessionID, !conversationInputs.hasPending(for: CentralEditingTarget(target)),
              !state.recovery, !state.pending, state.uiWaits == 0, state.question == nil,
              !state.busy || state.interactionId != nil else { return false }
        return conversationInputs.text(for: CentralEditingTarget(target)).unicodeScalars.contains { !$0.properties.isWhitespace }
    }

    func start() async {
        #if DEBUG
        if isPreview { return }
        #endif
        while !Task.isCancelled {
            await refreshMachines()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func signIn(_ credential: AxoControlPlaneAccessCookie) async {
        guard let host = endpoint.baseURL.host else { return }
        do {
            if persistsCredentials { try ControlPlaneAccessCredential.save(credential, host: host) }
            let authorization = UUID()
            authorizationOperation = authorization
            discoveryOperation = UUID()
            await disconnect()
            guard authorizationOperation == authorization else { return }
            use(credential)
            machines = []
            accessMessage = nil
            await refreshMachines()
        } catch { notice = "Cloudflare Access could not be saved securely on this device." }
    }

    func signOut() async {
        // Fence old callbacks before awaiting transport teardown.
        authorizationOperation = UUID()
        discoveryOperation = UUID()
        selectionOperation = UUID()
        let previous = controlPlane
        controlPlane = nil
        if persistsCredentials, let host = endpoint.baseURL.host { ControlPlaneAccessCredential.remove(host: host) }
        accessCookie = nil
        machines = []; selectedMachineID = nil
        clearCatalog()
        isConnected = false; connectedMachineID = nil
        isDiscovering = false; isLoadingCatalog = false
        accessMessage = nil
        notice = nil
        await previous?.disconnect()
    }

    func refreshMachines() async {
        #if DEBUG
        if isPreview { return }
        #endif
        guard let controlPlane else { accessMessage = "Cloudflare Access authorization is required."; return }
        let operation = UUID()
        discoveryOperation = operation
        isDiscovering = true; notice = nil
        defer { if discoveryOperation == operation { isDiscovering = false } }
        do {
            let result = try await controlPlane.discoverMachines()
            guard discoveryOperation == operation else { return }
            let previous = selectedMachine
            machines = result.machines
            if let machineID = selectedMachineID,
               let current = machines.first(where: { $0.machineId == machineID }) {
                if !current.online || current.hostGeneration == nil || current.hostGeneration != previous?.hostGeneration {
                    selectionOperation = UUID()
                    clearCatalog()
                    isConnected = false; connectedMachineID = nil; isLoadingCatalog = false
                    notice = "The machine is offline or restarted. Reconnect to read its current central state."
                    await controlPlane.disconnect()
                }
            } else if selectedMachineID != nil {
                selectionOperation = UUID()
                clearCatalog()
                selectedMachineID = nil
                isConnected = false; connectedMachineID = nil; isLoadingCatalog = false
                await controlPlane.disconnect()
            }
        } catch {
            guard discoveryOperation == operation else { return }
            selectionOperation = UUID()
            machines = []; clearCatalog()
            selectedMachineID = nil
            isConnected = false; connectedMachineID = nil; isLoadingCatalog = false
            await controlPlane.disconnect()
            guard discoveryOperation == operation else { return }
            await report(error)
        }
    }

    func selectMachine(_ machineID: UUID) async {
        guard let machine = machines.first(where: { $0.machineId == machineID }) else { return }
        #if DEBUG
        if isPreview {
            selectedMachineID = machineID
            isConnected = machine.online && catalog?.source.machine.machineId == machineID && catalog?.source.machine.hostGeneration == machine.hostGeneration
            connectedMachineID = isConnected ? machineID : nil
            return
        }
        #endif
        selectedMachineID = machineID
        let operation = UUID()
        selectionOperation = operation
        clearCatalog()
        notice = nil
        isConnected = false; connectedMachineID = nil; isLoadingCatalog = false
        guard machine.online, machine.hostGeneration != nil else { await controlPlane?.disconnect(); return }
        guard let controlPlane else { return }
        isLoadingCatalog = true
        defer { if selectionOperation == operation { isLoadingCatalog = false } }
        do {
            _ = try await controlPlane.connect(to: machine)
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            connectedMachineID = machineID
            isConnected = true
            await loadCatalog(machineID: machineID, operation: operation)
        } catch {
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            clearCatalog()
            await report(error)
        }
    }

    private func loadCatalog(machineID: UUID, operation: UUID) async {
        guard connectedMachineID == machineID, selectionOperation == operation, let controlPlane else { return }
        clearCatalog()
        do {
            let result = try await controlPlane.catalog()
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            catalog = result
        } catch {
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            clearCatalog()
            isConnected = false; connectedMachineID = nil
            await report(error)
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            catalogNotice = notice ?? "Central state is unavailable. No cached graph was applied."
        }
    }

    func refreshCatalog() async {
        guard !isLoadingCatalog, let machineID = selectedMachineID, connectedMachineID == machineID else { return }
        let operation = selectionOperation
        notice = nil; isLoadingCatalog = true
        defer { if selectionOperation == operation { isLoadingCatalog = false } }
        await loadCatalog(machineID: machineID, operation: operation)
    }

    func disconnect() async {
        selectionOperation = UUID()
        clearCatalog()
        isConnected = false; connectedMachineID = nil; isLoadingCatalog = false
        await controlPlane?.disconnect()
    }

    func reconnect() async {
        guard !isLoadingCatalog else { return }
        guard let machineID = selectedMachineID else { await refreshMachines(); return }
        let operation = UUID()
        selectionOperation = operation
        await refreshMachines()
        guard selectionOperation == operation, selectedMachineID == machineID,
              let machine = machines.first(where: { $0.machineId == machineID }), machine.online else { return }
        await selectMachine(machineID)
    }

    func openConversation(sessionID: UUID) async {
        guard selectedCatalog?.sessions.contains(where: { $0.session.sessionId == sessionID }) == true else { return }
        if conversationPresentationID != nil { discardConversationEditing() }
        conversationEditorBinding = nil
        conversationSessionID = sessionID
        conversationPresentationID = UUID()
        conversationOperation = UUID()
        conversationObservation = nil
        conversationHistory = []
        conversationNotice = nil
        conversationSubmissionSupported = false
        #if DEBUG
        if isPreview, let session = selectedCatalog?.sessions.first(where: { $0.session.sessionId == sessionID }),
           let source = selectedCatalog?.source {
            do {
                conversationObservation = try CentralBrowserPreview.notAdmittedObservation(
                    source: source, workspaceId: session.session.workspaceId, sessionId: sessionID
                )
                conversationNotice = "Preview fixture: no Pi admission exists and no request was sent."
            } catch {
                conversationNotice = "Preview conversation fixture is invalid. No request was sent."
            }
            return
        }
        #endif
        await refreshConversation()
    }

    func closeConversation() {
        conversationOperation = UUID()
        discardConversationEditing()
        conversationEditorBinding = nil
        conversationSessionID = nil
        conversationPresentationID = nil
        conversationObservation = nil
        conversationHistory = []
        conversationNotice = nil
        conversationSubmissionSupported = false
        isLoadingConversation = false
    }

    func refreshConversation() async {
        guard !isLoadingConversation, let sessionID = conversationSessionID,
              let session = selectedCatalog?.sessions.first(where: { $0.session.sessionId == sessionID }),
              let source = selectedCatalog?.source, let controlPlane else { return }
        let operation = UUID()
        conversationOperation = operation
        conversationObservation = nil
        conversationHistory = []
        conversationNotice = nil
        isLoadingConversation = true
        defer { if conversationOperation == operation { isLoadingConversation = false } }
        var confirmedObservation: CentralResponse?
        do {
            conversationSubmissionSupported = await controlPlane.supports(method: "axo.state.chat.command.submit")
            guard conversationIsCurrent(operation, source: source, sessionID: sessionID) else { return }
            let observe = try CentralRequest.observePi(source: source, workspaceId: session.session.workspaceId, sessionId: sessionID)
            let observation = try await controlPlane.perform(observe)
            guard conversationIsCurrent(operation, source: source, sessionID: sessionID) else { return }
            confirmedObservation = observation
            conversationObservation = observation

            let target: CentralPiBindingTarget
            let readMode: CentralPiHistoryReadMode
            switch observation.payload {
            case .piObservation(.live(let binding, _)):
                setConversationEditorBinding(binding)
                target = binding
                readMode = .live
            case .piObservation(.stopped(let binding)):
                setConversationEditorBinding(nil)
                conversationNotice = "This Pi conversation is stopped. History is read-only; no replacement was started."
                target = binding
                readMode = .stopped
            case .piObservation(.notAdmitted):
                setConversationEditorBinding(nil)
                conversationNotice = "This session has no admitted Pi conversation yet. No replacement was started."
                await reconcileOnePendingInput(source: source, operation: operation, sessionID: sessionID, controlPlane: controlPlane)
                return
            default:
                setConversationEditorBinding(nil)
                conversationNotice = "The selected session returned no Pi conversation state."
                return
            }

            let historyRequest = try CentralRequest.piHistory(target: target, readMode: readMode, collection: .branch, limit: 50)
            let history = try await controlPlane.perform(historyRequest)
            guard conversationIsCurrent(operation, source: source, sessionID: sessionID) else { return }
            guard case .piHistory(let page) = history.payload, page.target == target, page.readMode == readMode else {
                throw AxoProtocolValidationError.invalidResult(method: historyRequest.method)
            }
            conversationHistory = page.entries
            if page.cursor != nil {
                conversationNotice = "Showing the first bounded page of Pi history. Earlier entries are not loaded."
            } else if !conversationSubmissionSupported {
                conversationNotice = "This daemon supports central reads but does not advertise central Pi submission. Input remains local and cannot be sent."
            }
            await reconcileOnePendingInput(source: source, operation: operation, sessionID: sessionID, controlPlane: controlPlane)
        } catch {
            guard conversationIsCurrent(operation, source: source, sessionID: sessionID) else { return }
            conversationHistory = []
            if let confirmedObservation, confirmedObservation.source == source {
                // A history read failure does not invalidate a separately validated live binding.
                // Submission still rechecks central method support before creating its ticket.
                conversationObservation = confirmedObservation
                conversationNotice = "Pi history is unavailable. No cached history was applied; current observed state is retained."
            } else {
                conversationObservation = nil
                conversationNotice = "Pi conversation state is unavailable. No cached conversation was applied."
            }
        }
    }

    func canEditConversation(presentationID: UUID, binding: CentralPiBindingTarget) -> Bool {
        conversationPresentationID == presentationID && currentLiveConversationTarget() == binding
    }

    func conversationEditingCapture(presentationID: UUID, binding: CentralPiBindingTarget) throws -> CentralEditCapture {
        guard canEditConversation(presentationID: presentationID, binding: binding),
              let observation = conversationObservation else { throw CentralInputIssue.unavailable }
        return try conversationInputs.editingCapture(from: observation)
    }

    func editConversation(_ text: String, presentationID: UUID, binding: CentralPiBindingTarget) {
        guard canEditConversation(presentationID: presentationID, binding: binding) else {
            conversationNotice = "The Pi binding changed. Close and reopen this conversation before editing."
            return
        }
        do {
            try conversationInputs.edit(text, in: CentralEditingTarget(binding))
            conversationNotice = nil
        } catch CentralInputIssue.textCapacity {
            conversationNotice = "The editing limit was reached. Shorten the text before submitting."
        } catch {
            conversationNotice = "This Pi editing buffer is unavailable. No text was submitted."
        }
    }

    @discardableResult func applyConversationEdit(_ text: String, matching capture: CentralEditCapture, presentationID: UUID) throws -> Bool {
        guard conversationPresentationID == presentationID, let observation = conversationObservation else { return false }
        return try conversationInputs.apply(text, matching: capture, against: observation)
    }

    func abandonEmptyConversationCapture(_ capture: CentralEditCapture) {
        conversationInputs.releaseEmptyEditingCapture(capture)
    }

    func submitConversation(presentationID: UUID, binding: CentralPiBindingTarget) async {
        guard let controlPlane, let response = conversationObservation,
              canEditConversation(presentationID: presentationID, binding: binding),
              canSubmitConversation, let sessionID = conversationSessionID,
              let source = selectedCatalog?.source else {
            conversationNotice = "Pi input is unavailable until the selected central binding is observed."
            return
        }
        let operation = conversationOperation
        guard await controlPlane.supports(method: "axo.state.chat.command.submit") else {
            guard conversationPresentationID == presentationID else { return }
            conversationSubmissionSupported = false
            conversationNotice = "This daemon does not advertise central Pi submission. No request was sent."
            return
        }
        guard conversationPresentationID == presentationID,
              conversationIsCurrent(operation, source: source, sessionID: sessionID),
              conversationObservation?.revision == response.revision,
              canEditConversation(presentationID: presentationID, binding: binding),
              canSubmitConversation else { return }
        do {
            let ticket = try conversationInputs.captureText(from: response)
            try await submit(ticket, controlPlane: controlPlane)
        } catch {
            conversationNotice = "The Pi command could not be captured. Editing was preserved; no other destination was used."
        }
    }

    func cancelConversationInteraction(presentationID: UUID, binding: CentralPiBindingTarget) async {
        await submitControl(.cancel, presentationID: presentationID, binding: binding,
                            message: "The observed Pi interaction can no longer be cancelled.")
    }

    func answerConversationQuestion(optionID: UUID, presentationID: UUID, binding: CentralPiBindingTarget) async {
        await submitControl(.answer(optionId: optionID), presentationID: presentationID, binding: binding,
                            message: "That question option is no longer available.")
    }

    private func submitControl(_ choice: CentralControlChoice, presentationID: UUID,
                               binding: CentralPiBindingTarget, message: String) async {
        guard let controlPlane, let response = conversationObservation,
              canEditConversation(presentationID: presentationID, binding: binding),
              let sessionID = conversationSessionID, let source = selectedCatalog?.source else {
            conversationNotice = message
            return
        }
        let operation = conversationOperation
        guard await controlPlane.supports(method: "axo.state.chat.command.submit") else {
            guard conversationPresentationID == presentationID else { return }
            conversationSubmissionSupported = false
            conversationNotice = "This daemon does not advertise central Pi submission. No request was sent."
            return
        }
        guard conversationPresentationID == presentationID,
              conversationIsCurrent(operation, source: source, sessionID: sessionID),
              conversationObservation?.revision == response.revision,
              canEditConversation(presentationID: presentationID, binding: binding) else { return }
        do {
            let ticket = try conversationInputs.captureControl(choice, from: response)
            try await submit(ticket, controlPlane: controlPlane)
        } catch { conversationNotice = message }
    }

    private func submit(_ ticket: CentralInputTicket, controlPlane: AxoControlPlaneSession) async throws {
        let request = try conversationInputs.beginSubmission(ticket)
        let operation = conversationOperation
        let sessionID = conversationSessionID
        let source = ticket.command.target.source
        do {
            let response = try await controlPlane.perform(request)
            guard conversationIsCurrent(operation, source: source, sessionID: sessionID) else { return }
            let result = try conversationInputs.acknowledgeSubmission(ticket, response: response)
            switch result {
            case .dispatched:
                conversationNotice = "Axod acknowledged the original Pi command. Execution remains a separate observation."
                await refreshConversation()
            case .rejected:
                conversationNotice = "Pi rejected the original command. Editing is preserved for a new explicit submission."
                await refreshConversation()
            case .missing, .unconfirmed, .outcomeUnknown:
                conversationNotice = "The original Pi command remains unresolved. It will not be replayed."
            }
        } catch {
            await reconcile(ticket, source: selectedCatalog?.source, operation: operation, sessionID: sessionID, controlPlane: controlPlane)
        }
    }

    private func reconcileOnePendingInput(source: CentralSource, operation: UUID, sessionID: UUID, controlPlane: AxoControlPlaneSession) async {
        guard let ticket = conversationInputs.pendingTickets.first(where: { CentralEditingTarget($0.command.target).sessionId == sessionID }) else { return }
        await reconcile(ticket, source: source, operation: operation, sessionID: sessionID, controlPlane: controlPlane)
    }

    private func reconcile(_ ticket: CentralInputTicket, source: CentralSource?, operation: UUID, sessionID: UUID?, controlPlane: AxoControlPlaneSession) async {
        let commandID = ticket.command.commandId
        guard reconcilingInputIDs.insert(commandID).inserted else { return }
        defer { reconcilingInputIDs.remove(commandID) }
        guard let source, conversationIsCurrent(operation, source: source, sessionID: sessionID) else { return }
        do {
            let request = try conversationInputs.reconciliation(ticket, source: source)
            let response = try await controlPlane.perform(request)
            guard conversationIsCurrent(operation, source: source, sessionID: sessionID) else { return }
            let result = try conversationInputs.acknowledgeReconciliation(ticket, source: source, response: response)
            switch result {
            case .dispatched:
                conversationNotice = "The exact original Pi command was acknowledged."
            case .rejected:
                conversationNotice = "The exact original Pi command was rejected. Editing is preserved."
            case .missing, .unconfirmed, .outcomeUnknown:
                conversationNotice = "The original Pi command remains unresolved. It will not be replayed."
            }
        } catch {
            guard conversationIsCurrent(operation, source: source, sessionID: sessionID) else { return }
            conversationNotice = "The original Pi command remains unresolved. It will not be replayed."
        }
    }

    private func currentLiveConversationTarget() -> CentralPiBindingTarget? {
        guard isConnected, let source = selectedCatalog?.source,
              case .piObservation(.live(let target, _)) = conversationObservation?.payload,
              conversationObservation?.source == source, target.sessionId == conversationSessionID else { return nil }
        return target
    }

    private func conversationIsCurrent(_ operation: UUID, source: CentralSource, sessionID: UUID?) -> Bool {
        conversationOperation == operation && conversationSessionID == sessionID && selectedCatalog?.source == source
    }

    private func discardConversationEditing() {
        guard let source = catalog?.source, let sessionID = conversationSessionID else { return }
        conversationInputs.discardEditing(for: source, sessionId: sessionID)
    }

    private func setConversationEditorBinding(_ binding: CentralPiBindingTarget?) {
        guard conversationEditorBinding != binding else { return }
        let previous = conversationEditorBinding
        discardConversationEditing()
        conversationEditorBinding = binding
        if previous != nil, binding != nil {
            conversationNotice = "The Pi binding changed. The unsent draft was discarded; close and reopen this conversation before editing."
        }
    }

    private func clearCatalog() {
        discardConversationEditing()
        catalog = nil
        catalogNotice = nil
        conversationSessionID = nil
        conversationPresentationID = nil
        conversationEditorBinding = nil
        conversationSubmissionSupported = false
        conversationOperation = UUID()
        conversationObservation = nil
        conversationHistory = []
        conversationNotice = nil
        isLoadingConversation = false
    }
    private func use(_ credential: AxoControlPlaneAccessCookie) {
        accessCookie = credential
        controlPlane = AxoControlPlaneSession(endpoint: endpoint, accessCookie: credential)
    }

    private func report(_ error: Error) async {
        if case AxoJSONRPCClientError.unauthorized = error {
            await signOut()
            guard accessCookie == nil else { return }
            accessMessage = "Cloudflare Access expired or was denied. Sign in again."
            return
        }
        if let error = error as? AxoJSONRPCClientError {
            switch error {
            case .redirectRejected: notice = "The endpoint redirected to sign-in. Open Cloudflare Access and authorize again."
            case .outcomeUnknown: notice = "Delivery is unknown. No mutation was replayed."
            case .remote(code: -32002, message: _): notice = "The central source or revision changed. Reconnect."
            case .remote(code: -32003, message: _): notice = "The selected machine is offline."
            case .remote(code: -32001, message: _): notice = "The selected host requires compatible negotiation."
            case .remote: notice = "The host rejected the request."
            default: notice = error.localizedDescription
            }
        } else if let error = error as? AxoProtocolValidationError {
            switch error {
            case .staleHost: notice = "The host restarted. Old cached sessions were discarded; reconnect."
            case .staleStore: notice = "The central store changed. Old cached sessions were discarded; reconnect."
            default: notice = "The host returned invalid central session metadata. No data was applied."
            }
        } else if let error = error as? AxoControlPlaneSessionError {
            switch error {
            case .machineOffline: notice = "The selected machine is offline."
            case .superseded: return
            case .noSelectedMachine: notice = "Select an online machine first."
            case .outcomeUnknown: notice = "The original central command has an unknown outcome. No mutation was replayed."
            case .unsupportedMethod, .protocolMismatch: notice = "This daemon does not support central session management. No legacy catalog was used."
            }
        } else { notice = "The private control plane is unavailable. Refresh or reconnect to the selected machine." }
    }

    #if DEBUG
    private var isPreview: Bool { ProcessInfo.processInfo.arguments.contains("--axo-control-plane-preview") }

    private func loadPreview() {
        let onlineID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let offlineID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let restartedID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let generation = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        machines = [MachineSummary(machineId: onlineID, label: "Studio Mac", online: true, hostGeneration: generation),
                    MachineSummary(machineId: offlineID, label: "Travel Mac", online: false, hostGeneration: nil),
                    MachineSummary(machineId: restartedID, label: "Restarted Mac", online: true, hostGeneration: generation)]
        let source = try! CentralSource(machine: .init(machineId: onlineID, hostGeneration: generation), storeGeneration: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!)
        let fixture = try! CentralBrowserPreview.records(source: source, piID: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!)
        catalog = try! CentralCatalog(source: source, revision: CentralRevision(rawValue: 7)!, workspaces: fixture.workspaces, sessions: fixture.sessions)
        selectedMachineID = onlineID; connectedMachineID = onlineID; isConnected = true
        let header = Data(#"{"alg":"none"}"#.utf8).base64URL
        let payload = Data(#"{"aud":"\#(AxoControlPlaneEndpoint.accessAudience)","exp":4102444800,"type":"app"}"#.utf8).base64URL
        accessCookie = try? AxoControlPlaneAccessCookie("\(header).\(payload).signature")
    }
    #endif
}

#if DEBUG
private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
