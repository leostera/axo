import AxoProtocol
import Foundation

/// Where an account's relay lives: an origin, never a path.
///
/// Parsed once: an endpoint is always `https`, or `http` to a loopback address when the caller
/// opts in (tests against a local Worker), so nothing downstream re-checks the scheme before
/// sending a session token.
public struct RelayEndpoint: Equatable, Sendable {
  public static let production = RelayEndpoint(origin: URL(string: "https://axo.leostera.dev")!)!

  public let origin: URL

  public init?(origin: URL, allowInsecureLoopback: Bool = false) {
    guard let components = URLComponents(url: origin, resolvingAgainstBaseURL: false),
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else { return nil }
    switch components.scheme?.lowercased() {
    case "https": break
    case "http" where allowInsecureLoopback && Self.isLoopback(host): break
    default: return nil
    }
    var normal = components
    normal.path = ""
    guard let url = normal.url else { return nil }
    self.origin = url
  }

  private static func isLoopback(_ host: String) -> Bool {
    host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
  }

  public var meURL: URL { url("/api/auth/me") }
  public var tokenURL: URL { url("/api/auth/token") }
  public var logoutURL: URL { url("/api/auth/logout") }

  /// Where the system browser starts sign-in. `challenge` is the PKCE challenge of a secret that
  /// stays in the app, so only this app can finish the sign-in it started.
  public func signInURL(challenge: String) -> URL {
    var components = URLComponents(url: url("/api/auth/cloudflare/start"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "client", value: "native"),
      URLQueryItem(name: "challenge", value: challenge),
    ]
    return components.url!
  }
  /// Where a signed-in account asks for a code that links a new Mac to it.
  public var hostPairingsURL: URL { url("/api/v1/account/host-pairings") }

  /// The account's one socket for this client (RFD0018): every host and Session, through the
  /// client's own Durable Object.
  public func accountClientSocketURL(clientID: ClientID) -> URL {
    var components = URLComponents(url: url("/api/v1/account/client"), resolvingAgainstBaseURL: false)!
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    components.queryItems = [URLQueryItem(name: "clientId", value: clientID.rawValue)]
    return components.url!
  }

  /// A client's socket on one host's HostDO (RFD0032, protocol 3).
  public func hostClientSocketURL(host: UUID, clientID: ClientID) -> URL {
    var components = URLComponents(
      url: url("/api/v1/account/hosts/\(host.uuidString.lowercased())/client"), resolvingAgainstBaseURL: false)!
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    components.queryItems = [URLQueryItem(name: "clientId", value: clientID.rawValue)]
    return components.url!
  }

  /// Settings › Apps' API: `/api/v1/account/apps` and the routes under it.
  public func appsURL(_ path: String = "", query: [URLQueryItem] = []) -> URL {
    var components = URLComponents(url: url("/api/v1/account/apps" + path), resolvingAgainstBaseURL: false)!
    components.queryItems = query.isEmpty ? nil : query
    return components.url!
  }

  /// One of the account's assets (RFD0030), by the 64 hex digits of its SHA-256.
  public func assetURL(hex: String) -> URL { url("/api/v1/account/assets/\(hex)") }

  /// A page of the web app, at this origin.
  public func webURL(_ path: String) -> URL { url(path) }

  private func url(_ path: String) -> URL {
    var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
    components.path = path
    return components.url!
  }
}

/// Which client of the account a socket is: one per app install, so a reconnect replaces the
/// last socket instead of adding one. Unguessable, and as the ClientDO names it.
public struct ClientID: Hashable, Sendable {
  public let rawValue: String

  /// Fails unless `rawValue` is 8 to 64 letters, digits, `-` or `_`.
  public init?(rawValue: String) {
    guard (8...64).contains(rawValue.count),
      rawValue.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" })
    else { return nil }
    self.rawValue = rawValue
  }

  /// A new random client id.
  public static func random() -> ClientID {
    ClientID(rawValue: "ios-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())!
  }
}
