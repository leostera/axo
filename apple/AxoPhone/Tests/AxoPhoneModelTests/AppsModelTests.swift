import AxoClient
import AxoProtocol
import XCTest

@testable import AxoPhoneModel

/// Settings › Apps' API, answered from memory, recording what was asked.
private final class FakeApps: AppsService, @unchecked Sendable {
  private let lock = NSLock()
  var apps: [Connection] = []
  var failList: Error?
  var refuseTokens = false
  var deviceAnswers: [DeviceSignIn] = []
  var macAnswers: [MacSignIn] = []
  var addAnswer: (Connection, String?)?
  var phoneAnswers: [PhoneSignIn] = []
  private(set) var calls: [String] = []

  private func note(_ call: String) { lock.withLock { calls.append(call) } }

  func list() async throws -> [Connection] {
    note("list")
    if let failList { throw failList }
    return apps
  }
  func log(service: String?, limit: Int, before: String?) async throws -> [CallRecord] { [] }
  func integrity() async throws -> CallLogIntegrity { CallLogIntegrity(verified: true, events: 0) }
  func addToken(app: String, account: String?, fields: [String: String]) async throws -> String {
    note("token \(app) \(account ?? "-") \(fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")
    if refuseTokens { throw AppsRefusal(status: 400, message: "Hetzner refused that token.") }
    return account ?? "a@b.c"
  }
  func startDeviceSignIn(app: String) async throws -> (flow: String, state: DeviceSignIn) {
    note("device \(app)")
    return ("flow-1", .pending(userCode: "WDJB-MJHT", verificationUrl: "https://auth.openai.com/codex/device", intervalSeconds: 5, expiresAt: ""))
  }
  func pollDeviceSignIn(app: String, flow: String) async throws -> DeviceSignIn {
    lock.withLock {
      calls.append("poll \(flow)")
      return deviceAnswers.isEmpty ? .pending(userCode: "WDJB-MJHT", verificationUrl: "", intervalSeconds: 5, expiresAt: "") : deviceAnswers.removeFirst()
    }
  }
  func startMacSignIn(app: String, mac: String, preset: String, account: String?) async throws -> String {
    note("mac \(app) \(mac) \(preset) \(account ?? "-")")
    return "mac-flow"
  }
  func pollMacSignIn(app: String, flow: String) async throws -> MacSignIn {
    lock.withLock {
      calls.append("macpoll \(flow)")
      return macAnswers.isEmpty ? .pending(mac: "studio") : macAnswers.removeFirst()
    }
  }
  func phoneSignIn(app: String, step: PhoneSignInStep) async throws -> PhoneSignIn {
    lock.withLock {
      calls.append("phone \(app) \(step.body.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")
      return phoneAnswers.isEmpty ? .failed("no answer") : phoneAnswers.removeFirst()
    }
  }
  func setClient(_ name: String, clientId: String, clientSecret: String?) async throws -> String {
    note("client \(name) \(clientId) \(clientSecret ?? "-")")
    return "https://axo.leostera.dev/api/v1/connections/oauth/start?flow=x"
  }
  func remove(_ name: String, account: String?) async throws { note("remove \(name) \(account ?? "-")") }
  func addServer(name: String, url: String) async throws -> (connection: Connection, signInUrl: String?) {
    note("add \(name) \(url)")
    return addAnswer ?? (.server(ServerConnection(name: "x", url: url, state: .ready)), nil)
  }
  func webPage(for app: AppConnection?) -> URL { URL(string: "https://axo.leostera.dev/app/settings/apps/\(app?.slug ?? "mcp")")! }
}

@MainActor
final class AppsModelTests: XCTestCase {
  private let hetzner = AppConnection(
    name: "apps.hetzner", title: "Hetzner", provider: "Hetzner",
    signIn: .token(TokenSignIn(helpUrl: "https://console.hetzner.cloud", named: true, fields: [AppTokenField(name: "token", label: "API token")])))
  private let chatgpt = AppConnection(name: "apps.chatgpt", title: "ChatGPT", provider: "OpenAI", signIn: .device)

  /// A model whose polls do not wait, and the fake behind it.
  private func world(_ apps: [Connection] = []) -> (AppsModel, FakeApps) {
    let fake = FakeApps()
    fake.apps = apps
    return (AppsModel(service: fake, pause: { _ in await Task.yield() }), fake)
  }

  func testTheListingIsSplitIntoAppsServersAndMacs() async {
    let (model, _) = world([
      .app(hetzner), .server(ServerConnection(name: "docs", url: "https://docs.mcp.cloudflare.com/mcp", state: .ready)),
      .host(HostConnectionInfo(name: "studio", hostId: UUID(), state: "online")), .unknown,
    ])
    await model.refresh()
    XCTAssertEqual(model.phase, .loaded)
    XCTAssertEqual(model.apps.map(\.name), ["apps.hetzner"])
    XCTAssertEqual(model.servers.map(\.name), ["docs"])
    XCTAssertEqual(model.macs.map(\.name), ["studio"])
  }

  func testAFirstListingThatFailsSaysWhyAndALaterOneKeepsWhatIsShown() async {
    let (model, fake) = world([.app(hetzner)])
    fake.failList = AppsRefusal(status: 503, message: "Apps are unavailable")
    await model.refresh()
    XCTAssertEqual(model.phase, .failed("Apps are unavailable"))
    fake.failList = nil
    await model.refresh()
    fake.failList = RelayError.unreachable("offline")
    await model.refresh()
    XCTAssertEqual(model.phase, .loaded, "what was read stays")
    XCTAssertEqual(model.apps.count, 1)
    XCTAssertEqual(model.notice?.kind, .problem)
  }

  func testATokenIsAddedUnderALowercaseNameAndTheListingIsReadAgain() async {
    let (model, fake) = world([.app(hetzner)])
    await model.refresh()
    let added = await model.addToken(to: hetzner, account: "  Personal ", fields: ["token": "s3cret"])
    XCTAssertTrue(added)
    XCTAssertEqual(fake.calls, ["list", "token apps.hetzner personal token=s3cret", "list"])
    XCTAssertEqual(model.notice, AppsModel.Notice(kind: .done, text: "Added personal."))
    XCTAssertFalse(model.isBusy)
  }

  func testARefusedTokenSaysWhatTheServiceSaid() async {
    let (model, fake) = world([.app(hetzner)])
    fake.refuseTokens = true
    let added = await model.addToken(to: hetzner, account: nil, fields: ["token": "bad"])
    XCTAssertFalse(added)
    XCTAssertEqual(model.notice, AppsModel.Notice(kind: .problem, text: "Hetzner refused that token."))
  }

  func testADeviceSignInShowsItsCodeUntilTheProviderSaysItIsDone() async throws {
    let (model, fake) = world([.app(chatgpt)])
    fake.deviceAnswers = [.pending(userCode: "WDJB-MJHT", verificationUrl: "", intervalSeconds: 5, expiresAt: ""), .done(account: "a@b.c")]
    await model.startDeviceSignIn(for: chatgpt)
    XCTAssertEqual(model.deviceFlow?.userCode, "WDJB-MJHT")
    XCTAssertEqual(model.deviceFlow?.verificationURL?.host(), "auth.openai.com")
    try await eventually { model.deviceFlow == nil }
    XCTAssertEqual(model.notice, AppsModel.Notice(kind: .done, text: "Added a@b.c."))
    try await eventually { fake.calls.filter { $0 == "list" }.count >= 2 }
  }

  func testAFailedDeviceSignInSaysWhyAndCancellingStopsAsking() async throws {
    let (model, fake) = world([.app(chatgpt)])
    fake.deviceAnswers = [.failed("The code expired.")]
    await model.startDeviceSignIn(for: chatgpt)
    try await eventually { model.deviceFlow == nil }
    XCTAssertEqual(model.notice, AppsModel.Notice(kind: .problem, text: "The code expired."))

    let (waiting, slow) = world([.app(chatgpt)])
    await waiting.startDeviceSignIn(for: chatgpt)
    waiting.cancelSignIn()
    XCTAssertNil(waiting.deviceFlow)
    // A poll already on its way may still land; its answer is dropped.
    try await Task.sleep(for: .milliseconds(20))
    let polled = slow.calls.filter { $0.hasPrefix("poll") }.count
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(slow.calls.filter { $0.hasPrefix("poll") }.count, polled, "no more asking once cancelled")
  }

  func testASignInOnAMacWaitsForThePersonThere() async throws {
    let (model, fake) = world([.app(hetzner)])
    fake.macAnswers = [.pending(mac: "studio"), .done(account: "trading")]
    await model.startMacSignIn(for: hetzner, on: "studio", preset: "read", account: "Trading")
    XCTAssertEqual(model.macFlow, AppsModel.MacFlow(app: "apps.hetzner", flow: "mac-flow", mac: "studio"))
    XCTAssertTrue(fake.calls.contains("mac apps.hetzner studio read trading"))
    try await eventually { model.macFlow == nil }
    XCTAssertEqual(model.notice?.text, "Added trading.")
  }

  func testAServerThatNeedsABrowserSignInSaysSo() async {
    let (model, fake) = world()
    fake.addAnswer = (.server(ServerConnection(name: "emdash", url: "https://leostera.com/mcp", state: .needsSignIn)), "https://axo.leostera.dev/api/v1/connections/oauth/start?flow=x")
    let outcome = await model.addServer(name: " emdash ", url: " https://leostera.com/mcp ")
    XCTAssertEqual(outcome, .needsSignIn)
    XCTAssertTrue(fake.calls.contains("add emdash https://leostera.com/mcp"), "trimmed")

    fake.addAnswer = (.server(ServerConnection(name: "docs", title: "Docs", url: "https://docs.mcp.cloudflare.com/mcp", state: .ready)), nil)
    let ready = await model.addServer(name: "Docs", url: "https://docs.mcp.cloudflare.com/mcp")
    XCTAssertEqual(ready, .added)
    XCTAssertEqual(model.notice?.text, "Added Docs.")
  }

  func testAClientIsSavedTrimmedAndSaysWhatIsNext() async {
    let gmail = AppConnection(name: "apps.gmail", title: "Gmail", provider: "Google")
    let (model, fake) = world([.app(gmail)])
    let saved = await model.setClient(of: gmail, clientId: " id.apps.googleusercontent.com ", clientSecret: " shh ")
    XCTAssertTrue(saved)
    XCTAssertTrue(fake.calls.contains("client apps.gmail id.apps.googleusercontent.com shh"))
    XCTAssertEqual(model.notice?.text, "Google is set up. Add an account.")
  }

  func testAPhoneSignInGoesFromNumberToCodeToPasswordAndSaysWhoWasAdded() async {
    let telegram = AppConnection(
      name: "apps.telegram", title: "Telegram", provider: "Telegram",
      signIn: .phone(PhoneSignInOffer(consoleUrl: "https://my.telegram.org", clientHelp: "", clientReady: true)))
    let (model, fake) = world([.app(telegram)])
    fake.phoneAnswers = [
      .code(flow: "flow-0123456789abcdef", viaApp: true, error: nil),
      .password(flow: "flow-0123456789abcdef", hint: "pet", error: nil),
      .done(account: "leostera"),
    ]
    let code = await model.phoneSignIn(telegram, step: .start(phone: "+44 7700 900123"))
    XCTAssertEqual(code, .code(flow: "flow-0123456789abcdef", viaApp: true, error: nil))
    XCTAssertNil(model.notice, "a step that goes on says nothing yet")
    _ = await model.phoneSignIn(telegram, step: .code(flow: "flow-0123456789abcdef", code: "12345"))
    let done = await model.phoneSignIn(telegram, step: .password(flow: "flow-0123456789abcdef", password: "hunter2"))
    XCTAssertEqual(done, .done(account: "leostera"))
    XCTAssertEqual(model.notice?.text, "Added leostera.")
    XCTAssertEqual(fake.calls.filter { $0.hasPrefix("phone") }, [
      "phone apps.telegram phone=+44 7700 900123,step=start",
      "phone apps.telegram code=12345,flow=flow-0123456789abcdef,step=code",
      "phone apps.telegram flow=flow-0123456789abcdef,password=hunter2,step=password",
    ])
  }

  func testAPhoneAppWithoutItsAPIIDNeedsSettingUpFirst() {
    let unset = AppConnection(
      name: "apps.telegram", title: "Telegram",
      signIn: .phone(PhoneSignInOffer(consoleUrl: "https://my.telegram.org", clientHelp: "", clientReady: false)))
    XCTAssertTrue(unset.needsClient)
    XCTAssertEqual(AppsCatalog.detail(of: unset), "Needs set-up")
  }

  // MARK: - What the pages show

  func testACallReadsAsItsToolAndWhatItWasAbout() {
    let search = CallRecord(
      callId: "1", at: "", service: "apps.gmail", tool: "search_messages",
      input: .object(["account": .string("a@b.c"), "query": .string("is:unread"), "limit": .number(10)]))
    XCTAssertEqual(AppsCatalog.callTitle(search, ofOne: true), "Search messages")
    XCTAssertEqual(AppsCatalog.callTitle(search, ofOne: false, titles: ["apps.gmail": "Gmail"]), "Gmail · Search messages")
    let click = CallRecord(callId: "3", at: "", service: "computer", tool: "click", input: .object([:]))
    XCTAssertEqual(AppsCatalog.callTitle(click, ofOne: false), "Computer use · Click")
    XCTAssertEqual(AppsCatalog.summary(search), "a@b.c · 10 · is:unread", "the account first, then the values")

    let bash = CallRecord(callId: "2", at: "", service: "studio", tool: "bash", error: "exit 1", input: .object(["command": .string("git  status\n --short")]))
    XCTAssertEqual(AppsCatalog.summary(bash), "git status --short · exit 1")
  }

  func testAServerAddedByAKnownURLIsThatServerTrailingSlashOrNot() {
    XCTAssertEqual(KnownServer.of(url: "https://api.githubcopilot.com/mcp")?.id, "github")
    XCTAssertEqual(KnownServer.of(url: "https://MCP.cloudflare.com/mcp/")?.id, "cloudflare")
    XCTAssertNil(KnownServer.of(url: "https://leostera.com/mcp"))
  }

  func testATilesDetailSaysWhatItNeeds() {
    let unset = AppConnection(
      name: "apps.gmail", title: "Gmail",
      signIn: .oauth(client: AppOAuthClient(provider: "google", ready: false, consoleUrl: "https://x", redirectUri: "https://y")))
    XCTAssertEqual(AppsCatalog.detail(of: unset), "Needs set-up")
    XCTAssertEqual(AppsCatalog.detail(of: hetzner), "No accounts")
    let onepassword = AppConnection(name: "apps.onepassword", title: "1Password", signIn: .mac(setup: "", helpUrl: ""), accounts: [AppAccount(account: "studio")])
    XCTAssertEqual(AppsCatalog.detail(of: onepassword), "1 Mac")
  }
}
