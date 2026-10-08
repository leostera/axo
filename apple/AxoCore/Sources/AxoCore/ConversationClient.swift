import Foundation
import Observation

@MainActor @Observable
public final class ConversationClient {
    public enum LinkState: Equatable { case disconnected, connecting, online, macOffline, failed(String) }
    public private(set) var link: LinkState = .disconnected
    public private(set) var snapshot: Snapshot?
    public private(set) var pendingID: String?
    public private(set) var lastAcknowledgedID: String?
    public private(set) var notice: String?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral)

    public init() {}

    public var canSend: Bool { link == .online && snapshot != nil && pendingID == nil }

    public func connect(endpoint: RelayEndpoint, authorizationCookie: String) {
        disconnect()
        snapshot = nil
        notice = nil
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

    public func disconnect() {
        receiver?.cancel()
        heartbeat?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        if pendingID != nil { notice = "Delivery uncertain. Check the conversation before sending again." }
        pendingID = nil
        link = .disconnected
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
        case .snapshot(let value): snapshot = value; link = .online
        case .presence(let online): link = online ? .online : .macOffline; if !online { snapshot = nil }
        case .acknowledged(let id):
            guard id == pendingID else { return }
            lastAcknowledgedID = id
            pendingID = nil
            notice = "Submitted to Pi. If it is working, your prompt follows the current run."
        case .error(let id, let message):
            if id == nil || id == pendingID { pendingID = nil; notice = message }
        }
    }

    private func connectionFailed(for failedSocket: URLSessionWebSocketTask) {
        guard socket === failedSocket else { return }
        disconnect()
        link = .failed("Connection lost or Access expired. Reconnect or sign in again.")
    }
}
