import AxoProtocol
import Foundation

/// How `AccountClient` fetches: `URLSession` in the app, a stub in tests.
public protocol HTTPDataLoading: Sendable {
  func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPDataLoading {
  public func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw AxoClientError.invalidResponse("the relay did not answer over HTTP")
    }
    return (data, http)
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
}

/// Who can ask the relay for a pairing code: `AccountClient`, or a stand-in.
public protocol HostPairingIssuing: Sendable {
  func createHostPairing() async throws -> HostPairing
}

/// An account's view of its hosts, over HTTPS.
///
/// The relay owns this data and decides who may see it; the client only asks, and checks that
/// what came back is what it asked about.
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

  public func account() async throws -> SignedInAccount {
    try await get(endpoint.meURL)
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

  public func hosts() async throws -> [RemoteHost] {
    try await get(endpoint.hostsURL, as: RemoteHostList.self).hosts
  }

  /// The Sessions of one run of one host. A host that restarted since `host` was read is a
  /// conflict, not a quiet answer about a different run.
  public func sessions(of host: RemoteHostRef) async throws -> [RemoteSession] {
    struct Answer: Decodable {
      let host: RemoteHost
      let sessions: [RemoteSession]
    }
    let answer: Answer = try await get(endpoint.sessionsURL(of: host))
    guard answer.host.reference == host, answer.sessions.allSatisfy({ $0.hostId == host.hostId })
    else {
      throw AxoClientError.invalidResponse("the relay answered for a different host")
    }
    return answer.sessions
  }

  /// One page of a Session's Pi events, newest first. `before` is the id of the oldest event already read (0 starts at the newest).
  public func piEvents(of host: RemoteHostRef, session: SessionID, before cursor: Int64 = 0, limit: Int = 50)
    async throws -> PiEventPage
  {
    try await get(endpoint.piEventsURL(of: host, session: session, before: cursor, limit: min(max(limit, 1), 50)))
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
    } catch {
      throw AxoClientError.connectionFailed(error.localizedDescription)
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
