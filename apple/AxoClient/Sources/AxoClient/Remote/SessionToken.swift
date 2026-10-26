import Foundation

/// A Cloudflare Access assertion (a JWT), as it travels in the `cf-access-token` header.
///
/// Parsed once: non-empty and made only of the characters a JWT uses, so it can be put in a
/// header without escaping and a stray newline cannot split the request.
public struct AccessToken: Equatable, Sendable {
  public let value: String

  public init?(_ value: String) {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.=")
    guard !value.isEmpty, value.count <= 16_384,
      value.unicodeScalars.allSatisfy(allowed.contains)
    else { return nil }
    self.value = value
  }
}

/// Where the current Access token comes from: the sign-in flow on a phone, a test fixture
/// elsewhere. Asked for before every request, so a refreshed token is used at once.
public protocol AccessTokenProvider: Sendable {
  /// Fails with `RelayError.signInRequired` when there is no valid session.
  func accessToken() async throws -> AccessToken
}

public struct StaticAccessToken: AccessTokenProvider {
  private let token: AccessToken

  public init(_ token: AccessToken) {
    self.token = token
  }

  public func accessToken() async throws -> AccessToken { token }
}

/// How native clients identify themselves to the relay.
///
/// Access authenticates the caller from the `cf-access-token` header alone. Cookies are never
/// sent or kept, so a browser session on the same device cannot be mistaken for the app's, and
/// the Worker's cookie-free rule for native clients holds.
public enum RelayCredentials {
  public static let header = "cf-access-token"

  public static func authorize(_ request: URLRequest, with tokens: any AccessTokenProvider)
    async throws -> URLRequest
  {
    var request = request
    request.setValue(try await tokens.accessToken().value, forHTTPHeaderField: Self.header)
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
