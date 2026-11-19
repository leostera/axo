import CryptoKit
import Foundation
import XCTest
@testable import AxoProtocol

final class DeviceLinkCodeTests: XCTestCase {
  func testCandidateCodeIsPrivateAccountBoundExpiringAndProvesItsDeviceKey() throws {
    let account = UUID(), now = Date(timeIntervalSince1970: 1000)
    let signer = SoftwareDeviceSigner()
    let code = try ClientDeviceLinkCode.create(account: account, name: "New iPad", signer: signer, now: now)
    let text = try code.qrText
    let scanned = try ClientDeviceLinkCode.scan(text, account: account, now: now)
    XCTAssertEqual(scanned.candidate.key, signer.publicKey)
    XCTAssertThrowsError(try ClientDeviceLinkCode.scan(text, account: UUID(), now: now))
    XCTAssertThrowsError(try ClientDeviceLinkCode.scan(text, account: account, now: now.addingTimeInterval(301)))
    XCTAssertThrowsError(try ClientDeviceLinkCode.scan("https://example.invalid/link", account: account, now: now))
    let privateObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(code)) as? [String: Any])
    let secret = try XCTUnwrap(privateObject["secret"] as? String)
    let publicRequest = String(decoding: try JSONEncoder().encode(DeviceLinkMailboxCommand.create(code.candidate)), as: UTF8.self)
    XCTAssertFalse(publicRequest.contains(secret), "the cloud must never receive the camera capability")
    XCTAssertFalse(String(describing: code).contains(secret))
    var changed = privateObject
    var candidate = try XCTUnwrap(changed["candidate"] as? [String: Any])
    candidate["key"] = SoftwareDeviceSigner().publicKey
    changed["candidate"] = candidate
    let forged = "AXO-CLIENT-LINK-1:" + (try JSONSerialization.data(withJSONObject: changed)).base64EncodedString()
    XCTAssertThrowsError(try ClientDeviceLinkCode.scan(forged, account: account, now: now))
  }

  func testOnlyTheScannedDeviceCanOpenTheTrustBundleAndItCannotBecomeAManager() throws {
    let account = UUID(), now = Date(timeIntervalSince1970: 1000)
    let code = try ClientDeviceLinkCode.create(account: account, name: "iPad", signer: SoftwareDeviceSigner(), now: now)
    let macKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
    let host = DeviceLinkHost(hostId: UUID(), inputKey: macKey, canLinkDevices: false)
    let box = try code.seal(DeviceLinkBundle(candidate: code.candidate, allowed: true, hosts: [host]))
    XCTAssertEqual(try code.open(box, now: now).hosts, [host])
    let other = try ClientDeviceLinkCode.create(account: account, name: "iPad", signer: SoftwareDeviceSigner(), now: now)
    XCTAssertThrowsError(try other.open(box, now: now))
    XCTAssertThrowsError(try code.open(box, now: now.addingTimeInterval(301)))
    let manager = DeviceLinkHost(hostId: host.hostId, inputKey: macKey, canLinkDevices: true)
    let escalation = try code.seal(DeviceLinkBundle(candidate: code.candidate, allowed: true, hosts: [manager]))
    XCTAssertThrowsError(try code.open(escalation, now: now))
    let duplicate = try code.seal(DeviceLinkBundle(candidate: code.candidate, allowed: true, hosts: [host, host]))
    XCTAssertThrowsError(try code.open(duplicate, now: now))
  }

  func testMacReceiptAuthenticatesTheExactClaimBeforeAnInputKeyCanBeConfirmed() throws {
    let account = UUID(), host = UUID(), now = Date()
    let capability = P256.Signing.PrivateKey()
    let object: [String: Any] = ["version": 1, "id": UUID().uuidString.lowercased(),
      "accountId": account.uuidString.lowercased(), "hostId": host.uuidString.lowercased(),
      "expiresAt": UInt64(now.timeIntervalSince1970 * 1000) + 300_000,
      "inputKey": P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString(),
      "secret": capability.rawRepresentation.base64EncodedString()]
    let text = "AXO-LINK-1:" + (try JSONSerialization.data(withJSONObject: object)).base64EncodedString()
    let code = try HostDeviceLinkCode.scan(text, account: account, now: now)
    let claim = try code.claim(using: SoftwareDeviceSigner(), name: "Phone")
    let message = Data("axo-link-phone-receipt/v1\n\(code.claimMessage(key: claim.key, name: claim.name).base64EncodedString())".utf8)
    let receipt = DevicePairingReceipt(paired: true, signature: try capability.signature(for: message).rawRepresentation.base64EncodedString())
    XCTAssertNoThrow(try code.verify(receipt, claim: claim, now: now))
    let other = try code.claim(using: SoftwareDeviceSigner(), name: "Phone")
    XCTAssertThrowsError(try code.verify(receipt, claim: other, now: now))
    let forged = DevicePairingReceipt(paired: true, signature: try P256.Signing.PrivateKey().signature(for: message).rawRepresentation.base64EncodedString())
    XCTAssertThrowsError(try code.verify(forged, claim: claim, now: now))
    let answerBytes = SoftwareDeviceSigner.message(requestID: code.id, action: .accept, sealed: nil)
    XCTAssertNotEqual(answerBytes, code.claimMessage(key: claim.key, name: claim.name))
  }
}
