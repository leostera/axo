import AxoProtocol
import Foundation

/// What Axo said when it refused an Apps request: its own words, for the person.
public struct ConnectionsRefusal: Error, Equatable, LocalizedError {
  public let status: Int
  public let message: String

  public init(status: Int, message: String) {
    self.status = status
    self.message = message
  }

  public var errorDescription: String? { message }
}

/// Settings › Apps over HTTPS (RFD0016), signed in with the phone's session token: the account's
/// apps and MCP servers, adding and removing their accounts, and what Sessions did with them.
/// A browser sign-in (an OAuth app, an MCP server) runs on the web, where the provider sends the
/// browser back to a page signed in to the same account; `webPage(for:)` says which.
public struct ConnectionsClient: Sendable {
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

  // MARK: - Reading

  /// Every app, MCP server and Mac the account's Sessions can use.
  public func list() async throws -> [Connection] {
    struct Listing: Decodable { let connections: [Connection] }
    let listing: Listing = try await send("GET", path: "")
    return listing.connections
  }

  /// Recent calls, newest first: of everything, or of one app or server (`service`).
  public func log(service: String? = nil, limit: Int = 50, before: String? = nil) async throws -> [CallRecord] {
    struct Log: Decodable { let records: [CallRecord] }
    var query = [URLQueryItem(name: "limit", value: String(limit))]
    if let service { query.append(URLQueryItem(name: "service", value: service)) }
    if let before { query.append(URLQueryItem(name: "before", value: before)) }
    let log: Log = try await send("GET", path: "/log", query: query)
    return log.records
  }

  /// Whether the call log is as it was written.
  public func integrity() async throws -> CallLogIntegrity {
    try await send("GET", path: "/log/integrity")
  }

  // MARK: - Apps

  /// Adds a token app's account with what the service issued; returns the account's name. The
  /// token is checked with the service and sealed in the account; nothing sends it back.
  public func addToken(app: String, account: String?, fields: [String: String]) async throws -> String {
    struct Body: Encodable {
      let account: String?
      let fields: [String: String]
      func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(account, forKey: .account)
        try c.encode(fields, forKey: .fields)
      }
      enum CodingKeys: String, CodingKey { case account, fields }
    }
    struct Added: Decodable { let account: String }
    let added: Added = try await send("POST", path: "/\(app)/token", body: Body(account: account, fields: fields))
    return added.account
  }

  /// Starts a device sign-in: the code to enter at the provider, and the flow to poll.
  public func startDeviceSignIn(app: String) async throws -> (flow: String, state: DeviceSignIn) {
    struct Flow: Decodable { let flow: String }
    let data = try await sendData("POST", path: "/\(app)/device", body: Optional<Empty>.none)
    return (try decode(Flow.self, data).flow, try decode(DeviceSignIn.self, data))
  }

  public func pollDeviceSignIn(app: String, flow: String) async throws -> DeviceSignIn {
    try await send("POST", path: "/\(app)/device/poll", body: FlowBody(flow: flow))
  }

  /// Starts a sign-in on one of the account's Macs (Kraken's): its browser opens the provider's page.
  public func startMacSignIn(app: String, mac: String, preset: String, account: String?) async throws -> String {
    struct Body: Encodable {
      let mac: String
      let preset: String
      let account: String?
      func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mac, forKey: .mac)
        try c.encode(preset, forKey: .preset)
        try c.encodeIfPresent(account, forKey: .account)
      }
      enum CodingKeys: String, CodingKey { case mac, preset, account }
    }
    struct Flow: Decodable { let flow: String }
    let flow: Flow = try await send("POST", path: "/\(app)/mac-sign-in", body: Body(mac: mac, preset: preset, account: account))
    return flow.flow
  }

  public func pollMacSignIn(app: String, flow: String) async throws -> MacSignIn {
    try await send("POST", path: "/\(app)/mac-sign-in/poll", body: FlowBody(flow: flow))
  }

  /// One step of a phone app's sign-in (Telegram's): the number, the code, or the password.
  public func phoneSignIn(app: String, step: PhoneSignInStep) async throws -> PhoneSignIn {
    try await send("POST", path: "/\(app)/phone-sign-in", body: step.body)
  }

  /// Sets an OAuth app's client (or a server's that registers none itself), once; the secret is
  /// never shown again. Returns the sign-in link that follows, which opens on the web.
  @discardableResult
  public func setClient(_ name: String, clientId: String, clientSecret: String?) async throws -> String {
    struct Body: Encodable {
      let clientId: String
      let clientSecret: String?
      func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientId, forKey: .clientId)
        try c.encode(clientSecret, forKey: .clientSecret)
      }
      enum CodingKeys: String, CodingKey { case clientId, clientSecret }
    }
    struct Link: Decodable { let signInUrl: String }
    let link: Link = try await send("POST", path: "/\(name)/client", body: Body(clientId: clientId, clientSecret: clientSecret))
    return link.signInUrl
  }

  /// Signs an app's account out, or removes an MCP server (no account).
  public func remove(_ name: String, account: String? = nil) async throws {
    struct Body: Encodable {
      let account: String?
      func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(account, forKey: .account)
      }
      enum CodingKeys: String, CodingKey { case account }
    }
    _ = try await sendData("POST", path: "/\(name)/remove", body: Body(account: account))
  }

  // MARK: - MCP servers

  /// Adds a remote MCP server under a name of the person's. `signInUrl` is set when it needs a
  /// browser sign-in next.
  public func addServer(name: String, url: String) async throws -> (connection: Connection, signInUrl: String?) {
    struct Body: Encodable {
      let name: String
      let url: String
    }
    struct Added: Decodable {
      let connection: Connection
      let signInUrl: String?
    }
    let added: Added = try await send("POST", path: "", body: Body(name: name, url: url))
    return (added.connection, added.signInUrl)
  }

  // MARK: - The web

  /// Where a browser sign-in happens: the app's page in the web app, signed in to the account
  /// there, which comes back to it when the provider is done. `nil` names the MCP servers page.
  public func webPage(for app: AppConnection?) -> URL {
    endpoint.webURL(app.map { "/app/settings/apps/\($0.slug)" } ?? "/app/settings/apps/mcp")
  }

  // MARK: - Plumbing

  private struct Empty: Encodable {}
  private struct FlowBody: Encodable { let flow: String }
  private struct Refusal: Decodable { let error: String }

  private func send<Value: Decodable>(
    _ method: String, path: String, query: [URLQueryItem] = [], body: (some Encodable)? = Optional<Empty>.none
  ) async throws -> Value {
    try decode(Value.self, try await sendData(method, path: path, query: query, body: body))
  }

  private func sendData(
    _ method: String, path: String, query: [URLQueryItem] = [], body: (some Encodable)?
  ) async throws -> Data {
    var request = URLRequest(url: endpoint.connectionsURL(path, query: query))
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    } else if method == "POST" {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data("{}".utf8)
    }
    request = try await RelayCredentials.authorize(request, with: tokens)
    let (data, response): (Data, HTTPURLResponse)
    do {
      (data, response) = try await loader.load(request)
    } catch let error as AxoClientError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      throw RelayError.unreachable(error.localizedDescription)
    }
    switch response.statusCode {
    case 200..<300: return data
    case 401: throw RelayError.signInRequired
    case let status:
      // Axo's refusals say what was wrong ({ error }); anything else is just a status.
      if let refusal = try? JSONDecoder().decode(Refusal.self, from: data) {
        throw ConnectionsRefusal(status: status, message: refusal.error)
      }
      throw RelayError.httpStatus(status)
    }
  }

  private func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
    do {
      return try JSONDecoder().decode(Value.self, from: data)
    } catch {
      throw AxoClientError.invalidResponse("could not read Axo's answer: \(error)")
    }
  }
}
