import CryptoKit
import Foundation

public enum CompanionError: Error, LocalizedError {
  case invalidMessage, phoneUnavailable, unauthorized, storage(Int32), server(Int)

  public var errorDescription: String? {
    switch self {
    case .invalidMessage: "Could not read the iPhone sign-in. Open Axo on your iPhone and try again."
    case .phoneUnavailable: "Open Axo on your paired iPhone to sync your sign-in."
    case .unauthorized: "Sign in to Axo on your iPhone."
    case .storage: "Could not securely save your sign-in. Unlock your Watch and try again."
    case .server(let status): "Axo returned HTTP \(status). Try again shortly."
    }
  }
}

/// The iPhone's native sign-in, parsed before crossing a network or storage boundary. It has
/// exactly the same authority and revocation as the phone, not a separate Watch credential.
public struct CompanionSession: Codable, Equatable, Sendable {
  public let token: String
  public let accountID: UUID

  public init(token: String) throws {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "axo1", let account = UUID(uuidString: String(parts[1])),
      account.uuidString.lowercased() == parts[1], Self.isSecret(String(parts[2]))
    else { throw CompanionError.invalidMessage }
    self.token = token
    accountID = account
  }

  public init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(token: fields.decode(String.self, forKey: .token))
    guard try fields.decode(UUID.self, forKey: .accountID) == accountID else { throw CompanionError.invalidMessage }
  }

  private static func isSecret(_ text: String) -> Bool {
    guard text.count == 43,
      let bytes = Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
    else { return false }
    return bytes.count == 32 && encode(bytes) == text
  }

  private static func encode(_ bytes: Data) -> String {
    bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}

public enum CompanionAuthentication: Codable, Equatable, Sendable {
  case signedOut
  case signedIn(CompanionSession)

  public var session: CompanionSession? {
    if case .signedIn(let session) = self { return session }
    return nil
  }

  /// Only this irreversible fingerprint and ordering metadata enter phone defaults, never tokens.
  var fingerprint: String {
    switch self {
    case .signedOut: "signed-out"
    case .signedIn(let session): SHA256.hash(data: Data(session.token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
  }
}

/// Ordered by the phone, not wall clocks. A new phone install has a new authority ID and must
/// answer a live Watch request before any of its queued contexts can authorize the Watch.
public struct CompanionSnapshot: Codable, Equatable, Sendable {
  public let authority: UUID
  public let revision: Int64
  public let authentication: CompanionAuthentication

  public init(authority: UUID, revision: Int64, authentication: CompanionAuthentication) throws {
    guard revision > 0 else { throw CompanionError.invalidMessage }
    self.authority = authority
    self.revision = revision
    self.authentication = authentication
  }

  public init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(authority: fields.decode(UUID.self, forKey: .authority), revision: fields.decode(Int64.self, forKey: .revision),
      authentication: fields.decode(CompanionAuthentication.self, forKey: .authentication))
  }
}

/// Persist signed-out snapshots too: an old queued sign-in must not resurrect a logged-out Watch.
public struct CompanionLoginState: Codable, Equatable, Sendable {
  public private(set) var snapshot: CompanionSnapshot?
  public var session: CompanionSession? { snapshot?.authentication.session }

  public init() {}

  @discardableResult
  public mutating func receive(_ incoming: CompanionSnapshot, authoritative: Bool) -> Bool {
    if let current = snapshot, current.authority == incoming.authority {
      guard incoming.revision > current.revision else { return false }
    } else if !authoritative {
      return false
    }
    snapshot = incoming
    return true
  }

  /// A server refusal drops authority immediately. The next live phone reply must reauthorize.
  public mutating func invalidate() { snapshot = nil }
}

public struct CompanionAccount: Decodable, Equatable, Sendable {
  public let accountId: UUID
  public let profile: Profile?

  public struct Profile: Decodable, Equatable, Sendable {
    public let email: String?
    public let name: String?
  }

  public var displayName: String { profile?.name ?? profile?.email ?? "Your Axo account" }
}

/// The first authenticated request from the Watch. Uses the existing native account API, not
/// host registration. Call again on foreground and periodically while active to detect revocation.
public struct CompanionAccountClient: Sendable {
  private let session: URLSession

  public init(session: URLSession = .shared) { self.session = session }

  public func account(using credential: CompanionSession) async throws -> CompanionAccount {
    var request = URLRequest(url: URL(string: "https://axo.leostera.dev/api/auth/me")!)
    request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await session.data(for: request, delegate: NoCompanionRedirects())
    guard let http = response as? HTTPURLResponse else { throw CompanionError.invalidMessage }
    switch http.statusCode {
    case 200: break
    case 401, 403: throw CompanionError.unauthorized
    default: throw CompanionError.server(http.statusCode)
    }
    let account = try JSONDecoder().decode(CompanionAccount.self, from: data)
    guard account.accountId == credential.accountID else { throw CompanionError.invalidMessage }
    return account
  }
}

private final class NoCompanionRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
