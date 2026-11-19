import AxoMobileModel
import AxoProtocol
import CryptoKit
import UserNotifications
import XCTest

final class RequestNotificationTextInputTests: XCTestCase {
  private let session = UUID()
  private let request = UUID()
  private func question(fields: [InputRequest.Field] = [.init(id: "f0", label: "Reply", kind: .text)],
    message: String = "Name 🦎?", key: String = Data(repeating: 1, count: 65).base64EncodedString(),
    origin: String? = "https://example.test", app: String = "Fixture", window: String = "Reply", submit: String? = "Save"
  ) -> Elicitation {
    Elicitation(id: request.uuidString.lowercased(), sessionId: SessionID(session), kind: .input, askedBy: .computerUse,
      message: message, input: InputRequest(app: app, window: window, origin: origin, fields: fields, submit: submit, key: key),
      createdAt: 0, expiresAt: 200_000)
  }

  private func route(account: UUID = UUID()) throws -> RequestNotificationRoute {
    try XCTUnwrap(RequestNotificationRoute(userInfo: ["axo": ["version": 1,
      "accountId": account.uuidString, "hostId": UUID().uuidString, "sessionId": session.uuidString, "requestId": request.uuidString]]))
  }

  func testNativeQuickReplyRequiresUnlockAndHasNoForegroundOrApprovalAction() throws {
    let category = RequestNotificationReplyAction.category()
    XCTAssertEqual(category.identifier, "AXO_INPUT_TEXT_V1")
    XCTAssertEqual(category.actions.count, 1)
    let action = try XCTUnwrap(category.actions.first as? UNTextInputNotificationAction)
    XCTAssertEqual(action.identifier, "AXO_INPUT_REPLY_V1")
    XCTAssertEqual(action.textInputButtonTitle, "Send")
    XCTAssertTrue(action.options.contains(.authenticationRequired))
    XCTAssertFalse(action.options.contains(.foreground))
  }

  func testSwiftAndWorkerShareTheUnicodeTargetBindingVector() throws {
    let candidate = try XCTUnwrap(RequestNotificationTextInput(question()))
    XCTAssertEqual(candidate.body, "Name 🦎?\nFixture · Reply\nhttps://example.test\nReply\nThen: Save")
    XCTAssertEqual(candidate.digest, "785ea9e95e570d37352fe211463caa65d2b2d6c883d9e8a32f5926b88fabdcf4")
    for changed in [question(origin: "https://other.test"), question(app: "Other"), question(window: "Other"),
      question(submit: nil), question(key: Data(repeating: 2, count: 65).base64EncodedString()),
      question(fields: [.init(id: "f1", label: "Reply", kind: .text)])] {
      XCTAssertNotEqual(try XCTUnwrap(RequestNotificationTextInput(changed)).digest, candidate.digest)
    }
  }

  func testSecretsFormsAndIncompletePreviewsRemainInTheApp() {
    for kind in [InputRequest.Field.Kind.password, .code, .email, .username] {
      XCTAssertNil(RequestNotificationTextInput(question(fields: [.init(id: "f0", label: "Private", kind: kind)])))
    }
    XCTAssertNil(RequestNotificationTextInput(question(fields: [])))
    XCTAssertNil(RequestNotificationTextInput(question(fields: [
      .init(id: "f0", label: "First", kind: .text), .init(id: "f1", label: "Second", kind: .text)])))
    XCTAssertNil(RequestNotificationTextInput(question(message: String(repeating: "🦎", count: 141))))
  }

  func testOnlyUnchangedUnexpiredFullRouteAndBodyCanProduceAReply() throws {
    let question = question()
    let candidate = try XCTUnwrap(RequestNotificationTextInput(question))
    let route = try route()
    let action = try XCTUnwrap(RequestNotificationAction(userInfo: ["axoInput": ["version": 1,
      "digest": candidate.digest, "expiresAt": question.expiresAt]]))
    let now = Date(timeIntervalSince1970: 100)
    XCTAssertNotNil(action.textInput(question, route: route, displayedBody: candidate.body, now: now))
    XCTAssertNil(action.textInput(question, route: route, displayedBody: "Changed target", now: now))
    XCTAssertNil(action.textInput(question, route: route, displayedBody: candidate.body, now: Date(timeIntervalSince1970: 200)))
    XCTAssertFalse(action.matches(question, route: route, displayedMessage: question.message, now: now))
    XCTAssertNil(RequestNotificationAction(userInfo: ["axoInput": ["version": 1, "digest": candidate.digest, "expiresAt": 200_000],
      "axoRequest": ["version": 1, "digest": candidate.digest, "expiresAt": 200_000]]))
    let other = Elicitation(id: UUID().uuidString.lowercased(), sessionId: question.sessionId, kind: .input,
      message: question.message, input: question.input, createdAt: 0, expiresAt: question.expiresAt)
    XCTAssertNil(action.textInput(other, route: route, displayedBody: candidate.body, now: now))
  }

  func testReplyIsSealedWithoutTrimmingAndBoundToRequestAndOrigin() throws {
    let key = P256.KeyAgreement.PrivateKey()
    let question = question(key: key.publicKey.x963Representation.base64EncodedString())
    let candidate = try XCTUnwrap(RequestNotificationTextInput(question))
    let sealed = try candidate.seal("  harmless 🦎\nreply  ", requestID: question.id)
    func open(_ requestID: String, _ origin: String?) throws -> Data {
      var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: .P256_SHA256_AES_GCM_256,
        info: InputSeal.info, encapsulatedKey: XCTUnwrap(Data(base64Encoded: sealed.enc)))
      return try recipient.open(XCTUnwrap(Data(base64Encoded: sealed.ciphertext)),
        authenticating: InputSeal.aad(requestID: requestID, origin: origin))
    }
    let value = try JSONSerialization.jsonObject(with: open(question.id, question.input?.origin)) as? [String: [String: String]]
    XCTAssertEqual(value?["values"]?["f0"], "  harmless 🦎\nreply  ")
    XCTAssertThrowsError(try open("other-request", question.input?.origin))
    XCTAssertThrowsError(try open(question.id, "https://other.test"))
    XCTAssertThrowsError(try candidate.seal("", requestID: question.id))
    XCTAssertThrowsError(try candidate.seal(String(repeating: "🦎", count: 1001), requestID: question.id))
    XCTAssertNoThrow(try candidate.seal(String(repeating: "🦎", count: 1000), requestID: question.id))
  }

  @MainActor
  func testReplyDispatchFenceSurvivesRecreationAndStoresNoReplyText() throws {
    let name = "axo-reply-ledger-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    let route = try route()
    let now = Date(timeIntervalSince1970: 100)
    XCTAssertTrue(RequestNotificationReplyLedger(defaults: defaults).claim(route, expiresAt: 200_000, now: now))
    XCTAssertFalse(RequestNotificationReplyLedger(defaults: defaults).claim(route, expiresAt: 200_000, now: now))
    XCTAssertFalse(RequestNotificationReplyLedger(defaults: defaults).claim(route, expiresAt: 200_000,
      now: Date(timeIntervalSince1970: 200)))
    let stored = try XCTUnwrap(defaults.dictionary(forKey: "push.inputReplyAttempts.v1"))
    XCTAssertEqual(stored.count, 1)
    XCTAssertTrue(stored.values.allSatisfy { $0 is NSNumber })
  }
}
