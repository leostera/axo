import CryptoKit
import Foundation

/// A sign-in the app has started: where to send the system browser, and the secret that proves
/// this app (and no one who saw the redirect) is the one finishing it.
public struct SignInAttempt: Sendable {
  public let url: URL
  fileprivate let verifier: String
}

/// What a finished sign-in gives the app.
public struct SignedInSession: Equatable, Sendable {
  public let token: SessionToken
  public let accountID: UUID
  public let expiresAt: Date
}

public enum SignInError: Error, Equatable, LocalizedError {
  /// The person closed the sheet or said no.
  case cancelled
  /// The link the browser returned was not this sign-in's callback.
  case invalidCallback
  /// The relay would not trade the code: used, expired, or for another secret.
  case refused

  public var errorDescription: String? {
    switch self {
    case .cancelled: "Sign-in was cancelled."
    case .invalidCallback: "Sign-in returned an unexpected link."
    case .refused: "Sign-in could not be completed. Try again."
    }
  }
}

/// Signing in from the app: the system browser proves who the person is to Cloudflare and the
/// Worker; the app gets back a one-time code on its own link and trades it, with a secret that
/// never left the app, for a session token. The token never travels in a URL.
public struct NativeSignIn: Sendable {
  /// The scheme the app registers for the callback, `axo://auth/callback`.
  public static let callbackScheme = "axo"

  private let endpoint: RelayEndpoint
  private let loader: any HTTPDataLoading
  private let randomBytes: @Sendable () -> [UInt8]

  public init(
    endpoint: RelayEndpoint = .production,
    loader: any HTTPDataLoading = RelayCredentials.makeURLSession(),
    randomBytes: @escaping @Sendable () -> [UInt8] = {
      var generator = SystemRandomNumberGenerator()
      return (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
  ) {
    self.endpoint = endpoint
    self.loader = loader
    self.randomBytes = randomBytes
  }

  public func begin() -> SignInAttempt {
    let verifier = Self.base64URL(Data(randomBytes()))
    let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    return SignInAttempt(url: endpoint.signInURL(challenge: challenge), verifier: verifier)
  }

  /// Finishes `attempt` with the link the browser came back on.
  public func complete(_ attempt: SignInAttempt, callback: URL) async throws -> SignedInSession {
    let code = try Self.code(in: callback)
    var request = URLRequest(url: endpoint.tokenURL)
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(Exchange(code: code, verifier: attempt.verifier))

    let (data, response): (Data, HTTPURLResponse)
    do {
      (data, response) = try await loader.load(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AxoClientError.connectionFailed(error.localizedDescription)
    }
    switch response.statusCode {
    case 200: break
    case 400: throw SignInError.refused
    case let status: throw RelayError.httpStatus(status)
    }
    guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
      let token = SessionToken(answer.token), token.accountID == answer.accountId,
      let expiresAt = Self.date(answer.expiresAt)
    else { throw AxoClientError.invalidResponse("the relay's sign-in answer was not a session") }
    return SignedInSession(token: token, accountID: answer.accountId, expiresAt: expiresAt)
  }

  private static func code(in callback: URL) throws -> String {
    guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
      components.scheme == callbackScheme, components.host == "auth", components.path == "/callback"
    else { throw SignInError.invalidCallback }
    let items = Dictionary(
      (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
      uniquingKeysWith: { first, _ in first })
    if items["error"] != nil { throw SignInError.cancelled }
    guard let code = items["code"], !code.isEmpty, code.count <= 256,
      code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
    else { throw SignInError.invalidCallback }
    return code
  }

  private static func date(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private struct Exchange: Encodable {
    let code: String
    let verifier: String
  }

  private struct Answer: Decodable {
    let token: String
    let accountId: UUID
    let expiresAt: String
  }
}
