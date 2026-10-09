import Foundation
import Observation

public struct ToolOutputState: Equatable, Sendable {
    public var text = ""
    public var nextOffset: Int? = 0
    public var isLoading = false
    public var error: String?
    public init() {}
}

@MainActor @Observable
public final class ConversationClient {
    public enum LinkState: Equatable { case disconnected, connecting, online, macOffline, failed(String) }
    public private(set) var link: LinkState = .disconnected
    public private(set) var snapshot: Snapshot?
    public private(set) var files: SessionFilesClient?
    public private(set) var pendingID: String?
    public private(set) var pendingCancellationID: String?
    public private(set) var activityEvents: [AgentEvent] = []
    public private(set) var droppedEventCount = 0
    public private(set) var messages: [ConversationMessage] = []
    public private(set) var hasEarlierMessages = false
    public private(set) var isLoadingHistory = false
    public private(set) var hasLaterMessages = false
    public var isBrowsingHistory = false
    private var historyViewID: String?
    private var latestSnapshot: Snapshot?
    public private(set) var toolOutputs: [String: ToolOutputState] = [:]
    private var readRequests: [String: PhoneCommand] = [:]
    private var readTimeouts: [String: Task<Void, Never>] = [:]
    public private(set) var lastAcknowledgedID: String?
    public private(set) var notice: String?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var endpoint: RelayEndpoint?
    private var authorizationCookie: String?
    private var reconnectAttempt = 0
    private var shouldReconnect = false
    private var eventSessionID: String?
    private var seenEventIDs = Set<String>()
    private let session = URLSession(configuration: .ephemeral)

    public init() {}

    public var canSend: Bool { link == .online && snapshot != nil && pendingID == nil }

    public func connect(endpoint: RelayEndpoint, authorizationCookie: String) {
        disconnect()
        snapshot = nil
        notice = nil
        self.endpoint = endpoint
        self.authorizationCookie = authorizationCookie
        if files?.matches(endpoint) != true {
            files?.cancelAllUploads()
            files = SessionFilesClient(endpoint: endpoint, cookie: authorizationCookie)
        }
        else { files?.configure(endpoint: endpoint, cookie: authorizationCookie) }
        shouldReconnect = true
        reconnectAttempt = 0
        openSocket()
    }

    public func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        stopActiveSocket()
        endpoint = nil
        authorizationCookie = nil
        if pendingID != nil { notice = "Delivery uncertain. Check the conversation before sending again." }
        pendingID = nil
        pendingCancellationID = nil
        link = .disconnected
    }

    private func openSocket() {
        guard shouldReconnect, let endpoint, let authorizationCookie else { return }
        link = .connecting
        var request = URLRequest(url: endpoint.socketURL)
        request.setValue("CF_Authorization=\(authorizationCookie)", forHTTPHeaderField: "Cookie")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 256 * 1024
        self.socket = socket
        socket.resume()
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let frame = try await socket.receive()
                    let data: Data
                    switch frame {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: throw ProtocolError.malformed
                    }
                    guard self?.socket === socket else { return }
                    do { self?.apply(try RelayEvent.decode(data)) }
                    catch { self?.protocolFailed(for: socket, error: error); return }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.connectionFailed(for: socket)
            }
        }
        heartbeat = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(20))
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        socket.sendPing { error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume() }
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.connectionFailed(for: socket)
            }
        }
    }

    private func stopActiveSocket() {
        for id in Array(readRequests.keys) { failReadRequest(id: id, message: "Connection lost. Try again when connected.") }
        receiver?.cancel()
        receiver = nil
        heartbeat?.cancel()
        heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    public func loadEarlierMessages() { loadHistory(direction: "before") }
    public func loadLaterMessages() { loadHistory(direction: "after") }

    private func loadHistory(direction: String) {
        let available = direction == "before" ? hasEarlierMessages : hasLaterMessages
        let cursor = direction == "before" ? messages.first?.id : messages.last?.id
        guard link == .online, socket != nil, !isLoadingHistory, available,
              let value = snapshot, let cursor else { return }
        isLoadingHistory = true
        sendReadRequest(.history(id: UUID().uuidString, session: value.sessionId,
                                viewId: value.viewId, beforeId: cursor, direction: direction))
    }

    @discardableResult
    public func backToBottom() -> Bool {
        guard let snapshot = latestSnapshot else { notice = "Newest messages unavailable. Reconnect to your Mac."; return false }
        if link != .online { notice = "Showing newest cached messages. Reconnect to refresh." }
        for id in Array(readRequests.keys) where readRequests[id]?.type == "history" { _ = finishReadRequest(id: id) }
        isLoadingHistory = false
        isBrowsingHistory = false
        messages = snapshot.messages
        hasEarlierMessages = snapshot.hasEarlierMessages
        hasLaterMessages = false
        pruneToolOutputs()
        return true
    }

    private func boundHistory(keepingOlder: Bool) {
        var bytes = messages.reduce(0) { $0 + ((try? JSONEncoder().encode($1).count) ?? 0) }
        while messages.count > 200 || bytes > 256 * 1024 {
            let removed = keepingOlder ? messages.removeLast() : messages.removeFirst()
            bytes -= (try? JSONEncoder().encode(removed).count) ?? 0
            if keepingOlder { hasLaterMessages = true } else { hasEarlierMessages = true }
        }
        pruneToolOutputs()
    }

    private func pruneToolOutputs() {
        let visibleTools = Set(messages.compactMap(\.toolCallId))
        for id in Array(toolOutputs.keys) where !visibleTools.contains(id) { toolOutputs.removeValue(forKey: id) }
    }

    public func loadToolOutput(toolCallId: String) {
        guard link == .online, socket != nil, let session = snapshot?.sessionId else { return }
        var output = toolOutputs[toolCallId] ?? ToolOutputState()
        guard !output.isLoading, let offset = output.nextOffset else { return }
        output.isLoading = true
        output.error = nil
        toolOutputs[toolCallId] = output
        sendReadRequest(.toolOutput(id: UUID().uuidString, session: session, toolCallId: toolCallId, offset: offset))
    }

    private func sendReadRequest(_ command: PhoneCommand) {
        guard let id = command.id, let socket else { return }
        readRequests[id] = command
        readTimeouts[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.failReadRequest(id: id, message: "The Mac did not answer. Try again.")
        }
        Task { [weak self] in
            do {
                let data = try JSONEncoder().encode(command)
                try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            } catch { self?.failReadRequest(id: id, message: "Could not request data from the Mac.") }
        }
    }

    private func finishReadRequest(id: String) -> PhoneCommand? {
        readTimeouts.removeValue(forKey: id)?.cancel()
        return readRequests.removeValue(forKey: id)
    }

    private func failReadRequest(id: String, message: String) {
        guard let command = finishReadRequest(id: id) else { return }
        if command.type == "history" {
            isLoadingHistory = false
            notice = message
        }
        if let toolCallId = command.toolCallId {
            toolOutputs[toolCallId]?.isLoading = false
            toolOutputs[toolCallId]?.error = message
        }
    }

    public func cancelAgent(runId: String) {
        guard canSend, let sessionId = snapshot?.sessionId, snapshot?.runId == runId else { return }
        let id = UUID().uuidString
        pendingCancellationID = id
        send(.cancel(id: id, session: sessionId, runId: runId))
    }

    public func send(_ command: PhoneCommand) {
        guard canSend, let socket else { return }
        pendingID = command.id
        notice = nil
        Task {
            do {
                let bytes = try JSONEncoder().encode(command)
                try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
            } catch { connectionFailed(for: socket) }
        }
    }

    func apply(_ event: RelayEvent) {
        switch event {
        case .snapshot(let value):
            reconnectAttempt = 0
            files?.selectSession(value.sessionId)
            if eventSessionID != value.sessionId || historyViewID != value.viewId {
                for id in Array(readRequests.keys) { _ = finishReadRequest(id: id) }
                eventSessionID = value.sessionId
                historyViewID = value.viewId
                activityEvents = []
                seenEventIDs = []
                messages = []
                toolOutputs = [:]
                hasEarlierMessages = value.hasEarlierMessages
                hasLaterMessages = false
                isLoadingHistory = false
            }
            let incomingIds = Set(value.messages.map(\.id))
            let overlaps = !incomingIds.isDisjoint(with: messages.map(\.id))
            if messages.isEmpty || (!overlaps && !isBrowsingHistory) {
                messages = value.messages
                hasEarlierMessages = value.hasEarlierMessages
                hasLaterMessages = false
            } else if overlaps {
                let updates = Dictionary(uniqueKeysWithValues: value.messages.map { ($0.id, $0) })
                let existingIDs = Set(messages.map(\.id))
                messages = messages.map { updates[$0.id] ?? $0 } + value.messages.filter { !existingIDs.contains($0.id) }
            } else {
                // A disjoint tail is ordinary new work, not proof of a different branch.
                hasLaterMessages = true
            }
            boundHistory(keepingOlder: isBrowsingHistory)
            for event in value.events ?? [] where seenEventIDs.insert(event.id).inserted {
                activityEvents.append(event)
                if activityEvents.count > 500 {
                    seenEventIDs.remove(activityEvents.removeFirst().id)
                }
            }
            droppedEventCount = value.droppedEvents ?? 0
            snapshot = value
            latestSnapshot = value
            link = .online
        case .history(let page):
            guard let request = readRequests[page.id], request.type == "history",
                  request.sessionId == snapshot?.sessionId, page.sessionId == snapshot?.sessionId,
                  request.viewId == snapshot?.viewId, page.viewId == snapshot?.viewId,
                  request.beforeId == page.beforeId, request.direction == (page.direction ?? "before") else { return }
            _ = finishReadRequest(id: page.id)
            isLoadingHistory = false
            let ids = Set(messages.map(\.id))
            let additions = page.messages.filter { !ids.contains($0.id) }
            if page.direction == "after" {
                messages += additions
                hasLaterMessages = page.hasLaterMessages
                boundHistory(keepingOlder: false)
            } else {
                messages = additions + messages
                hasEarlierMessages = page.hasEarlierMessages
                boundHistory(keepingOlder: true)
            }
        case .toolOutput(let page):
            guard let request = readRequests[page.id], request.type == "tool_output",
                  request.sessionId == snapshot?.sessionId, page.sessionId == snapshot?.sessionId,
                  request.toolCallId == page.toolCallId, request.offset == page.offset else { return }
            _ = finishReadRequest(id: page.id)
            guard var output = toolOutputs[page.toolCallId], output.nextOffset == page.offset else { return }
            output.text += page.text
            output.nextOffset = page.nextOffset
            output.isLoading = false
            output.error = nil
            toolOutputs[page.toolCallId] = output
        case .filesChanged(let sessionId, let revision):
            files?.invalidate(sessionId: sessionId, revision: revision)
        case .presence(let online):
            // A handshake/presence event is not proof that a usable snapshot arrived.
            link = online ? .online : .macOffline
            if !online { snapshot = nil }
        case .acknowledged(let id, let cancelled):
            guard id == pendingID else { return }
            lastAcknowledgedID = id
            pendingID = nil
            pendingCancellationID = nil
            notice = cancelled ? "Cancellation requested." : "Submitted to Pi."
        case .error(let id, let message):
            if let id, readRequests[id] != nil { failReadRequest(id: id, message: message); return }
            if id == nil || id == pendingID {
                pendingID = nil
                pendingCancellationID = nil
                notice = message
            }
        }
    }

    private func protocolFailed(for failedSocket: URLSessionWebSocketTask, error: Error) {
        guard socket === failedSocket else { return }
        stopActiveSocket()
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        let hadPromptInFlight = pendingID != nil
        pendingID = nil
        pendingCancellationID = nil
        let detail: String
        if case DecodingError.keyNotFound(let key, _) = error {
            detail = "Missing \(key.stringValue)."
        } else {
            detail = "The relay sent an unsupported message."
        }
        let message = "Protocol mismatch. \(detail) Update the relay and reload the Mac bridge, then reconnect."
            + (hadPromptInFlight ? " Delivery of the last prompt is uncertain; check Pi before resending." : "")
        notice = message
        link = .failed(message)
    }

    private func connectionFailed(for failedSocket: URLSessionWebSocketTask) {
        guard socket === failedSocket else { return }
        stopActiveSocket()
        if pendingID != nil { notice = "Delivery uncertain. Check the conversation before sending again." }
        pendingID = nil
        pendingCancellationID = nil
        link = .failed("Connection lost or Access expired. Reconnecting…")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldReconnect, endpoint != nil, authorizationCookie != nil, reconnectTask == nil else { return }
        let delay = min(30, 1 << min(reconnectAttempt, 5))
        reconnectAttempt = min(reconnectAttempt + 1, 5)
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.shouldReconnect else { return }
            self.reconnectTask = nil
            self.openSocket()
        }
    }
}
