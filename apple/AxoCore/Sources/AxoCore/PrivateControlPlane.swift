import AxoProtocol
import Foundation

public struct AxoControlPlaneEndpoint: Equatable, Sendable {
    public static let production = try! AxoControlPlaneEndpoint("https://api.axo.leostera.dev")
    public static let accessAudience = "b4ce8a1f58bff7fd09c1d2b64fdbbd7a2098df4a0e46850b78caa05783676073"

    public let baseURL: URL

    public init(_ origin: String) throws {
        guard let url = URL(string: origin), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { throw ProtocolError.invalidEndpoint }
        baseURL = url
    }

    public var rpcURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/v1/rpc"
        return components.url!
    }

    public func clientSocketURL(machineID: UUID) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        components.path = "/v1/machines/\(machineID.uuidString.lowercased())/client"
        return components.url!
    }
}

/// A structurally checked JWT for the new API's Access application, not the legacy relay.
/// This local audience/expiry check prevents credential mix-ups; Cloudflare and the Worker verify its signature.
public struct AxoControlPlaneAccessCookie: Equatable, Sendable {
    private let jwt: String
    public let expiresAt: Date

    public init(_ jwt: String, now: Date = .now) throws {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard jwt.utf8.count <= 16_384, segments.count == 3,
              segments.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(Self.isBase64URLByte) }),
              let payload = Self.decodePayload(String(segments[1])),
              let claims = try? JSONDecoder().decode(AccessClaims.self, from: payload),
              claims.type == "app",
              claims.audiences.contains(AxoControlPlaneEndpoint.accessAudience),
              claims.exp > now.timeIntervalSince1970
        else { throw AccessCookieError.invalidOrExpired }
        self.jwt = jwt
        self.expiresAt = Date(timeIntervalSince1970: claims.exp)
    }

    var cookieHeaderValue: String { "CF_Authorization=\(jwt)" }
    public var valueForKeychainStorage: String { jwt }

    private struct AccessClaims: Decodable {
        enum Audience: Decodable {
            case one(String)
            case many([String])

            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let single = try? value.decode(String.self) {
                    self = .one(single)
                } else {
                    self = .many(try value.decode([String].self))
                }
            }
        }

        let aud: Audience
        let exp: TimeInterval
        let type: String

        var audiences: Set<String> {
            switch aud {
            case .one(let value): [value]
            case .many(let values): Set(values)
            }
        }
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
    }

    private static func decodePayload(_ segment: String) -> Data? {
        var base64 = segment.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

public enum AccessCookieError: Error, Equatable, Sendable, LocalizedError {
    case invalidOrExpired

    public var errorDescription: String? {
        "Sign in to the Axo private control plane again."
    }
}

public enum AxoControlPlaneSessionError: Error, Equatable, Sendable, LocalizedError {
    case machineOffline(UUID)
    case noSelectedMachine
    case superseded
    case protocolMismatch

    public var errorDescription: String? {
        switch self {
        case .machineOffline: "This machine is offline. Runtime data shown here is historical."
        case .noSelectedMachine: "Select an online machine before listing runtimes."
        case .superseded: "The selected machine changed while the request was in flight."
        case .protocolMismatch: "The host and client do not support the same control protocol."
        }
    }
}

/// Read-only discovery and runtime browsing for the v1 profile; it never retries or replays a mutation.
public actor AxoControlPlaneSession {
    private let endpoint: AxoControlPlaneEndpoint
    private let accessCookie: AxoControlPlaneAccessCookie
    private let rpc: AxoJSONRPCClient
    private var connection: AxoJSONRPCWebSocketConnection?
    private var target: MachineTarget?
    private var operationID = UUID()

    public init(
        endpoint: AxoControlPlaneEndpoint = .production,
        accessCookie: AxoControlPlaneAccessCookie,
        rpc: AxoJSONRPCClient = AxoJSONRPCClient()
    ) {
        self.endpoint = endpoint
        self.accessCookie = accessCookie
        self.rpc = rpc
    }

    public func discoverMachines() async throws -> MachineListResult {
        let value = try await rpc.callHTTP(
            endpoint: endpoint,
            accessCookie: accessCookie,
            method: AxoProtocol.Method.listMachines,
            parameters: EmptyRPCParameters()
        )
        return try AxoProtocolResultValidator.machineList(value)
    }

    public func connect(to machine: MachineSummary) async throws -> RuntimeListResult {
        guard machine.online, let hostGeneration = machine.hostGeneration else {
            throw AxoControlPlaneSessionError.machineOffline(machine.machineId)
        }
        let destination = MachineTarget(machineId: machine.machineId, hostGeneration: hostGeneration)
        let thisOperation = UUID()
        operationID = thisOperation
        let oldConnection = connection
        connection = nil
        target = destination
        await oldConnection?.close()
        try requireCurrent(thisOperation, destination: destination)

        do {
            let directory = try await discoverMachines()
            try requireCurrent(thisOperation, destination: destination)
            guard let currentMachine = directory.machines.first(where: { $0.machineId == machine.machineId }),
                  currentMachine.online, let currentGeneration = currentMachine.hostGeneration else {
                throw AxoControlPlaneSessionError.machineOffline(machine.machineId)
            }
            guard currentGeneration == hostGeneration else {
                throw AxoProtocolValidationError.staleHost(expected: hostGeneration, actual: currentGeneration)
            }
        } catch {
            if operationID == thisOperation { target = nil }
            throw error
        }

        let newConnection: AxoJSONRPCWebSocketConnection
        do {
            newConnection = try rpc.openWebSocket(
                endpoint: endpoint,
                machineID: machine.machineId,
                accessCookie: accessCookie
            )
        } catch {
            if operationID == thisOperation { target = nil }
            throw error
        }
        connection = newConnection
        do {
            let negotiation = try await newConnection.request(
                method: AxoProtocol.Method.negotiate,
                parameters: NegotiationParameters()
            )
            do { _ = try AxoProtocolResultValidator.negotiation(negotiation) }
            catch { throw AxoControlPlaneSessionError.protocolMismatch }
            try requireCurrent(thisOperation, destination: destination)

            let runtimes = try await newConnection.request(
                method: AxoProtocol.Method.listRuntimes,
                parameters: RuntimeListParameters(target: destination)
            )
            let result = try AxoProtocolResultValidator.runtimeList(runtimes, target: destination)
            try requireCurrent(thisOperation, destination: destination)
            return result
        } catch {
            if operationID == thisOperation {
                connection = nil
                target = nil
            }
            await newConnection.close()
            throw error
        }
    }

    public func refreshRuntimes(after: UUID? = nil) async throws -> RuntimeListResult {
        guard let destination = target, let activeConnection = connection else {
            throw AxoControlPlaneSessionError.noSelectedMachine
        }
        let thisOperation = operationID
        let runtimes = try await activeConnection.request(
            method: AxoProtocol.Method.listRuntimes,
            parameters: RuntimeListParameters(target: destination, after: after)
        )
        let result = try AxoProtocolResultValidator.runtimeList(runtimes, target: destination)
        try requireCurrent(thisOperation, destination: destination, connection: activeConnection)
        return result
    }

    public func disconnect() async {
        operationID = UUID()
        target = nil
        let oldConnection = connection
        connection = nil
        await oldConnection?.close()
    }

    private func requireCurrent(
        _ expectedOperation: UUID,
        destination: MachineTarget,
        connection expectedConnection: AxoJSONRPCWebSocketConnection? = nil
    ) throws {
        guard operationID == expectedOperation, target == destination else {
            throw AxoControlPlaneSessionError.superseded
        }
        if let expectedConnection, connection !== expectedConnection {
            throw AxoControlPlaneSessionError.superseded
        }
    }
}
