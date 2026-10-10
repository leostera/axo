import AxoProtocol
import Foundation

public enum AxoJSONRPCClientError: Error, Equatable, Sendable, LocalizedError {
    case invalidMethod
    case frameTooLarge
    case pendingCallLimit
    case disconnected
    case cancelled
    case redirectRejected
    case unauthorized(statusCode: Int)
    case unexpectedHTTPStatus(Int)
    case unexpectedContentType
    case malformedResponse
    case mismatchedResponseID
    case outcomeUnknown(requestID: String)
    case remote(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidMethod: "The JSON-RPC method name is invalid."
        case .frameTooLarge: "The JSON-RPC frame exceeded the profile limit."
        case .pendingCallLimit: "Too many JSON-RPC calls are already in flight."
        case .disconnected: "The control-plane connection is closed."
        case .cancelled: "The control-plane request was cancelled."
        case .redirectRejected: "The control-plane endpoint returned a redirect."
        case .unauthorized: "Cloudflare Access authorization is required or expired."
        case .unexpectedHTTPStatus(let status): "The control-plane returned HTTP \(status)."
        case .unexpectedContentType: "The control-plane did not return JSON."
        case .malformedResponse: "The control-plane returned an invalid JSON-RPC response."
        case .mismatchedResponseID: "The control-plane response did not match its request."
        case .outcomeUnknown: "The request outcome is unknown. Reconcile before retrying a mutation."
        case .remote(_, let message): message
        }
    }

    public var isOutcomeUnknown: Bool {
        switch self {
        case .outcomeUnknown, .remote(code: -32004, message: _): true
        default: false
        }
    }
}

/// A bounded JSON-RPC 2.0 client shared by AxoMac and AxoPhone. Authentication is caller-owned.
public struct AxoJSONRPCClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = Self.sessionConfiguration()
        self.session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }

    init(session: URLSession) {
        self.session = session
    }

    public func callHTTP(
        endpoint: AxoControlPlaneEndpoint,
        accessCookie: AxoControlPlaneAccessCookie,
        method: String,
        parameters: some Encodable & Sendable,
        timeout: TimeInterval = 10
    ) async throws -> JSONValue {
        try Self.validateMethod(method)
        guard accessCookie.expiresAt > .now else {
            throw AxoJSONRPCClientError.unauthorized(statusCode: 401)
        }
        let requestID = UUID().uuidString.lowercased()
        let params = try Self.jsonValue(parameters)
        let rpcRequest = RPCRequest(id: .string(requestID), method: method, params: params)
        let body = try JSONEncoder().encode(rpcRequest)
        guard body.count <= AxoProtocolCodec.maximumFrameBytes else {
            throw AxoJSONRPCClientError.frameTooLarge
        }

        var request = URLRequest(url: endpoint.rpcURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.boundedTimeout(timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(accessCookie.cookieHeaderValue, forHTTPHeaderField: "Cookie")
        request.httpBody = body

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw AxoJSONRPCClientError.malformedResponse
            }
            switch response.statusCode {
            case 200: break
            case 401, 403: throw AxoJSONRPCClientError.unauthorized(statusCode: response.statusCode)
            case 300..<400: throw AxoJSONRPCClientError.redirectRejected
            default: throw AxoJSONRPCClientError.unexpectedHTTPStatus(response.statusCode)
            }
            guard response.mimeType?.lowercased() == "application/json" else {
                throw AxoJSONRPCClientError.unexpectedContentType
            }

            let data = try await Self.readBounded(bytes)
            let frame = try AxoProtocolCodec.decodeResponses(String(decoding: data, as: UTF8.self))
            guard !frame.isBatch, frame.responses.count == 1 else {
                throw AxoJSONRPCClientError.malformedResponse
            }
            return try Self.result(frame.responses[0], requestID: requestID)
        } catch let error as AxoJSONRPCClientError {
            throw error
        } catch is CancellationError {
            throw AxoJSONRPCClientError.cancelled
        } catch {
            if Task.isCancelled { throw AxoJSONRPCClientError.cancelled }
            // A request may have reached the service before transport failure; callers must not replay it blindly.
            throw AxoJSONRPCClientError.outcomeUnknown(requestID: requestID)
        }
    }

    public func openWebSocket(
        endpoint: AxoControlPlaneEndpoint,
        machineID: UUID,
        accessCookie: AxoControlPlaneAccessCookie
    ) throws -> AxoJSONRPCWebSocketConnection {
        guard accessCookie.expiresAt > .now else {
            throw AxoJSONRPCClientError.unauthorized(statusCode: 401)
        }
        return try AxoJSONRPCWebSocketConnection(
            url: endpoint.clientSocketURL(machineID: machineID),
            accessCookie: accessCookie
        )
    }

    fileprivate static func validateMethod(_ method: String) throws {
        guard !method.isEmpty, method.utf16.count <= 128 else {
            throw AxoJSONRPCClientError.invalidMethod
        }
    }

    fileprivate static func jsonValue<Value: Encodable & Sendable>(_ value: Value) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    fileprivate static func result(_ response: RPCResponse, requestID: String) throws -> JSONValue {
        switch response {
        case .result(let responseID, let value):
            guard responseID == .string(requestID) else { throw AxoJSONRPCClientError.mismatchedResponseID }
            return value
        case .failure(let responseID, let error):
            guard responseID == .string(requestID) else { throw AxoJSONRPCClientError.mismatchedResponseID }
            throw AxoJSONRPCClientError.remote(code: error.code, message: error.message)
        }
    }

    fileprivate static func boundedTimeout(_ requested: TimeInterval) -> TimeInterval {
        min(max(requested, 0.1), AxoProtocol.maximumCallDurationSeconds)
    }

    fileprivate static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = AxoProtocol.maximumCallDurationSeconds
        configuration.timeoutIntervalForResource = AxoProtocol.maximumCallDurationSeconds
        return configuration
    }

    private static func readBounded(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        data.reserveCapacity(4_096)
        for try await byte in bytes {
            guard data.count < AxoProtocolCodec.maximumFrameBytes else {
                throw AxoJSONRPCClientError.frameTooLarge
            }
            data.append(byte)
        }
        return data
    }
}

public actor AxoJSONRPCWebSocketConnection {
    private struct PendingCall {
        let continuation: CheckedContinuation<JSONValue, Error>
        var deadline: Task<Void, Never>?
    }

    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let accessCookie: AxoControlPlaneAccessCookie
    private var receiver: Task<Void, Never>?
    private var pending: [String: PendingCall] = [:]
    private var isClosed = false

    fileprivate init(url: URL, accessCookie: AxoControlPlaneAccessCookie) throws {
        guard url.scheme == "wss", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw ProtocolError.invalidEndpoint
        }
        let configuration = AxoJSONRPCClient.sessionConfiguration()
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        self.accessCookie = accessCookie
        var request = URLRequest(url: url)
        request.timeoutInterval = AxoProtocol.maximumCallDurationSeconds
        request.setValue(accessCookie.cookieHeaderValue, forHTTPHeaderField: "Cookie")
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = AxoProtocolCodec.maximumFrameBytes
        socket.resume()
    }

    public func request(
        method: String,
        parameters: some Encodable & Sendable,
        timeout: TimeInterval = 10
    ) async throws -> JSONValue {
        try AxoJSONRPCClient.validateMethod(method)
        guard !isClosed else { throw AxoJSONRPCClientError.disconnected }
        guard accessCookie.expiresAt > .now else {
            await close()
            throw AxoJSONRPCClientError.unauthorized(statusCode: 401)
        }
        guard pending.count < AxoProtocol.maximumPendingCalls else { throw AxoJSONRPCClientError.pendingCallLimit }
        ensureReceiver()

        let requestID = UUID().uuidString.lowercased()
        let params = try AxoJSONRPCClient.jsonValue(parameters)
        let request = RPCRequest(id: .string(requestID), method: method, params: params)
        let data = try JSONEncoder().encode(request)
        guard data.count <= AxoProtocolCodec.maximumFrameBytes else {
            throw AxoJSONRPCClientError.frameTooLarge
        }
        let raw = String(decoding: data, as: UTF8.self)
        let socket = self.socket
        let deadline = AxoJSONRPCClient.boundedTimeout(timeout)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                    } catch { return }
                    await self?.expire(requestID)
                }
                pending[requestID] = PendingCall(continuation: continuation, deadline: timeoutTask)
                Task { [weak self] in
                    do { try await socket.send(.string(raw)) }
                    catch { await self?.fail(requestID, with: .outcomeUnknown(requestID: requestID)) }
                }
            }
        } onCancel: {
            Task { await self.cancel(requestID) }
        }
    }

    public func sendNotification(method: String, parameters: JSONValue? = nil) async throws {
        try AxoJSONRPCClient.validateMethod(method)
        guard !isClosed else { throw AxoJSONRPCClientError.disconnected }
        guard accessCookie.expiresAt > .now else {
            await close()
            throw AxoJSONRPCClientError.unauthorized(statusCode: 401)
        }
        ensureReceiver()
        let notification = RPCRequest(method: method, params: parameters)
        let data = try JSONEncoder().encode(notification)
        guard data.count <= AxoProtocolCodec.maximumFrameBytes else {
            throw AxoJSONRPCClientError.frameTooLarge
        }
        do { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
        catch { throw AxoJSONRPCClientError.disconnected }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        receiver?.cancel()
        receiver = nil
        socket.cancel(with: .goingAway, reason: nil)
        failAll(with: .disconnected)
        session.invalidateAndCancel()
    }

    private func ensureReceiver() {
        guard receiver == nil, !isClosed else { return }
        receiver = Task { [weak self] in await self?.receiveLoop() }
    }

    private func receiveLoop() async {
        while !Task.isCancelled, !isClosed {
            do {
                let message = try await socket.receive()
                guard !Task.isCancelled, !isClosed else { return }
                let raw: String
                switch message {
                case .string(let text): raw = text
                case .data: throw AxoJSONRPCClientError.malformedResponse
                @unknown default: throw AxoJSONRPCClientError.malformedResponse
                }
                let frame = try AxoProtocolCodec.decodeResponses(raw)
                try await acknowledgeConsumedFrame()
                for response in frame.responses { resolve(response) }
            } catch {
                guard !Task.isCancelled, !isClosed else { return }
                isClosed = true
                socket.cancel(with: .protocolError, reason: nil)
                failAll(with: error as? AxoJSONRPCClientError ?? .disconnected)
                session.invalidateAndCancel()
                return
            }
        }
    }

    private func acknowledgeConsumedFrame() async throws {
        let parameters = TransportAcknowledgement(frames: 1)
        let value = try AxoJSONRPCClient.jsonValue(parameters)
        let request = RPCRequest(method: AxoProtocol.Method.acknowledgeTransport, params: value)
        let data = try JSONEncoder().encode(request)
        guard data.count <= AxoProtocolCodec.maximumFrameBytes else {
            throw AxoJSONRPCClientError.frameTooLarge
        }
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func resolve(_ response: RPCResponse) {
        let requestID: String
        switch response {
        case .result(let id, _), .failure(let id, _):
            guard case .string(let value) = id else { return }
            requestID = value
        }
        guard let call = pending.removeValue(forKey: requestID) else { return }
        call.deadline?.cancel()
        do { call.continuation.resume(returning: try AxoJSONRPCClient.result(response, requestID: requestID)) }
        catch { call.continuation.resume(throwing: error) }
    }

    private func expire(_ requestID: String) {
        fail(requestID, with: .outcomeUnknown(requestID: requestID))
    }

    private func cancel(_ requestID: String) {
        fail(requestID, with: .outcomeUnknown(requestID: requestID))
    }

    private func fail(_ requestID: String, with error: AxoJSONRPCClientError) {
        guard let call = pending.removeValue(forKey: requestID) else { return }
        call.deadline?.cancel()
        call.continuation.resume(throwing: error)
    }

    private func failAll(with error: AxoJSONRPCClientError) {
        let calls = pending
        pending.removeAll()
        for (requestID, call) in calls {
            call.deadline?.cancel()
            let failure = error.isOutcomeUnknown ? error : .outcomeUnknown(requestID: requestID)
            call.continuation.resume(throwing: failure)
        }
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
