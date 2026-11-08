import XCTest

@testable import AxoProtocol

/// Settings › Apps' listing and log, as the Worker sends them (packages/axo-api/src/apps.ts).
final class AppsTests: XCTestCase {
  private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
  }

  func testEveryKindOfConnectionAndSignInDecodesAndAnUnknownKindIsKeptAside() throws {
    let json = """
      [
      {"kind":"host","name":"studio","hostId":"18355f00-95fd-4c93-8586-a71a8a52bf73","state":"online"},
      {"kind":"thirdParty","name":"emdash_leostera_com","title":"emdash: leostera.com","url":"https://leostera.com/mcp",
       "state":"needsSignIn","tools":0,"icon":null,"syncedAt":null,"lastError":null},
      {"kind":"app","name":"apps.gmail","title":"Gmail","description":"Email.","provider":"Google","category":"communication",
       "permissions":["Read your email"],"signIn":{"kind":"oauth","client":{"provider":"google","ready":false,
       "consoleUrl":"https://console.cloud.google.com","redirectUri":"https://axo.leostera.dev/api/v1/connections/oauth/callback"}},
       "state":"needsSignIn","accounts":[],"tools":["search_messages"],"lastError":null},
      {"kind":"app","name":"apps.kraken","title":"Kraken","description":"","provider":"Kraken","category":"finance","permissions":[],
       "signIn":{"kind":"token","helpUrl":"https://pro.kraken.com","named":true,
         "fields":[{"name":"key","label":"API key","help":"","secret":false},{"name":"secret","label":"Private key","help":"In Settings.","secret":true}],
         "mac":{"title":"Sign in with Kraken","presets":[{"id":"read","label":"Read only","description":"Balances."}]}},
       "state":"ready","accounts":[{"account":"trading","state":"ready","lastError":null},
         {"account":"old","state":"needsSignIn","lastError":"Kraken refused the key."}],"tools":[],"lastError":null},
      {"kind":"app","name":"apps.chatgpt","title":"ChatGPT","signIn":{"kind":"device"},"state":"needsSignIn","accounts":[],"tools":[],"lastError":null},
      {"kind":"app","name":"apps.onepassword","title":"1Password","signIn":{"kind":"mac","setup":"Install the CLI.","helpUrl":"https://developer.1password.com"},
       "state":"ready","accounts":[{"account":"studio","state":"ready","lastError":null}],"tools":[],"lastError":null},
      {"kind":"app","name":"apps.signal","title":"Signal","signIn":{"kind":"qr","something":1},"state":"needsSignIn","accounts":[],"tools":[],"lastError":null},
      {"kind":"robot","name":"r2d2"}
      ]
      """
    let apps = try decode([AccountApp].self, json)
    XCTAssertEqual(apps.count, 8)

    guard case .host(let mac) = apps[0] else { return XCTFail("\(apps[0])") }
    XCTAssertTrue(mac.isOnline)

    guard case .server(let server) = apps[1] else { return XCTFail() }
    XCTAssertEqual(server.displayName, "emdash: leostera.com")
    XCTAssertEqual(server.state, .needsSignIn)

    guard case .app(let gmail) = apps[2] else { return XCTFail() }
    XCTAssertEqual(gmail.slug, "gmail")
    XCTAssertTrue(gmail.needsClient, "its Google client is not set up yet")
    XCTAssertFalse(gmail.isConnected)

    guard case .app(let kraken) = apps[3], case .token(let signIn) = kraken.signIn else { return XCTFail() }
    XCTAssertTrue(signIn.named)
    XCTAssertEqual(signIn.fields.map(\.secret), [false, true])
    XCTAssertEqual(signIn.mac?.presets.map(\.id), ["read"])
    XCTAssertTrue(kraken.isConnected)
    XCTAssertEqual(kraken.accounts.last?.lastError, "Kraken refused the key.")

    guard case .app(let chatgpt) = apps[4] else { return XCTFail() }
    XCTAssertEqual(chatgpt.signIn, .device)
    XCTAssertEqual(chatgpt.description, "", "a listing from an older Worker leaves these out")
    XCTAssertEqual(chatgpt.permissions, [])

    guard case .app(let onepassword) = apps[5] else { return XCTFail() }
    XCTAssertEqual(onepassword.signIn, .mac(setup: "Install the CLI.", helpUrl: "https://developer.1password.com"))

    guard case .app(let signal) = apps[6] else { return XCTFail() }
    XCTAssertEqual(signal.signIn, .unknown, "a sign-in this build does not know is added on the web")
    XCTAssertEqual(apps[7], .unknown, "a kind this build does not know is left aside, not a failed listing")
  }

  func testAnOAuthAppFromBeforeClientsWereThePersonsSignsInDirectly() throws {
    let app = try decode(AppConnection.self, #"{"kind":"app","name":"apps.gmail","title":"Gmail","state":"ready","accounts":[],"tools":[],"lastError":null}"#)
    XCTAssertEqual(app.signIn, .oauth(client: nil))
    XCTAssertFalse(app.needsClient)
  }

  func testTelegramSignsInByPhoneOnceItsAPIIDIsSetUp() throws {
    let app = try decode(
      AppConnection.self,
      #"{"kind":"app","name":"apps.telegram","title":"Telegram","signIn":{"kind":"phone","consoleUrl":"https://my.telegram.org/apps","clientHelp":"Create an app.","clientReady":false},"state":"needsSignIn","accounts":[],"tools":[],"lastError":null}"#)
    XCTAssertEqual(app.signIn, .phone(PhoneSignInOffer(consoleUrl: "https://my.telegram.org/apps", clientHelp: "Create an app.", clientReady: false)))
    XCTAssertTrue(app.needsClient)

    XCTAssertEqual(
      try decode(PhoneSignIn.self, #"{"state":"code","flow":"0123456789abcdef0","via":"sms","error":"That code is not right."}"#),
      .code(flow: "0123456789abcdef0", viaApp: false, error: "That code is not right."))
    XCTAssertEqual(
      try decode(PhoneSignIn.self, #"{"state":"password","flow":"0123456789abcdef0","hint":null}"#),
      .password(flow: "0123456789abcdef0", hint: nil, error: nil))
    XCTAssertEqual(try decode(PhoneSignIn.self, #"{"state":"done","account":"leostera"}"#), .done(account: "leostera"))
    XCTAssertEqual(PhoneSignInStep.code(flow: "f", code: "12345").body, ["step": "code", "flow": "f", "code": "12345"])
  }

  func testDeviceAndMacSignInsDecodeEachState() throws {
    XCTAssertEqual(
      try decode(DeviceSignIn.self, #"{"state":"pending","userCode":"WDJB-MJHT","verificationUrl":"https://auth.openai.com/codex/device","intervalSeconds":5,"expiresAt":"2026-11-02T10:00:00Z"}"#),
      .pending(userCode: "WDJB-MJHT", verificationUrl: "https://auth.openai.com/codex/device", intervalSeconds: 5, expiresAt: "2026-11-02T10:00:00Z"))
    XCTAssertEqual(try decode(DeviceSignIn.self, #"{"state":"done","account":"a@b.c"}"#), .done(account: "a@b.c"))
    XCTAssertEqual(try decode(DeviceSignIn.self, #"{"state":"failed","error":"Expired."}"#), .failed("Expired."))
    XCTAssertEqual(try decode(MacSignIn.self, #"{"state":"pending","mac":"studio","expiresAt":"2026-11-02T10:00:00Z"}"#), .pending(mac: "studio"))
    XCTAssertEqual(try decode(MacSignIn.self, #"{"state":"done","account":"trading","expiresAt":null}"#), .done(account: "trading"))
  }

  func testACallRecordKeepsItsInputAndTime() throws {
    let record = try decode(
      CallRecord.self,
      #"{"callId":"c1","at":"2026-11-02T10:00:00.123Z","sessionId":null,"hostId":null,"service":"apps.gmail","tool":"search_messages","targetHostId":null,"durationMs":120,"outcome":"ok","error":null,"input":{"account":"a@b.c","query":"is:unread"}}"#)
    XCTAssertEqual(record.input["query"]?.stringValue, "is:unread")
    XCTAssertNotNil(record.date, "fractional seconds read too")
    XCTAssertEqual(record.outcome, .ok)
  }
}
