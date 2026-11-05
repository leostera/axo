import CryptoKit
import Foundation
import XCTest

@testable import AxoProtocol

final class InputSealTests: XCTestCase {
  /// What the phone seals opens with the Mac's key for that request and address only; axod opens
  /// the same with `axo-seal` (crates/axo-seal/testdata/vectors.json, case "cryptokit").
  func testSealedValuesOpenOnlyForTheirRequestAndAddress() throws {
    let mac = P256.KeyAgreement.PrivateKey()
    let key = mac.publicKey.x963Representation.base64EncodedString()
    let sealed = try InputSeal.seal(["f0": "hunter2"], to: key, requestID: "r1", origin: "https://github.com")
    func open(_ origin: String) throws -> Data {
      var recipient = try HPKE.Recipient(
        privateKey: mac, ciphersuite: .P256_SHA256_AES_GCM_256, info: InputSeal.info,
        encapsulatedKey: Data(base64Encoded: sealed.enc)!)
      return try recipient.open(Data(base64Encoded: sealed.ciphertext)!, authenticating: InputSeal.aad(requestID: "r1", origin: origin))
    }
    XCTAssertEqual(String(data: try open("https://github.com"), encoding: .utf8), #"{"values":{"f0":"hunter2"}}"#)
    XCTAssertThrowsError(try open("https://github.co"))
    XCTAssertThrowsError(try InputSeal.seal([:], to: "not a key", requestID: "r1", origin: nil))
    XCTAssertEqual(InputSeal.fingerprint(of: key).count, 19)
  }

  func testTheFirstKeySeenForAMacIsTheOneUsed() {
    let defaults = UserDefaults(suiteName: "axo-input-pins-\(UUID())")!
    let pins = InputKeyPins(defaults: defaults)
    let host = UUID()
    XCTAssertEqual(pins.check(host: host, key: "A"), .pinned)
    XCTAssertEqual(pins.check(host: host, key: "A"), .same)
    XCTAssertEqual(pins.check(host: host, key: "B"), .changed)
  }

  func testAnInputRequestDecodes() throws {
    let json = #"{"id":"6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5a","sessionId":"00000000-0000-0000-0000-000000000001","kind":"input","askedBy":"computerUse","message":"Fill Password.","input":{"app":"Safari","window":"Sign in","origin":"https://github.com","fields":[{"id":"f0","label":"Password","kind":"password"}],"submit":"Sign in","key":"QQ=="},"createdAt":1,"expiresAt":2}"#
    let elicitation = try JSONDecoder().decode(Elicitation.self, from: Data(json.utf8))
    XCTAssertEqual(elicitation.kind, .input)
    XCTAssertEqual(elicitation.input?.fields.first?.kind, .password)
    XCTAssertEqual(elicitation.input?.submit, "Sign in")
  }
}
