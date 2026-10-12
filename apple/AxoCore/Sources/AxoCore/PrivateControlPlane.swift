import AxoProtocol
import Foundation

public struct AxoControlPlaneEndpoint: Equatable, Sendable {
    public static let production = try! AxoControlPlaneEndpoint("https://api.axo.leostera.dev")
    public static let accessAudience = "b4ce8a1f58bff7fd09c1d2b64fdbbd7a2098df4a0e46850b78caa05783676073"
    public let baseURL: URL
    public init(_ origin: String) throws {
        guard let url = URL(string: origin), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw ProtocolError.invalidEndpoint }
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

/// Structurally checked for this Access application, not the legacy relay.
/// Cloudflare and the Worker still verify the signature; local audience/expiry
/// checks prevent credential mix-ups, never establish authentication themselves.
public struct AxoControlPlaneAccessCookie: Equatable, Sendable {
    private let jwt: String
    public let expiresAt: Date
    public init(_ jwt: String, now: Date = .now) throws {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard jwt.utf8.count <= 16_384, segments.count == 3,
              segments.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(Self.isBase64URLByte) }),
              let payload = Self.decodePayload(String(segments[1])),
              let claims = try? JSONDecoder().decode(AccessClaims.self, from: payload), claims.type == "app",
              claims.audiences.contains(AxoControlPlaneEndpoint.accessAudience), claims.exp > now.timeIntervalSince1970
        else { throw AccessCookieError.invalidOrExpired }
        self.jwt = jwt; expiresAt = Date(timeIntervalSince1970: claims.exp)
    }
    var cookieHeaderValue: String { "CF_Authorization=\(jwt)" }
    public var valueForKeychainStorage: String { jwt }
    private struct AccessClaims: Decodable {
        enum Audience: Decodable {
            case one(String), many([String])
            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let single = try? value.decode(String.self) { self = .one(single) }
                else { self = .many(try value.decode([String].self)) }
            }
        }
        let aud: Audience
        let exp: TimeInterval
        let type: String
        var audiences: Set<String> { switch aud { case .one(let value): [value]; case .many(let values): Set(values) } }
    }
    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
    }
    private static func decodePayload(_ segment: String) -> Data? {
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
public enum AccessCookieError: Error, Equatable, Sendable, LocalizedError {
    case invalidOrExpired
    public var errorDescription: String? { "Sign in to the Axo private control plane again." }
}
public enum AxoControlPlaneSessionError: Error, Equatable, Sendable, LocalizedError {
    case machineOffline(UUID), noSelectedMachine, superseded, protocolMismatch
    case unsupportedMethod(String)
    case outcomeUnknown(source: CentralSource, commandId: UUID)
    public var errorDescription: String? {
        switch self {
        case .machineOffline: "This machine is offline. Reconnect before loading central sessions."
        case .noSelectedMachine: "Select an online machine before loading central sessions."
        case .superseded: "The selected authority changed while the request was in flight."
        case .protocolMismatch: "The host does not support central session management."
        case .unsupportedMethod(let method): "This host does not support \(method)."
        case .outcomeUnknown: "The original central command has an unknown outcome. Preserve its source and command ID; do not replay it."
        }
    }
}
