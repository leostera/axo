import Foundation

/// An Axo session token, `axo1.<account id>.<secret>`, as the Worker issued it.
///
/// Parsed once: the account is a UUID and the secret is exactly 32 bytes of canonical unpadded
/// base64url, so a value of this type can go in a header without escaping, and a stray newline
/// cannot split the request.
public struct SessionToken: Equatable, Sendable {
  public let value: String
  public let accountID: UUID

  public init?(_ value: String) {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "axo1", let account = UUID(uuidString: String(parts[1])),
      account.uuidString.lowercased() == parts[1],
      Self.isCanonicalSecret(String(parts[2]))
    else { return nil }
    self.value = value
    self.accountID = account
  }

  /// 32 bytes as 43 base64url characters, the last of which carries only two bits.
  private static func isCanonicalSecret(_ text: String) -> Bool {
    guard text.count == 43, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    else { return false }
    let base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
    guard let bytes = Data(base64Encoded: base64), bytes.count == 32 else { return false }
    let canonical = bytes.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return canonical == text
  }
}

/// Where the current session token comes from: the sign-in on a phone, a test fixture
/// elsewhere. Asked for before every request, so a fresh sign-in is used at once.
public protocol SessionTokenProvider: Sendable {
  /// Fails with `RelayError.signInRequired` when there is no signed-in session.
  func sessionToken() async throws -> SessionToken
}

public struct StaticSessionToken: SessionTokenProvider {
  private let token: SessionToken

  public init(_ token: SessionToken) {
    self.token = token
  }

  public func sessionToken() async throws -> SessionToken { token }
}

/// How native clients identify themselves to the relay: a bearer token, never cookies. A token
/// is not ambient the way a cookie is, so no other site can make the app send it, and a browser
/// session on the same device cannot be mistaken for the app's.
public enum RelayCredentials {
  public static func authorize(_ request: URLRequest, with tokens: any SessionTokenProvider)
    async throws -> URLRequest
  {
    var request = request
    request.setValue("Bearer \(try await tokens.sessionToken().value)", forHTTPHeaderField: "Authorization")
    request.httpShouldHandleCookies = false
    return request
  }

  /// A session that stores no cookies and caches nothing.
  public static func makeURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }
}
