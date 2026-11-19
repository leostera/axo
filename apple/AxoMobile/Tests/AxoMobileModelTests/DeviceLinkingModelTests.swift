import AxoClient
import AxoProtocol
import CryptoKit
import Foundation
import XCTest
@testable import AxoMobileModel

private actor LinkService: DeviceLinkingClient {
  let code: HostDeviceLinkCode
  let capability: P256.Signing.PrivateKey
  var grants: [DeviceLinkGrant] = []
  var boxes: [String: String] = [:]
  var forgeReceipt = false

  init(code: HostDeviceLinkCode, capability: P256.Signing.PrivateKey) { self.code = code; self.capability = capability }
  func useForgedReceipt() { forgeReceipt = true }
  func redeemDevicePairing(_ claim: DevicePairingClaim) async throws -> DevicePairingReceipt {
    let message = Data("axo-link-phone-receipt/v1\n\(code.claimMessage(key: claim.key, name: claim.name).base64EncodedString())".utf8)
    let key = forgeReceipt ? P256.Signing.PrivateKey() : capability
    let signature = try key.signature(for: message).rawRepresentation.base64EncodedString()
    return try JSONDecoder().decode(DevicePairingReceipt.self, from: JSONSerialization.data(withJSONObject: ["paired": true, "signature": signature]))
  }
  func linkDevice(_ grant: DeviceLinkGrant) async throws { grants.append(grant) }
  func unlinkDevice(_ revocation: DeviceUnlink) async throws {}
  func deviceLinkMailbox(_ command: DeviceLinkMailboxCommand) async throws -> DeviceMailboxReceipt {
    var object: [String: Any] = ["state": "waiting"]
    switch command {
    case .create: break
    case .cancel: object = ["state": "cancelled"]
    case .complete(let id, let box): boxes[id] = box; object = ["state": "complete"]
    case .poll(let id): if let box = boxes[id] { object = ["state": "complete", "box": box] }
    }
    return try JSONDecoder().decode(DeviceMailboxReceipt.self, from: JSONSerialization.data(withJSONObject: object))
  }
}

@MainActor
final class DeviceLinkingModelTests: XCTestCase {
  private func defaults() -> UserDefaults {
    let name = "device-linking-tests-" + UUID().uuidString
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
    return UserDefaults(suiteName: name)!
  }

  private func fixture() throws -> (UUID, HostDeviceLinkCode, P256.Signing.PrivateKey, StaticSessionToken) {
    let account = UUID(), capability = P256.Signing.PrivateKey()
    let object: [String: Any] = ["version": 1, "id": UUID().uuidString.lowercased(),
      "accountId": account.uuidString.lowercased(), "hostId": UUID().uuidString.lowercased(),
      "expiresAt": UInt64(Date().timeIntervalSince1970 * 1000) + 300_000,
      "inputKey": P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString(),
      "secret": capability.rawRepresentation.base64EncodedString()]
    let code = try JSONDecoder().decode(HostDeviceLinkCode.self, from: JSONSerialization.data(withJSONObject: object))
    let token = try XCTUnwrap(SessionToken("axo1.\(account.uuidString.lowercased()).\(String(repeating: "A", count: 43))"))
    return (account, code, capability, StaticSessionToken(token))
  }

  func testScanOnHubAllowAndCandidateReceiveNeedsNoSecondFingerprintCheck() async throws {
    let (_, code, capability, tokens) = try fixture()
    let service = LinkService(code: code, capability: capability)
    let hubSigner = SoftwareDeviceSigner(), targetSigner = SoftwareDeviceSigner()
    let hubDefaults = defaults(), targetDefaults = defaults()
    let hub = DeviceLinkingModel(client: service, tokens: tokens, name: "Phone", defaults: hubDefaults, signer: { hubSigner })
    await hub.scan(try code.qrText)
    XCTAssertEqual(hub.phase, .linked)
    XCTAssertEqual(hub.linkedHosts.first?.canLinkDevices, true)
    XCTAssertTrue(InputKeyPins(defaults: hubDefaults).isConfirmed(code.inputKey))
    let target = DeviceLinkingModel(client: service, tokens: tokens, name: "iPad", defaults: targetDefaults, signer: { targetSigner })
    await target.showCode()
    let targetCode = try XCTUnwrap(target.clientCode)
    XCTAssertTrue(target.linkedHosts.isEmpty, "login and a displayed QR confer no approval authority")
    await hub.scan(try targetCode.qrText)
    XCTAssertEqual(hub.phase, .confirming("iPad"))
    await hub.decideScannedClient(allow: true)
    let grants = await service.grants
    XCTAssertEqual(grants.count, 1)
    XCTAssertEqual(grants.first?.managerKey, hubSigner.publicKey)
    XCTAssertEqual(grants.first?.key, targetSigner.publicKey)
    await target.poll()
    XCTAssertEqual(target.phase, .linked)
    XCTAssertEqual(target.linkedHosts.first?.canLinkDevices, false, "linking a responder never silently promotes another manager")
    XCTAssertTrue(InputKeyPins(defaults: targetDefaults).isConfirmed(code.inputKey))
    XCTAssertEqual(hub.linkedClients.first?.name, "iPad")
    let reopened = DeviceLinkingModel(client: service, tokens: tokens, name: "Phone", defaults: hubDefaults, signer: { hubSigner })
    await reopened.load()
    XCTAssertEqual(reopened.linkedHosts, hub.linkedHosts)
    XCTAssertEqual(reopened.linkedClients, hub.linkedClients)
  }

  func testDenialTransfersNoKeysAndCreatesNoGrant() async throws {
    let (_, code, capability, tokens) = try fixture()
    let service = LinkService(code: code, capability: capability)
    let hub = DeviceLinkingModel(client: service, tokens: tokens, name: "Phone", defaults: defaults(), signer: { SoftwareDeviceSigner(key: Self.hubKey) })
    await hub.scan(try code.qrText)
    let targetDefaults = defaults(), signer = SoftwareDeviceSigner()
    let target = DeviceLinkingModel(client: service, tokens: tokens, name: "iPad", defaults: targetDefaults, signer: { signer })
    await target.showCode()
    await hub.scan(try XCTUnwrap(target.clientCode).qrText)
    await hub.decideScannedClient(allow: false)
    await target.poll()
    XCTAssertTrue(target.linkedHosts.isEmpty)
    XCTAssertFalse(InputKeyPins(defaults: targetDefaults).isConfirmed(code.inputKey))
    let deniedGrants = await service.grants
    XCTAssertTrue(deniedGrants.isEmpty)
    guard case .failed = target.phase else { return XCTFail("denial must be explicit") }
  }

  private static let hubKey = P256.Signing.PrivateKey()

  func testAnUnverifiedServerReceiptCannotPinTheMacOrLinkThePhone() async throws {
    let (_, code, capability, tokens) = try fixture()
    let service = LinkService(code: code, capability: capability)
    await service.useForgedReceipt()
    let storage = defaults(), signer = SoftwareDeviceSigner()
    let model = DeviceLinkingModel(client: service, tokens: tokens, name: "Phone", defaults: storage, signer: { signer })
    await model.scan(try code.qrText)
    XCTAssertTrue(model.linkedHosts.isEmpty)
    XCTAssertFalse(InputKeyPins(defaults: storage).isConfirmed(code.inputKey))
    guard case .failed = model.phase else { return XCTFail("forged receipt must fail") }
  }

  func testSigningInOrScanningWithoutManagementAuthorityCannotLinkAnotherDevice() async throws {
    let (account, code, capability, tokens) = try fixture()
    let service = LinkService(code: code, capability: capability)
    let signer = SoftwareDeviceSigner()
    let untrusted = DeviceLinkingModel(client: service, tokens: tokens, name: "Phone", defaults: defaults(), signer: { signer })
    let target = try ClientDeviceLinkCode.create(account: account, name: "iPad", signer: SoftwareDeviceSigner())
    await untrusted.scan(try target.qrText)
    guard case .failed = untrusted.phase else { return XCTFail("a login is not management authority") }
    let untrustedGrants = await service.grants
    XCTAssertTrue(untrustedGrants.isEmpty)
  }
}
