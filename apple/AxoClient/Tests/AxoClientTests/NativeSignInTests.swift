import CryptoKit
import XCTest

@testable import AxoClient

final class NativeSignInTests: XCTestCase {
  private let endpoint = RelayEndpoint.production

  private func make(_ loader: SignInStub = SignInStub(status: 200, body: "{}")) -> NativeSignIn {
    NativeSignIn(
      endpoint: endpoint, loader: loader,
      randomBytes: { (0..<32).map { UInt8($0) } })
  }

  func testBeginningSendsTheBrowserToTheWorkerWithOnlyTheChallenge() throws {
    let attempt = make().begin()
    let components = try XCTUnwrap(URLComponents(url: attempt.url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.host, "axo.leostera.dev")
    XCTAssertEqual(components.path, "/api/auth/cloudflare/start")
    let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(items["client"], "native")
    XCTAssertEqual(items.count, 2, "nothing but the client and the challenge")
    // The challenge is S256 of the verifier, which stays in the app.
    let verifier = Data((0..<32).map { UInt8($0) }).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let expected = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    XCTAssertEqual(items["challenge"], expected)
    XCTAssertFalse(attempt.url.absoluteString.contains(verifier), "the secret is not in the URL")
    XCTAssertEqual(items["challenge"]?.count, 43)
  }

  func testEachAttemptHasItsOwnSecretWithTheSystemGenerator() {
    let signIn = NativeSignIn(endpoint: endpoint, loader: SignInStub(status: 200, body: "{}"))
    XCTAssertNotEqual(signIn.begin().url, signIn.begin().url)
  }

  func testTheCodeAndTheSecretAreTradedForASessionTheAppCanUse() async throws {
    let token = SessionToken.fixture(9)
    let body = """
      {"token":"\(token.value)","accountId":"\(token.accountID.uuidString.lowercased())",
      "profile":{"email":null,"name":null},"expiresAt":"2027-01-20T10:30:00.123Z"}
      """
    let loader = SignInStub(status: 200, body: body)
    let signIn = make(loader)
    let attempt = signIn.begin()
    let session = try await signIn.complete(attempt, callback: URL(string: "axo://auth/callback?code=\(token.accountID).abc_DEF-123")!)
    XCTAssertEqual(session.token, token)
    XCTAssertEqual(session.accountID, token.accountID)
    XCTAssertEqual(session.expiresAt.timeIntervalSince1970, 1_800_441_000.123, accuracy: 0.001)

    let request = try XCTUnwrap(loader.requests.first)
    XCTAssertEqual(request.url?.path, "/api/auth/token")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
    XCTAssertEqual(sent["code"], "\(token.accountID).abc_DEF-123")
    XCTAssertEqual(sent["verifier"]?.count, 43)
  }

  func testACancelledOrForeignCallbackNeverReachesTheRelay() async {
    let loader = SignInStub(status: 200, body: "{}")
    let signIn = make(loader)
    let attempt = signIn.begin()
    let cases: [(String, SignInError)] = [
      ("axo://auth/callback?error=cancelled", .cancelled),
      ("axo://auth/callback?error=access_denied&code=x", .cancelled),
      ("axo://auth/callback", .invalidCallback),
      ("axo://auth/callback?code=", .invalidCallback),
      ("axo://auth/callback?code=has space", .invalidCallback),
      ("axo://auth/callback?code=\(String(repeating: "a", count: 300))", .invalidCallback),
      ("axo://pair/callback?code=x", .invalidCallback),
      ("axo://auth/other?code=x", .invalidCallback),
      ("https://evil.test/auth/callback?code=x", .invalidCallback),
      ("other://auth/callback?code=x", .invalidCallback),
    ]
    for (link, expected) in cases {
      do {
        _ = try await signIn.complete(attempt, callback: URL(string: link.replacingOccurrences(of: " ", with: "%20"))!)
        XCTFail("\(link) must not complete")
      } catch {
        XCTAssertEqual(error as? SignInError, expected, link)
      }
    }
    XCTAssertTrue(loader.requests.isEmpty)
  }

  func testTheRelayRefusingTheCodeIsAClearError() async {
    let signIn = make(SignInStub(status: 400, body: #"{"error":"invalid_grant"}"#))
    do {
      _ = try await signIn.complete(signIn.begin(), callback: URL(string: "axo://auth/callback?code=a.b")!)
      XCTFail()
    } catch {
      XCTAssertEqual(error as? SignInError, .refused)
    }
    let down = make(SignInStub(status: 503, body: ""))
    do {
      _ = try await down.complete(down.begin(), callback: URL(string: "axo://auth/callback?code=a.b")!)
      XCTFail()
    } catch {
      XCTAssertEqual(error as? RelayError, .httpStatus(503))
    }
  }

  func testAnAnswerThatIsNotASessionForThatAccountIsRejected() async {
    let token = SessionToken.fixture(2)
    let other = UUID().uuidString.lowercased()
    for body in [
      "not json", "{}",
      #"{"token":"nonsense","accountId":"\#(token.accountID.uuidString.lowercased())","expiresAt":"2027-01-20T10:30:00.123Z"}"#,
      #"{"token":"\#(token.value)","accountId":"\#(other)","expiresAt":"2027-01-20T10:30:00.123Z"}"#,
      #"{"token":"\#(token.value)","accountId":"\#(token.accountID.uuidString.lowercased())","expiresAt":"tomorrow"}"#,
    ] {
      let signIn = make(SignInStub(status: 200, body: body))
      do {
        _ = try await signIn.complete(signIn.begin(), callback: URL(string: "axo://auth/callback?code=a.b")!)
        XCTFail(body)
      } catch {
        guard case .invalidResponse = error as? AxoClientError else { return XCTFail("\(body): \(error)") }
      }
    }
  }
}

final class SignInStub: HTTPDataLoading, @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [URLRequest] = []
  let status: Int
  let body: String

  init(status: Int, body: String) {
    self.status = status
    self.body = body
  }

  var requests: [URLRequest] { lock.withLock { seen } }

  func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    lock.withLock { seen.append(request) }
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }
}
