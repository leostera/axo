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
  public var hostsURL: URL { url("/api/v1/account/hosts") }

  public func sessionsURL(of host: RemoteHostRef) -> URL {
    var components = URLComponents(
      url: url("/api/v1/account/hosts/\(host.hostId.uuidString.lowercased())/sessions"),
      resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "hostGeneration", value: host.hostGeneration.uuidString.lowercased())
    ]
    return components.url!
  }

  /// A page of one Session's stored Pi events, from the event after `cursor`.
  public func piEventsURL(of host: RemoteHostRef, session: SessionID, before cursor: Int64, limit: Int) -> URL {
    var components = URLComponents(
      url: url("/api/v1/account/hosts/\(host.hostId.uuidString.lowercased())/sessions/\(session)/events"),
      resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "before", value: String(cursor)),
      URLQueryItem(name: "limit", value: String(limit)),
    ]
    return components.url!
  }

  /// The WebSocket a person's client opens to reach one host.
  public func clientSocketURL(hostID: UUID) -> URL {
    var components = URLComponents(
      url: url("/api/v1/account/hosts/\(hostID.uuidString.lowercased())/client"),
      resolvingAgainstBaseURL: false)!
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    return components.url!
  }

  private func url(_ path: String) -> URL {
    var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
    components.path = path
    return components.url!
  }
}
