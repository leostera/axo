import AxoProtocol
import Foundation

/// How `AccountClient` fetches: `URLSession` in the app, a stub in tests.
public protocol HTTPDataLoading: Sendable {
  func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
  /// Like `load`, but fails with `HTTPBodyTooLarge` instead of holding a body longer than
  /// `maximumBytes`.
  func load(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse)
}

/// A response body was longer than the caller accepts.
public struct HTTPBodyTooLarge: Error, Equatable {
  public let maximumBytes: Int
}

extension HTTPDataLoading {
  /// For loaders whose bodies are already in memory, such as test stubs.
  public func load(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await load(request)
    guard data.count <= maximumBytes else { throw HTTPBodyTooLarge(maximumBytes: maximumBytes) }
    return (data, response)
  }
}

extension URLSession: HTTPDataLoading {
  public func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await data(for: request)
    return (data, try Self.http(response))
  }

  /// Streams the body and stops reading at `maximumBytes`, so a huge or endless response never
  /// fills memory.
  public func load(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
    let (bytes, response) = try await bytes(for: request)
    let http = try Self.http(response)
    let tooLarge = HTTPBodyTooLarge(maximumBytes: maximumBytes)
    if response.expectedContentLength > Int64(maximumBytes) { throw tooLarge }
    var data = Data()
    if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
    for try await byte in bytes {
      guard data.count < maximumBytes else { throw tooLarge }
      data.append(byte)
    }
    return (data, http)
  }

  private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else {
      throw AxoClientError.invalidResponse("the relay did not answer over HTTP")
    }
    return http
  }
}

/// Who the relay says the caller is.
public struct SignedInAccount: Decodable, Equatable, Sendable {
  public let accountId: UUID
  /// What the sign-in provider said about the person; either may be missing.
  public let profile: Profile?

  public struct Profile: Decodable, Equatable, Sendable {
    public let email: String?
    public let name: String?

    public init(email: String?, name: String?) {
      self.email = email
      self.name = name
    }
  }

  public init(accountId: UUID, profile: Profile?) {
    self.accountId = accountId
    self.profile = profile
  }
}

public struct AgentNotification: Decodable, Identifiable, Sendable {
  public let id: UUID
  public let hostId: UUID
  public let sessionId: SessionID
  public let title: String
  public let message: String
  public let createdAt: Int64
}

public struct NotificationQuestion: Decodable, Sendable {
  public let elicitation: Elicitation
  public let hostGeneration: UUID
}

/// A code that links one more Mac to the account, until it expires. The Mac redeems it: typed
/// into Axo's Remote Access settings, or opened as `link`.
public struct HostPairing: Equatable, Sendable {
  public let code: HostPairingCode
  public let expiresAt: Date

  public init(code: HostPairingCode, expiresAt: Date) {
    self.code = code
    self.expiresAt = expiresAt
  }

  /// The link the Mac app opens to fill the code in (`axo://pair/<code>`).
  public var link: URL { URL(string: "axo://pair/\(code.value)")! }

  /// The Terminal command that installs Axo on a Mac without it, from the relay at `origin`,
  /// starts it and fills this code in (`sites/axo.leostera.dev/src/install.ts`).
  public func installCommand(origin: URL) -> String {
    let base = origin.absoluteString.hasSuffix("/") ? String(origin.absoluteString.dropLast()) : origin.absoluteString
    return "curl -fsSL '\(base)/install?code=\(code.value)' | sh"
  }
}

/// Who can ask the relay for a pairing code: `AccountClient`, or a stand-in.
public protocol HostPairingIssuing: Sendable {
  func createHostPairing() async throws -> HostPairing
}

/// The account over HTTPS: who is signed in, signing out, and pairing codes. Hosts and Sessions
/// come over the account's socket (`AccountConnection`).
public struct AccountClient: HostPairingIssuing, Sendable {
  private let endpoint: RelayEndpoint
  private let tokens: any SessionTokenProvider
  private let loader: any HTTPDataLoading

  public init(
    endpoint: RelayEndpoint = .production,
    tokens: any SessionTokenProvider,
    loader: any HTTPDataLoading = RelayCredentials.makeURLSession()
  ) {
    self.endpoint = endpoint
    self.tokens = tokens
    self.loader = loader
  }

  public func redeemDevicePairing(_ claim: DevicePairingClaim) async throws -> DevicePairingReceipt {
    struct Command: Encodable { let operation = "redeem"; let claim: DevicePairingClaim }
    return try await deviceLinkRequest(Command(claim: claim))
  }

  public func linkDevice(_ grant: DeviceLinkGrant) async throws {
    struct Command: Encodable { let operation = "link"; let grant: DeviceLinkGrant }
    struct Receipt: Decodable { let linked: Bool }
    let receipt: Receipt = try await deviceLinkRequest(Command(grant: grant))
    guard receipt.linked else { throw DeviceLinkError.notConfirmed }
  }

  public func unlinkDevice(_ revocation: DeviceUnlink) async throws {
    struct Command: Encodable { let operation = "unlink"; let revocation: DeviceUnlink }
    struct Receipt: Decodable { let unlinked: Bool }
    let receipt: Receipt = try await deviceLinkRequest(Command(revocation: revocation))
    guard receipt.unlinked else { throw DeviceLinkError.notConfirmed }
  }

  public func deviceLinkMailbox(_ command: DeviceLinkMailboxCommand) async throws -> DeviceMailboxReceipt {
    try await deviceLinkRequest(command, path: "/api/v1/account/devices/pairings")
  }

  private func deviceLinkRequest<Command: Encodable, Result: Decodable>(_ command: Command,
    path: String = "/api/v1/account/devices/link") async throws -> Result {
    var request = URLRequest(url: endpoint.webURL(path))
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.httpBody = try JSONEncoder().encode(command)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request = try await RelayCredentials.authorize(request, with: tokens)
    return try await send(request)
  }

  public func account() async throws -> SignedInAccount {
    try await get(endpoint.meURL)
  }

  /// Development APNs registration belongs to this native sign-in, not a host credential.
  /// A nil token durably disables this installation; revisions fence late enable requests.
  public func setRequestNotifications(installationID: UUID, revision: Int64, deviceToken: Data?, richPreviews: Bool = false) async throws {
    guard revision > 0, revision <= 9_007_199_254_740_991,
      deviceToken.map({ !$0.isEmpty && $0.count <= 1024 }) ?? true
    else { throw AxoClientError.invalidResponse("invalid notification registration") }
    var body: [String: Any] = ["installationId": installationID.uuidString.lowercased(), "revision": revision,
      "action": deviceToken == nil ? "disable" : "enable"]
    if let deviceToken {
      body["previews"] = richPreviews ? "message" : "generic"
      body["destination"] = ["topic": "dev.leostera.axo", "environment": "sandbox",
        "token": deviceToken.map { String(format: "%02x", $0) }.joined()]
    }
    var request = URLRequest(url: endpoint.webURL("/api/v1/account/push"))
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request = try await RelayCredentials.authorize(request, with: tokens)
    struct Receipt: Decodable { let revision: Int64 }
    let receipt: Receipt = try await send(request)
    guard receipt.revision == revision else { throw AxoClientError.invalidResponse("notification revision mismatch") }
  }

  public func notifications() async throws -> [AgentNotification] {
    struct History: Decodable { let notifications: [AgentNotification] }
    let history: History = try await get(endpoint.webURL("/api/v1/account/notifications"))
    return history.notifications
  }

  public func notificationQuestion(hostID: UUID, requestID: UUID) async throws -> NotificationQuestion {
    try await notificationOperation(["operation": "read", "hostId": hostID.uuidString.lowercased(),
      "requestId": requestID.uuidString.lowercased()])
  }

  public func answerNotification(hostID: UUID, requestID: UUID, digest: String, expiresAt: Int64,
    action: ElicitationAnswer, device: DeviceProof) async throws
  {
    struct Result: Decodable { let resolved: Bool }
    let proof = try JSONSerialization.jsonObject(with: JSONEncoder().encode(device))
    let result: Result = try await notificationOperation(["operation": "answer", "hostId": hostID.uuidString.lowercased(),
      "requestId": requestID.uuidString.lowercased(), "digest": digest, "expiresAt": expiresAt,
      "action": action.rawValue, "device": proof])
    guard result.resolved else { throw AxoClientError.invalidResponse("notification answer was not confirmed") }
  }

  private func notificationOperation<Value: Decodable>(_ body: [String: Any]) async throws -> Value {
    var request = URLRequest(url: endpoint.webURL("/api/v1/account/push/request"))
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request = try await RelayCredentials.authorize(request, with: tokens)
    return try await send(request)
  }

  /// Ends this phone's sign-in at the relay. Other devices stay signed in.
  public func signOut() async throws {
    var request = URLRequest(url: endpoint.logoutURL)
    request.httpMethod = "POST"
    request = try await RelayCredentials.authorize(request, with: tokens)
    let (_, response) = try await loader.load(request)
    switch response.statusCode {
    case 204: break
    // Already ended, which is what was asked for.
    case 401: break
    case let status: throw RelayError.httpStatus(status)
    }
  }

  /// A new code to link a Mac to this account. Asking again makes another; each expires.
  public func createHostPairing() async throws -> HostPairing {
    struct Answer: Decodable {
      let code: String
      let expiresAt: String
    }
    var request = URLRequest(url: endpoint.hostPairingsURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request = try await RelayCredentials.authorize(request, with: tokens)
    let answer: Answer = try await send(request)
    guard let code = HostPairingCode(parsing: answer.code),
      let expiresAt = try? Date(answer.expiresAt, strategy: .iso8601)
    else {
      throw AxoClientError.invalidResponse("the relay's pairing code is not one")
    }
    return HostPairing(code: code, expiresAt: expiresAt)
  }

  private func get<Value: Decodable>(_ url: URL, as: Value.Type = Value.self) async throws -> Value {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request = try await RelayCredentials.authorize(request, with: tokens)
    return try await send(request)
  }

  private func send<Value: Decodable>(_ request: URLRequest) async throws -> Value {
    let (data, response): (Data, HTTPURLResponse)
    do {
      (data, response) = try await loader.load(request)
    } catch let error as AxoClientError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      // URLSession's word for the calling task being cancelled: nothing went wrong.
      throw CancellationError()
    } catch {
      throw RelayError.unreachable(error.localizedDescription)
    }
    switch response.statusCode {
    case 200: break
    case 401, 403: throw RelayError.signInRequired
    case let status: throw RelayError.httpStatus(status)
    }
    do {
      return try JSONDecoder().decode(Value.self, from: data)
    } catch {
      throw AxoClientError.invalidResponse("could not decode the relay's answer: \(error)")
    }
  }
}
