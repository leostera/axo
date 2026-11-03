import AxoClient
import AxoProtocol
import Foundation
import Observation

/// Settings › Apps' API, as the phone needs it (`ConnectionsClient`; a stand-in in tests).
public protocol ConnectionsService: Sendable {
  func list() async throws -> [Connection]
  func log(service: String?, limit: Int, before: String?) async throws -> [CallRecord]
  func integrity() async throws -> CallLogIntegrity
  func addToken(app: String, account: String?, fields: [String: String]) async throws -> String
  func startDeviceSignIn(app: String) async throws -> (flow: String, state: DeviceSignIn)
  func pollDeviceSignIn(app: String, flow: String) async throws -> DeviceSignIn
  func startMacSignIn(app: String, mac: String, preset: String, account: String?) async throws -> String
  func pollMacSignIn(app: String, flow: String) async throws -> MacSignIn
  func phoneSignIn(app: String, step: PhoneSignInStep) async throws -> PhoneSignIn
  @discardableResult func setClient(_ name: String, clientId: String, clientSecret: String?) async throws -> String
  func remove(_ name: String, account: String?) async throws
  func addServer(name: String, url: String) async throws -> (connection: Connection, signInUrl: String?)
  func webPage(for app: AppConnection?) -> URL
}

extension ConnectionsClient: ConnectionsService {}

/// What the account's Sessions can use, as Settings › Apps shows it (RFD0016): the apps Axo
/// provides with their accounts, the MCP servers the person added, and what Sessions did with
/// them. A token or a client secret is typed here once and sent to Axo, which seals it; nothing
/// brings it back. A browser sign-in (an OAuth app, an MCP server) happens on the web, in the app's
/// page there, and this lists the account it added when the person comes back.
@MainActor
@Observable
public final class AppsModel {
  public enum Phase: Equatable, Sendable {
    case idle, loading, loaded
    case failed(String)
  }

  /// Something to tell the person: an account added, or why something did not work.
  public struct Notice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case done, problem }
    public let kind: Kind
    public let text: String
  }

  /// A device sign-in under way (ChatGPT's): the code to enter at the provider.
  public struct DeviceFlow: Equatable, Sendable {
    public let app: String
    public let flow: String
    public let userCode: String
    public let verificationURL: URL?
  }

  /// A sign-in under way in the browser of one of the account's Macs (Kraken's).
  public struct MacFlow: Equatable, Sendable {
    public let app: String
    public let flow: String
    public let mac: String
  }

  public private(set) var phase: Phase = .idle
  public private(set) var apps: [AppConnection] = []
  public private(set) var servers: [ServerConnection] = []
  /// The account's Macs, as connections (by their connection names); a Mac sign-in runs on one.
  public private(set) var macs: [HostConnectionInfo] = []
  public private(set) var notice: Notice?
  /// Something is on its way; buttons wait.
  public private(set) var isBusy = false
  public private(set) var deviceFlow: DeviceFlow?
  public private(set) var macFlow: MacFlow?

  private let service: any ConnectionsService
  /// Waits between polls; tests make it immediate.
  private let pause: @Sendable (Duration) async throws -> Void
  private var pollTask: Task<Void, Never>?

  public init(
    service: any ConnectionsService,
    pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.service = service
    self.pause = pause
  }

  public func app(named name: String) -> AppConnection? { apps.first { $0.name == name } }

  /// The web page a browser sign-in runs on.
  public func webPage(for app: AppConnection?) -> URL { service.webPage(for: app) }

  public func dismissNotice() { notice = nil }

  // MARK: - Reading

  /// Reads the listing again; the first read shows as loading, later ones keep what is shown.
  public func refresh() async {
    if phase != .loaded { phase = .loading }
    do {
      adopt(try await service.list())
      phase = .loaded
    } catch is CancellationError {
      if phase == .loading { phase = .idle }
    } catch {
      if phase == .loaded { notice = Notice(kind: .problem, text: Self.describe(error)) } else { phase = .failed(Self.describe(error)) }
    }
  }

  private func adopt(_ connections: [Connection]) {
    var apps: [AppConnection] = []
    var servers: [ServerConnection] = []
    var macs: [HostConnectionInfo] = []
    for connection in connections {
      switch connection {
      case .app(let app): apps.append(app)
      case .server(let server): servers.append(server)
      case .host(let mac): macs.append(mac)
      case .unknown: break
      }
    }
    self.apps = apps
    self.servers = servers
    self.macs = macs
  }

  /// Recent calls, of everything or of one app or server.
  public func calls(of service: String? = nil, limit: Int = 50) async throws -> [CallRecord] {
    try await self.service.log(service: service, limit: limit, before: nil)
  }

  public func integrity() async throws -> CallLogIntegrity { try await service.integrity() }

  // MARK: - Accounts

  /// Signs `account` out of `app`; Sessions can no longer use it.
  public func remove(_ account: String, from app: AppConnection) async {
    await act(done: "Removed \(account).") { try await service.remove(app.name, account: account) }
  }

  /// Adds a token app's account (or a new token for `account`); says whether it was added.
  @discardableResult
  public func addToken(to app: AppConnection, account: String?, fields: [String: String]) async -> Bool {
    let name = account?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var added: String?
    await act {
      added = try await service.addToken(app: app.name, account: name?.isEmpty == false ? name : nil, fields: fields)
    }
    if let added { notice = Notice(kind: .done, text: "Added \(added).") }
    return added != nil
  }

  /// Sets up an OAuth app's client with the provider; says whether it was saved.
  @discardableResult
  public func setClient(of app: AppConnection, clientId: String, clientSecret: String) async -> Bool {
    let provider = app.provider.isEmpty ? app.title : app.provider
    return await act(done: "\(provider) is set up. Add an account.") {
      try await service.setClient(
        app.name, clientId: clientId.trimmingCharacters(in: .whitespacesAndNewlines),
        clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  // MARK: - Device sign-in

  /// Starts a device sign-in: the code shows until the person enters it at the provider, and
  /// Axo is asked every few seconds whether they have.
  public func startDeviceSignIn(for app: AppConnection) async {
    await act {
      let (flow, state) = try await service.startDeviceSignIn(app: app.name)
      guard case .pending(let code, let url, let interval, _) = state else {
        if case .failed(let error) = state { notice = Notice(kind: .problem, text: error) }
        return
      }
      deviceFlow = DeviceFlow(app: app.name, flow: flow, userCode: code, verificationURL: URL(string: url))
      pollDevice(app: app.name, flow: flow, every: .seconds(max(1, interval)))
    }
  }

  private func pollDevice(app: String, flow: String, every interval: Duration) {
    pollTask?.cancel()
    pollTask = Task { [weak self, service, pause] in
      while !Task.isCancelled {
        do { try await pause(interval) } catch { return }
        if Task.isCancelled { return }
        guard let state = try? await service.pollDeviceSignIn(app: app, flow: flow) else { continue }
        guard let self, self.deviceFlow?.flow == flow else { return }
        switch state {
        case .pending: continue
        case .done(let account): self.finishFlow(Notice(kind: .done, text: "Added \(account)."))
        case .failed(let error): self.finishFlow(Notice(kind: .problem, text: error))
        }
        return
      }
    }
  }

  // MARK: - Sign-in on a Mac

  /// Starts a sign-in in the browser of one of the account's Macs; Axo is asked every two seconds
  /// whether the person approved it there.
  public func startMacSignIn(for app: AppConnection, on mac: String, preset: String, account: String?) async {
    let name = account?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    await act {
      let flow = try await service.startMacSignIn(app: app.name, mac: mac, preset: preset, account: name?.isEmpty == false ? name : nil)
      macFlow = MacFlow(app: app.name, flow: flow, mac: mac)
      pollMac(app: app.name, flow: flow)
    }
  }

  private func pollMac(app: String, flow: String) {
    pollTask?.cancel()
    pollTask = Task { [weak self, service, pause] in
      while !Task.isCancelled {
        do { try await pause(.seconds(2)) } catch { return }
        if Task.isCancelled { return }
        guard let state = try? await service.pollMacSignIn(app: app, flow: flow) else { continue }
        guard let self, self.macFlow?.flow == flow else { return }
        switch state {
        case .pending: continue
        case .done(let account): self.finishFlow(Notice(kind: .done, text: "Added \(account)."))
        case .failed(let error): self.finishFlow(Notice(kind: .problem, text: error))
        }
        return
      }
    }
  }

  // MARK: - Phone sign-in

  /// Takes one step of a phone app's sign-in and says where it stands, for the form to show the
  /// next; nil when the step did not reach Axo (the notice says why). Done reads the listing again.
  public func phoneSignIn(_ app: AppConnection, step: PhoneSignInStep) async -> PhoneSignIn? {
    var answer: PhoneSignIn?
    let reached = await act {
      answer = try await service.phoneSignIn(app: app.name, step: step)
    }
    guard reached, let answer else { return nil }
    switch answer {
    case .done(let account): notice = Notice(kind: .done, text: "Added \(account).")
    case .failed(let error): notice = Notice(kind: .problem, text: error)
    case .code, .password: break
    }
    return answer
  }

  private func finishFlow(_ notice: Notice) {
    deviceFlow = nil
    macFlow = nil
    pollTask = nil
    self.notice = notice
    Task { await refresh() }
  }

  /// Stops waiting for a device or Mac sign-in.
  public func cancelSignIn() {
    pollTask?.cancel()
    pollTask = nil
    deviceFlow = nil
    macFlow = nil
  }

  // MARK: - MCP servers

  /// How adding a server went.
  public enum ServerAdded: Equatable, Sendable {
    case added
    /// It needs a browser sign-in next, on the web.
    case needsSignIn
    case failed
  }

  public func addServer(name: String, url: String) async -> ServerAdded {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    var outcome = ServerAdded.failed
    await act {
      let (connection, signInUrl) = try await service.addServer(name: name, url: url)
      if case .server(let server) = connection {
        outcome = signInUrl != nil || server.state == .needsSignIn ? .needsSignIn : .added
        if outcome == .added { notice = Notice(kind: .done, text: "Added \(server.displayName).") }
      } else {
        outcome = .added
      }
    }
    return outcome
  }

  public func remove(_ server: ServerConnection) async {
    await act(done: "Removed \(server.displayName).") { try await service.remove(server.name, account: nil) }
  }

  // MARK: - Doing

  /// Runs `work`, then reads the listing again. A failure becomes the notice; `done` is shown on
  /// success. Says whether it worked.
  @discardableResult
  private func act(done: String? = nil, _ work: () async throws -> Void) async -> Bool {
    isBusy = true
    defer { isBusy = false }
    do {
      try await work()
      if let done { notice = Notice(kind: .done, text: done) }
      await refresh()
      return true
    } catch is CancellationError {
      return false
    } catch {
      notice = Notice(kind: .problem, text: Self.describe(error))
      return false
    }
  }

  static func describe(_ error: Error) -> String {
    switch error {
    case let refusal as ConnectionsRefusal: refusal.message
    case AxoClientError.invalidResponse:
      "Axo answered in a way this version of the app does not understand. Update the app, or use the web."
    default: error.localizedDescription
    }
  }
}

// MARK: - What the pages show

/// What Settings › Apps shows of the catalog: the tiles, how they are grouped, and calls as lines.
public enum AppsCatalog {
  /// Category titles, as the web app names them.
  public static func categoryTitle(_ category: String) -> String {
    switch category {
    case "": "Other"
    case "mcp": "MCP servers"
    default: category.prefix(1).uppercased() + category.dropFirst()
    }
  }

  /// "No accounts", "1 account", "3 accounts".
  public static func count(_ n: Int, _ noun: String, _ nouns: String? = nil) -> String {
    let plural = nouns ?? "\(noun)s"
    return n == 0 ? "No \(plural)" : n == 1 ? "1 \(noun)" : "\(n) \(plural)"
  }

  /// What an app's tile says under its name.
  public static func detail(of app: AppConnection) -> String {
    if app.needsClient { return "Needs set-up" }
    if case .mac = app.signIn { return count(app.accounts.count, "Mac") }
    return count(app.accounts.count, "account")
  }

  /// "Search messages", or with its app or server first: "Gmail · Search messages".
  public static func callTitle(_ record: CallRecord, ofOne: Bool, titles: [String: String] = [:]) -> String {
    let words = record.tool.replacingOccurrences(of: "_", with: " ")
    let tool = words.prefix(1).uppercased() + words.dropFirst()
    return ofOne ? tool : "\(titles[record.service] ?? record.service) · \(tool)"
  }

  /// What a call was about, in a line: the command a Mac ran, or an app call's account and values.
  public static func summary(_ record: CallRecord) -> String {
    var what: String
    if case .object(var input) = record.input {
      if case .string(let command)? = input["command"] {
        what = command
      } else {
        let account = input.removeValue(forKey: "account")?.stringValue
        let values = input.keys.sorted().compactMap { key -> String? in
          switch input[key] {
          case .string(let text)? where !text.isEmpty: text
          case .number(let number)?: number.rounded() == number ? String(Int64(number)) : String(number)
          case .bool(let flag)?: String(flag)
          case nil, .null?, .string?: nil
          case let value?: value.compactJSON
          }
        }
        what = ([account].compactMap { $0 } + values).joined(separator: " · ")
      }
    } else {
      what = record.input == .null ? "" : record.input.compactJSON
    }
    let line = String(what.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(100))
    guard let error = record.error else { return line }
    return line.isEmpty ? String(error.prefix(80)) : "\(line) · \(error.prefix(80))"
  }
}

/// A remote MCP server Axo knows, with a page of its own; each may be added any number of times,
/// under a name of the person's, for another account with the service.
public struct KnownServer: Equatable, Sendable, Identifiable {
  /// How it signs in: `self` registers Axo as a client by itself; `client` needs an OAuth app the
  /// person registers with the provider (at `consoleURL`); `none` needs no sign-in.
  public enum SignIn: Equatable, Sendable { case `self`, client, none }

  public let id: String
  public let title: String
  public let provider: String
  public let category: String
  public let url: String
  public let description: String
  public let signIn: SignIn
  public var consoleURL: String?
  /// The image in the app's logos: the maker's.
  public var logo: String

  /// Every server Axo knows, as the web app lists them (packages/axo-web-app/src/chat/servers.ts).
  public static let all: [KnownServer] = [
    KnownServer(
      id: "github", title: "GitHub MCP", provider: "GitHub", category: "developer", url: "https://api.githubcopilot.com/mcp/",
      description: "GitHub's own server: repositories, code, issues, pull requests, Actions and security alerts.",
      signIn: .client, consoleURL: "https://github.com/settings/developers", logo: "github"),
    KnownServer(
      id: "cloudflare", title: "Cloudflare", provider: "Cloudflare", category: "developer", url: "https://mcp.cloudflare.com/mcp",
      description: "All of Cloudflare's API through code: Workers, DNS, R2, D1, KV, zones and the account's other products.",
      signIn: .self, logo: "cloudflare"),
    KnownServer(
      id: "cloudflare-docs", title: "Cloudflare Docs", provider: "Cloudflare", category: "developer",
      url: "https://docs.mcp.cloudflare.com/mcp", description: "Searches Cloudflare's documentation.", signIn: .none, logo: "cloudflare"),
    KnownServer(
      id: "cloudflare-observability", title: "Cloudflare Observability", provider: "Cloudflare", category: "developer",
      url: "https://observability.mcp.cloudflare.com/mcp", description: "Your Workers' logs and analytics, to debug them.",
      signIn: .self, logo: "cloudflare"),
    KnownServer(
      id: "cloudflare-browser", title: "Cloudflare Browser", provider: "Cloudflare", category: "developer",
      url: "https://browser.mcp.cloudflare.com/mcp",
      description: "Fetches web pages, turns them into Markdown and takes screenshots with Browser Rendering.", signIn: .self,
      logo: "cloudflare"),
    KnownServer(
      id: "cloudflare-containers", title: "Cloudflare Containers", provider: "Cloudflare", category: "developer",
      url: "https://containers.mcp.cloudflare.com/mcp", description: "A sandbox to run code in, in a container.", signIn: .self,
      logo: "cloudflare"),
    KnownServer(
      id: "cloudflare-radar", title: "Cloudflare Radar", provider: "Cloudflare", category: "developer",
      url: "https://radar.mcp.cloudflare.com/mcp",
      description: "Internet traffic trends, outages, attacks and domain rankings from Cloudflare Radar.", signIn: .self,
      logo: "cloudflare"),
    KnownServer(
      id: "huggingface", title: "Hugging Face", provider: "Hugging Face", category: "developer", url: "https://huggingface.co/mcp",
      description: "Searches the Hugging Face Hub's models, datasets, Spaces and papers, and runs Gradio apps.", signIn: .none,
      logo: "huggingface"),
    KnownServer(
      id: "ahrefs", title: "Ahrefs", provider: "Ahrefs", category: "marketing", url: "https://api.ahrefs.com/mcp/mcp",
      description: "Your Ahrefs data: backlinks, keywords, rankings, site metrics and competitors.", signIn: .self, logo: "ahrefs"),
    KnownServer(
      id: "strava", title: "Strava", provider: "Strava", category: "health", url: "https://mcp.strava.com/mcp",
      description: "Your Strava activities, fitness trends, training load and goals.", signIn: .self, logo: "strava"),
    KnownServer(
      id: "stripe", title: "Stripe", provider: "Stripe", category: "finance", url: "https://mcp.stripe.com",
      description: "Your Stripe account: customers, payments, subscriptions, invoices and balance, and Stripe's docs.",
      signIn: .self, logo: "stripe"),
    KnownServer(
      id: "paypal", title: "PayPal", provider: "PayPal", category: "finance", url: "https://mcp.paypal.com/mcp",
      description: "Your PayPal account: transactions, invoices, disputes and payment links.", signIn: .self, logo: "paypal"),
  ]

  /// The known server a connection's URL is, if any: by host and path, without a trailing slash.
  public static func of(url: String) -> KnownServer? {
    let at = endpoint(url)
    return all.first { endpoint($0.url) == at }
  }

  private static func endpoint(_ url: String) -> String {
    guard let components = URLComponents(string: url), let host = components.host else { return url.lowercased() }
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    return "\(host)\(path)".lowercased()
  }
}

extension JSONValue {
  /// The value as compact JSON, for a line of text.
  var compactJSON: String {
    switch self {
    case .null: "null"
    case .bool(let flag): String(flag)
    case .number(let number): number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    case .string(let text): "\"\(text)\""
    case .array(let items): "[" + items.map(\.compactJSON).joined(separator: ",") + "]"
    case .object(let fields): "{" + fields.keys.sorted().map { "\"\($0)\":\(fields[$0]!.compactJSON)" }.joined(separator: ",") + "}"
    }
  }
}
