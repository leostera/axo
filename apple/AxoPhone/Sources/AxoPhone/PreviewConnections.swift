#if DEBUG && targetEnvironment(simulator)
  import AxoClient
  import AxoPhoneModel
  import AxoProtocol
  import Foundation

  /// Settings › Apps for the simulator preview: a few apps of each kind of sign-in, two MCP
  /// servers and some activity, kept in memory. Adding and removing accounts works; a token
  /// spelled "bad" is refused, as a service would; device and Mac sign-ins finish on the second
  /// poll.
  final class PreviewConnections: ConnectionsService, @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: [String: [AppAccount]] = [
      "apps.gmail": [AppAccount(account: "leandro@example.com")],
      "apps.onepassword": [AppAccount(account: "studio")],
      "apps.hetzner": [AppAccount(account: "personal", state: .needsSignIn, lastError: "Hetzner refused the token.")],
    ]
    private var servers: [ServerConnection] = [
      ServerConnection(name: "Cloudflare_Docs", title: "Cloudflare Docs", url: "https://docs.mcp.cloudflare.com/mcp", state: .ready, tools: 2),
      ServerConnection(name: "emdash_leostera_com", title: "emdash: leostera.com", url: "https://leostera.com/_emdash/mcp", state: .needsSignIn),
    ]
    private var clientReady = ["apps.gmail": true, "apps.calendar": true, "apps.spotify": false, "apps.telegram": true]
    private var polls = 0

    private func locked<T>(_ work: () -> T) -> T { lock.withLock(work) }

    private func apps() -> [AppConnection] {
      func oauth(_ name: String, provider: String) -> AppSignIn {
        .oauth(client: AppOAuthClient(
          provider: provider, ready: clientReady[name] ?? true, consoleUrl: "https://console.cloud.google.com/apis/credentials",
          redirectUri: "https://axo.leostera.dev/api/v1/connections/oauth/callback"))
      }
      return [
        AppConnection(
          name: "apps.gmail", title: "Gmail", description: "Reads, searches, labels and sends your email.", provider: "Google",
          category: "communication",
          permissions: ["Read, search and label your email", "Send email as you", "Manage drafts"],
          signIn: oauth("apps.gmail", provider: "google"), accounts: accounts["apps.gmail"] ?? []),
        AppConnection(
          name: "apps.calendar", title: "Calendar", description: "Your calendars and their events.", provider: "Google",
          category: "productivity", permissions: ["See and change your events"], signIn: oauth("apps.calendar", provider: "google"),
          accounts: accounts["apps.calendar"] ?? []),
        AppConnection(
          name: "apps.spotify", title: "Spotify", description: "Playback on your devices, search, playlists and your library.",
          provider: "Spotify", category: "media", permissions: ["Control playback"], signIn: oauth("apps.spotify", provider: "spotify"),
          accounts: accounts["apps.spotify"] ?? []),
        AppConnection(
          name: "apps.hetzner", title: "Hetzner", description: "Servers, volumes, networks and firewalls in Hetzner Cloud.",
          provider: "Hetzner", category: "developer", permissions: ["Everything the token allows"],
          signIn: .token(TokenSignIn(
            helpUrl: "https://console.hetzner.cloud", named: true,
            fields: [AppTokenField(name: "token", label: "API token", help: "Create one in a project's Security › API tokens.")])),
          accounts: accounts["apps.hetzner"] ?? []),
        AppConnection(
          name: "apps.kraken", title: "Kraken", description: "Balances, orders and trades on Kraken.", provider: "Kraken",
          category: "finance",
          signIn: .token(TokenSignIn(
            helpUrl: "https://pro.kraken.com/app/settings/api", named: true,
            fields: [
              AppTokenField(name: "key", label: "API key", help: "", secret: false),
              AppTokenField(name: "secret", label: "Private key", help: "Create a key in Settings › API."),
            ],
            mac: MacSignInOffer(title: "Sign in with Kraken", presets: [
              MacSignInOffer.Preset(id: "read", label: "Read only", description: "Balances, orders and history."),
              MacSignInOffer.Preset(id: "trade", label: "Trade", description: "Also place and cancel orders."),
            ]))),
          accounts: accounts["apps.kraken"] ?? []),
        AppConnection(
          name: "apps.chatgpt", title: "ChatGPT", description: "Asks OpenAI's models with your plan.", provider: "OpenAI",
          category: "productivity", signIn: .device, accounts: accounts["apps.chatgpt"] ?? []),
        AppConnection(
          name: "apps.telegram", title: "Telegram", description: "Your chats, as a new device of yours.", provider: "Telegram",
          category: "communication", permissions: ["Read and send messages as you"],
          signIn: .phone(PhoneSignInOffer(
            consoleUrl: "https://my.telegram.org/apps", clientHelp: "At my.telegram.org, create an app under API development tools.",
            clientReady: clientReady["apps.telegram"] ?? false)),
          accounts: accounts["apps.telegram"] ?? []),
        AppConnection(
          name: "apps.onepassword", title: "1Password", description: "Items in every vault you can open.", provider: "1Password",
          category: "security",
          signIn: .mac(setup: "Install the 1Password CLI and turn on its app integration.", helpUrl: "https://developer.1password.com/docs/cli"),
          accounts: accounts["apps.onepassword"] ?? []),
      ]
    }

    func list() async throws -> [Connection] {
      try await Task.sleep(for: .milliseconds(150))
      return locked {
        apps().map { .app($0) } + servers.map { .server($0) } + [
          .host(HostConnectionInfo(name: "studio", hostId: PreviewFixture.studio, state: "online")),
          .host(HostConnectionInfo(name: "old_imac", hostId: PreviewFixture.imac, state: "offline")),
        ]
      }
    }

    func log(service: String?, limit: Int, before: String?) async throws -> [CallRecord] {
      let now = Date.now
      func at(_ minutes: Double) -> String { now.addingTimeInterval(-minutes * 60).formatted(.iso8601) }
      let all = [
        CallRecord(
          callId: "1", at: at(4), service: "apps.gmail", tool: "search_messages",
          input: .object(["account": .string("leandro@example.com"), "query": .string("from:github is:unread")])),
        CallRecord(callId: "2", at: at(30), service: "studio", tool: "bash", input: .object(["command": .string("git status --short")])),
        CallRecord(
          callId: "3", at: at(95), service: "apps.hetzner", tool: "list_servers", outcome: .error,
          error: "Hetzner refused the token.", input: .object(["account": .string("personal")])),
      ]
      return Array(all.filter { service == nil || $0.service == service }.prefix(limit))
    }

    func integrity() async throws -> CallLogIntegrity { CallLogIntegrity(verified: true, events: 3) }

    func addToken(app: String, account: String?, fields: [String: String]) async throws -> String {
      try await Task.sleep(for: .milliseconds(150))
      if fields.values.contains("bad") { throw ConnectionsRefusal(status: 400, message: "Hetzner refused that token.") }
      return locked {
        let name = account ?? "account"
        var list = accounts[app] ?? []
        list.removeAll { $0.account == name }
        list.append(AppAccount(account: name))
        accounts[app] = list
        return name
      }
    }

    func startDeviceSignIn(app: String) async throws -> (flow: String, state: DeviceSignIn) {
      locked { polls = 0 }
      return ("device-flow", .pending(userCode: "WDJB-MJHT", verificationUrl: "https://auth.openai.com/codex/device", intervalSeconds: 1, expiresAt: ""))
    }

    func pollDeviceSignIn(app: String, flow: String) async throws -> DeviceSignIn {
      locked {
        polls += 1
        guard polls >= 2 else {
          return .pending(userCode: "WDJB-MJHT", verificationUrl: "https://auth.openai.com/codex/device", intervalSeconds: 1, expiresAt: "")
        }
        accounts[app, default: []].append(AppAccount(account: "leandro@example.com"))
        return .done(account: "leandro@example.com")
      }
    }

    func startMacSignIn(app: String, mac: String, preset: String, account: String?) async throws -> String {
      locked { polls = 0 }
      return "mac-flow"
    }

    func pollMacSignIn(app: String, flow: String) async throws -> MacSignIn {
      locked {
        polls += 1
        guard polls >= 2 else { return .pending(mac: "studio") }
        accounts[app, default: []].append(AppAccount(account: "trading"))
        return .done(account: "trading")
      }
    }

    /// Telegram's sign-in: any number gets a code sent to the app; 00000 is not right; the
    /// account has a password, which anything but "wrong" passes.
    func phoneSignIn(app: String, step: PhoneSignInStep) async throws -> PhoneSignIn {
      let flow = "preview-flow-0123456789"
      switch step {
      case .start: return .code(flow: flow, viaApp: true, error: nil)
      case .code(_, let code):
        return code == "00000"
          ? .code(flow: flow, viaApp: true, error: "That code is not right. Enter the newest one.")
          : .password(flow: flow, hint: "pet", error: nil)
      case .password(_, let password):
        if password == "wrong" { return .password(flow: flow, hint: "pet", error: "That password is not right.") }
        return locked {
          accounts[app, default: []].append(AppAccount(account: "leostera"))
          return .done(account: "leostera")
        }
      }
    }

    func setClient(_ name: String, clientId: String, clientSecret: String?) async throws -> String {
      locked { clientReady[name] = true }
      return "https://axo.leostera.dev/api/v1/connections/oauth/start?flow=preview"
    }

    func remove(_ name: String, account: String?) async throws {
      locked {
        if let account { accounts[name]?.removeAll { $0.account == account } } else { servers.removeAll { $0.name == name } }
      }
    }

    func addServer(name: String, url: String) async throws -> (connection: Connection, signInUrl: String?) {
      locked {
        let slug = name.map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce(into: "") { $0.append($1) }
        let server = ServerConnection(name: slug, title: name, url: url, state: url.contains("signin") ? .needsSignIn : .ready, tools: 3)
        servers.append(server)
        return (.server(server), server.state == .needsSignIn ? "https://axo.leostera.dev/api/v1/connections/oauth/start?flow=x" : nil)
      }
    }

    func webPage(for app: AppConnection?) -> URL {
      URL(string: "https://axo.leostera.dev/app/settings/apps/\(app?.slug ?? "mcp")")!
    }
  }
#endif
