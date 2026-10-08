import Foundation
import Observation

@MainActor @Observable
public final class ConversationClient {
    public enum LinkState: Equatable { case disconnected, connecting, online, macOffline, failed(String) }
    public private(set) var link: LinkState = .disconnected
    public private(set) var snapshot: Snapshot?
    public private(set) var pendingID: String?
    public private(set) var pendingCancellationID: String?
    public private(set) var activityEvents: [AgentEvent] = []
    public private(set) var droppedEventCount = 0
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
                    self?.apply(try RelayEvent.decode(data))
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
        receiver?.cancel()
        receiver = nil
        heartbeat?.cancel()
        heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
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

    private func apply(_ event: RelayEvent) {
        switch event {
        case .snapshot(let value):
            reconnectAttempt = 0
            if eventSessionID != value.sessionId {
                eventSessionID = value.sessionId
                activityEvents = []
                seenEventIDs = []
            }
            for event in value.events ?? [] where seenEventIDs.insert(event.id).inserted {
                activityEvents.append(event)
                if activityEvents.count > 500 {
                    seenEventIDs.remove(activityEvents.removeFirst().id)
                }
            }
            droppedEventCount = value.droppedEvents ?? 0
            snapshot = value
            link = .online
        case .presence(let online):
            reconnectAttempt = 0
            link = online ? .online : .macOffline
            if !online { snapshot = nil }
        case .acknowledged(let id, let cancelled):
            guard id == pendingID else { return }
            lastAcknowledgedID = id
            pendingID = nil
            pendingCancellationID = nil
            notice = cancelled ? "Cancellation requested." : "Submitted to Pi."
        case .error(let id, let message):
            if id == nil || id == pendingID {
                pendingID = nil
                pendingCancellationID = nil
                notice = message
            }
        }
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
