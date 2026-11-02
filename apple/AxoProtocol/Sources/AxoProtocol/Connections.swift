import Foundation

// Settings › Apps over HTTPS (RFD0016): what the account's Sessions can use. These mirror
// `@axo/protocol`'s connections schemas (packages/axo-api/src/connections.ts). A reader takes what
// it knows and leaves the rest: an app or a sign-in kind newer than this build is kept as
// `.unknown` rather than failing the whole listing, as Workers roll out ahead of the app.

/// What the account's Sessions can reach: a paired Mac, an MCP server, or an app Axo provides.
public enum Connection: Decodable, Equatable, Sendable {
  case host(HostConnectionInfo)
  case server(ServerConnection)
  case app(AppConnection)
  /// A kind this build does not know.
  case unknown

  private enum Kind: String, Decodable { case host, thirdParty, app }
  private enum Keys: String, CodingKey { case kind }

  public init(from decoder: any Decoder) throws {
    let kind = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .kind)
    switch Kind(rawValue: kind) {
    case .host: self = .host(try HostConnectionInfo(from: decoder))
    case .thirdParty: self = .server(try ServerConnection(from: decoder))
    case .app: self = .app(try AppConnection(from: decoder))
    case nil: self = .unknown
    }
  }
}

/// A paired Mac, as a connection: `codemode.<name>.bash`.
public struct HostConnectionInfo: Decodable, Equatable, Sendable {
  public let name: String
  public let hostId: UUID
  public let state: String

  public init(name: String, hostId: UUID, state: String) {
    self.name = name
    self.hostId = hostId
    self.state = state
  }

  public var isOnline: Bool { state == "online" }
}

/// A remote MCP server the person added under a name of theirs.
public struct ServerConnection: Decodable, Equatable, Sendable, Identifiable {
  public enum State: String, Decodable, Sendable { case ready, needsSignIn, error }

  /// How scripts reach it: `codemode.<name>.*`.
  public let name: String
  /// What the person called it; nil when that is its name.
  public let title: String?
  public let url: String
  public let state: State
  public let tools: Int
  /// The server's icon, an https URL; nil until found, or when it has none.
  public let icon: String?
  public let lastError: String?

  public var id: String { name }
  public var displayName: String { title ?? name }

  public init(
    name: String, title: String? = nil, url: String, state: State, tools: Int = 0, icon: String? = nil,
    lastError: String? = nil
  ) {
    self.name = name
    self.title = title
    self.url = url
    self.state = state
    self.tools = tools
    self.icon = icon
    self.lastError = lastError
  }

  private enum Keys: String, CodingKey { case name, title, url, state, tools, icon, lastError }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    name = try c.decode(String.self, forKey: .name)
    title = try c.decodeIfPresent(String.self, forKey: .title)
    url = try c.decode(String.self, forKey: .url)
    state = (try? c.decode(State.self, forKey: .state)) ?? .error
    tools = try c.decodeIfPresent(Int.self, forKey: .tools) ?? 0
    icon = try c.decodeIfPresent(String.self, forKey: .icon)
    lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
  }
}

/// An app Axo provides (`apps.<app>`), with the provider accounts signed in to it.
public struct AppConnection: Decodable, Equatable, Sendable, Identifiable {
  /// `apps.gmail`.
  public let name: String
  public let title: String
  /// One sentence on what the app is for.
  public let description: String
  /// Who makes the service: "Google".
  public let provider: String
  /// For filtering: "communication", "productivity", ...; "" when not said.
  public let category: String
  /// What a signed-in account lets Axo do, one per line.
  public let permissions: [String]
  /// How Add account works.
  public let signIn: AppSignIn
  public let accounts: [AppAccount]
  public let lastError: String?

  public var id: String { name }
  /// `gmail`: the app's page on the web, `/app/settings/apps/<slug>`.
  public var slug: String { name.hasPrefix("apps.") ? String(name.dropFirst(5)) : name }
  /// Some account of it is signed in and working.
  public var isConnected: Bool { accounts.contains { $0.state == .ready } }
  /// An OAuth app waiting for its provider's client to be set up.
  public var needsClient: Bool {
    if case .oauth(let client?) = signIn { return !client.ready }
    return false
  }

  public init(
    name: String, title: String, description: String = "", provider: String = "", category: String = "",
    permissions: [String] = [], signIn: AppSignIn = .oauth(client: nil), accounts: [AppAccount] = [],
    lastError: String? = nil
  ) {
    self.name = name
    self.title = title
    self.description = description
    self.provider = provider
    self.category = category
    self.permissions = permissions
    self.signIn = signIn
    self.accounts = accounts
    self.lastError = lastError
  }

  private enum Keys: String, CodingKey {
    case name, title, description, provider, category, permissions, signIn, accounts, lastError
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    name = try c.decode(String.self, forKey: .name)
    title = try c.decode(String.self, forKey: .title)
    // A listing from a Worker one release older has none of these: read as empty.
    description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
    category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
    permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
    signIn = try c.decodeIfPresent(AppSignIn.self, forKey: .signIn) ?? .oauth(client: nil)
    accounts = try c.decodeIfPresent([AppAccount].self, forKey: .accounts) ?? []
    lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
  }
}

/// One provider account of an app, named by its email (or the name the person gave it).
public struct AppAccount: Decodable, Equatable, Sendable, Identifiable {
  public enum State: String, Decodable, Sendable { case ready, needsSignIn }

  public let account: String
  /// `needsSignIn`: the grant was refused or expired; sign in to that account again.
  public let state: State
  public let lastError: String?

  public var id: String { account }

  public init(account: String, state: State = .ready, lastError: String? = nil) {
    self.account = account
    self.state = state
    self.lastError = lastError
  }

  private enum Keys: String, CodingKey { case account, state, lastError }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    account = try c.decode(String.self, forKey: .account)
    state = (try? c.decode(State.self, forKey: .state)) ?? .needsSignIn
    lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
  }
}

/// How a person adds an account to an app.
public enum AppSignIn: Decodable, Equatable, Sendable {
  /// The provider's sign-in in a browser, once the person's OAuth client is set up (`client`;
  /// nil from Workers older than clients being the person's).
  case oauth(client: AppOAuthClient?)
  /// A code the person enters at the provider (ChatGPT), while Axo is asked whether they have.
  case device
  /// The app runs a program on the account's Macs (1Password), which are its accounts.
  case mac(setup: String, helpUrl: String)
  /// The person pastes what the service issued them; `named`: they name the account too.
  case token(TokenSignIn)
  /// A kind this build does not know: added on the web.
  case unknown

  private enum Keys: String, CodingKey { case kind, client, setup, helpUrl }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    switch try c.decode(String.self, forKey: .kind) {
    case "oauth": self = .oauth(client: try c.decodeIfPresent(AppOAuthClient.self, forKey: .client))
    case "device": self = .device
    case "mac":
      self = .mac(
        setup: try c.decodeIfPresent(String.self, forKey: .setup) ?? "",
        helpUrl: try c.decodeIfPresent(String.self, forKey: .helpUrl) ?? "")
    case "token": self = .token(try TokenSignIn(from: decoder))
    default: self = .unknown
    }
  }
}

/// A token app's Add account.
public struct TokenSignIn: Decodable, Equatable, Sendable {
  /// The service's page where the person creates the token.
  public let helpUrl: String
  public let named: Bool
  public let fields: [AppTokenField]
  /// A sign-in that ends on one of the account's Macs, offered beside pasting (Kraken's).
  public let mac: MacSignInOffer?

  public init(helpUrl: String, named: Bool, fields: [AppTokenField], mac: MacSignInOffer? = nil) {
    self.helpUrl = helpUrl
    self.named = named
    self.fields = fields
    self.mac = mac
  }
}

/// A field a person fills in to add a token app's account, such as Hetzner's API token.
public struct AppTokenField: Decodable, Equatable, Sendable, Identifiable {
  public let name: String
  public let label: String
  /// Where to find it, in plain words.
  public let help: String
  /// Never shown again once added.
  public let secret: Bool

  public var id: String { name }

  public init(name: String, label: String, help: String = "", secret: Bool = true) {
    self.name = name
    self.label = label
    self.help = help
    self.secret = secret
  }
}

/// A token app's sign-in on a Mac: the button, and what the credential may do.
public struct MacSignInOffer: Decodable, Equatable, Sendable {
  public struct Preset: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let description: String

    public init(id: String, label: String, description: String = "") {
      self.id = id
      self.label = label
      self.description = description
    }
  }

  public let title: String
  public let presets: [Preset]

  public init(title: String, presets: [Preset]) {
    self.title = title
    self.presets = presets
  }
}

/// The OAuth client an app signs in with: one the person registered with the provider.
public struct AppOAuthClient: Decodable, Equatable, Sendable {
  /// "google": one client serves every app of a provider.
  public let provider: String
  public let ready: Bool
  /// The provider's page for registering one.
  public let consoleUrl: String
  public let redirectUri: String

  public init(provider: String, ready: Bool, consoleUrl: String, redirectUri: String) {
    self.provider = provider
    self.ready = ready
    self.consoleUrl = consoleUrl
    self.redirectUri = redirectUri
  }
}

/// A device sign-in as it is polled: the code and where to enter it, until done or failed.
public enum DeviceSignIn: Decodable, Equatable, Sendable {
  case pending(userCode: String, verificationUrl: String, intervalSeconds: Int, expiresAt: String)
  case done(account: String)
  case failed(String)

  private enum Keys: String, CodingKey { case state, userCode, verificationUrl, intervalSeconds, expiresAt, account, error }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    switch try c.decode(String.self, forKey: .state) {
    case "pending":
      self = .pending(
        userCode: try c.decode(String.self, forKey: .userCode),
        verificationUrl: try c.decode(String.self, forKey: .verificationUrl),
        intervalSeconds: try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 5,
        expiresAt: try c.decodeIfPresent(String.self, forKey: .expiresAt) ?? "")
    case "done": self = .done(account: try c.decode(String.self, forKey: .account))
    default: self = .failed(try c.decodeIfPresent(String.self, forKey: .error) ?? "The sign-in failed.")
    }
  }
}

/// A sign-in on a Mac as it is polled: waiting for the person in that Mac's browser, done, or failed.
public enum MacSignIn: Decodable, Equatable, Sendable {
  case pending(mac: String)
  case done(account: String)
  case failed(String)

  private enum Keys: String, CodingKey { case state, mac, account, error }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    switch try c.decode(String.self, forKey: .state) {
    case "pending": self = .pending(mac: try c.decodeIfPresent(String.self, forKey: .mac) ?? "")
    case "done": self = .done(account: try c.decode(String.self, forKey: .account))
    default: self = .failed(try c.decodeIfPresent(String.self, forKey: .error) ?? "The sign-in failed.")
    }
  }
}

/// One call a Session made to an app, a server or a Mac, as the account's log keeps it.
public struct CallRecord: Decodable, Equatable, Sendable, Identifiable {
  public enum Outcome: String, Decodable, Sendable { case ok, error, unknown }

  public let callId: String
  /// ISO 8601.
  public let at: String
  public let service: String
  public let tool: String
  public let durationMs: Int
  public let outcome: Outcome
  public let error: String?
  public let input: JSONValue

  public var id: String { callId }

  public init(
    callId: String, at: String, service: String, tool: String, durationMs: Int = 0, outcome: Outcome = .ok,
    error: String? = nil, input: JSONValue = .null
  ) {
    self.callId = callId
    self.at = at
    self.service = service
    self.tool = tool
    self.durationMs = durationMs
    self.outcome = outcome
    self.error = error
    self.input = input
  }

  private enum Keys: String, CodingKey { case callId, at, service, tool, durationMs, outcome, error, input }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    callId = try c.decode(String.self, forKey: .callId)
    at = try c.decode(String.self, forKey: .at)
    service = try c.decode(String.self, forKey: .service)
    tool = try c.decode(String.self, forKey: .tool)
    durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
    outcome = (try? c.decode(Outcome.self, forKey: .outcome)) ?? .unknown
    error = try c.decodeIfPresent(String.self, forKey: .error)
    input = try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .null
  }

  /// When it was made.
  public var date: Date? {
    (try? Date(at, strategy: .iso8601))
      ?? (try? Date(at, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
  }
}

/// The call log's hash chain, replayed in the cloud: whether anything stored was changed.
public struct CallLogIntegrity: Decodable, Equatable, Sendable {
  public let verified: Bool
  public let events: Int
  public let head: String?
  public let reason: String?

  public init(verified: Bool, events: Int, head: String? = nil, reason: String? = nil) {
    self.verified = verified
    self.events = events
    self.head = head
    self.reason = reason
  }
}
