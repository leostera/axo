import AxoClient
import AxoMobileModel
import AxoProtocol
import CryptoKit
import Foundation
import XCTest

final class MobileIdentityTransferTests: XCTestCase {
  typealias Transfer = MobileIdentityTransfer
  private let token = SessionToken("axo1.6b0f0e0e-2c43-4b8e-9d0a-0d8f7b2b9c11.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")!

  private func defaults() -> UserDefaults {
    let name = "axo-transfer-test-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    addTeardownBlock { defaults.removePersistentDomain(forName: name) }
    return defaults
  }

  private func enclave() -> PhoneDeviceKey.Enclave {
    let signer = SoftwareDeviceSigner()
    return PhoneDeviceKey.Enclave(restore: { bytes in
      guard bytes == Data([1, 2, 3]) else { throw Transfer.Failure.invalid }
      return signer
    }, create: { XCTFail("A transfer must never create a key"); throw Transfer.Failure.invalid })
  }

  func test_transfers_identity_token_preferences_and_host_pins_without_transport_identity() throws {
    let source = defaults(), destination = MemoryDestination(defaults: defaults()), enclave = enclave(), id = UUID()
    source.set(Data([1, 2, 3]), forKey: Transfer.enclaveKey)
    source.set("dark", forKey: "appearance")
    let hostPin = P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
    let hostKey = "axo.inputKey.\(UUID().uuidString.lowercased())"
    source.set(hostPin, forKey: hostKey)
    source.set("not-transferable", forKey: "axo.clientID")
    source.set("unrelated fixture", forKey: "private.unrelated")
    let bytes = try Transfer.export(defaults: source, token: token, transferID: id, enclave: enclave)
    let snapshot = try Transfer.parse(bytes, expectedID: id)
    XCTAssertNil(snapshot.preferences["axo.clientID"])
    XCTAssertNil(snapshot.preferences["private.unrelated"])
    let bridge = MemoryBridge(bytes: bytes, id: id)
    try Transfer.apply(snapshot: snapshot, bytes: bytes, bridge: bridge, destination: destination, enclave: enclave)
    XCTAssertEqual(destination.savedToken, token)
    XCTAssertEqual(destination.defaults.data(forKey: Transfer.enclaveKey), Data([1, 2, 3]))
    XCTAssertEqual(destination.defaults.string(forKey: hostKey), hostPin)
    XCTAssertEqual(destination.defaults.string(forKey: "appearance"), "dark")
    XCTAssertEqual(bridge.state, .consumed(id))
    XCTAssertNil(bridge.bytes)
    let receipt = try Transfer.readJournal(XCTUnwrap(destination.savedJournal))
    XCTAssertTrue(receipt.completed)
    XCTAssertNil(receipt.staged)
    XCTAssertFalse(String(decoding: destination.savedJournal!, as: UTF8.self).contains(token.value))
    XCTAssertThrowsError(try Transfer.apply(snapshot: snapshot, bytes: bytes, bridge: bridge, destination: destination, enclave: enclave))
  }

  func test_missing_identity_remains_missing_and_source_signed_out_remains_signed_out() throws {
    let id = UUID(), destination = MemoryDestination(defaults: defaults())
    let bytes = try Transfer.export(defaults: defaults(), token: nil, transferID: id, enclave: nil)
    let snapshot = try Transfer.parse(bytes, expectedID: id)
    try Transfer.apply(snapshot: snapshot, bytes: bytes, bridge: MemoryBridge(bytes: bytes, id: id), destination: destination, enclave: nil)
    XCTAssertNil(destination.savedToken)
    XCTAssertNil(destination.defaults.object(forKey: Transfer.enclaveKey))
    XCTAssertNil(destination.defaults.object(forKey: Transfer.softwareKey))
  }

  func test_failed_token_write_and_failed_completion_receipt_resume_idempotently() throws {
    for failure in [MemoryDestination.Fail.token, .completion] {
      let source = defaults(), destination = MemoryDestination(defaults: defaults()), id = UUID()
      source.set("light", forKey: "appearance")
      let bytes = try Transfer.export(defaults: source, token: token, transferID: id, enclave: nil)
      let snapshot = try Transfer.parse(bytes, expectedID: id), bridge = MemoryBridge(bytes: bytes, id: id)
      destination.failure = failure
      XCTAssertThrowsError(try Transfer.apply(snapshot: snapshot, bytes: bytes, bridge: bridge, destination: destination, enclave: nil))
      XCTAssertFalse(try Transfer.readJournal(XCTUnwrap(destination.savedJournal)).completed)
      destination.failure = nil
      try Transfer.apply(snapshot: snapshot, bytes: bytes, bridge: bridge, destination: destination, enclave: nil)
      XCTAssertTrue(try Transfer.readJournal(XCTUnwrap(destination.savedJournal)).completed)
      XCTAssertEqual(destination.savedToken, token)
      XCTAssertEqual(destination.defaults.string(forKey: "appearance"), "light")
    }
  }

  func test_source_sign_out_during_apply_never_releases_startup_gate() throws {
    let id = UUID(), destination = MemoryDestination(defaults: defaults())
    let bytes = try Transfer.export(defaults: defaults(), token: token, transferID: id, enclave: nil)
    let snapshot = try Transfer.parse(bytes, expectedID: id), bridge = MemoryBridge(bytes: bytes, id: id)
    bridge.revokeOnConsume = true
    XCTAssertThrowsError(try Transfer.apply(snapshot: snapshot, bytes: bytes, bridge: bridge, destination: destination, enclave: nil))
    XCTAssertEqual(bridge.state, .revoked(id))
    XCTAssertFalse(try Transfer.readJournal(XCTUnwrap(destination.savedJournal)).completed)
    XCTAssertThrowsError(try Transfer.apply(snapshot: snapshot, bytes: bytes, bridge: bridge, destination: destination, enclave: nil))
  }

  func test_conflicts_are_detected_before_a_journal_or_destination_write() throws {
    let id = UUID()
    let bytes = try Transfer.export(defaults: defaults(), token: token, transferID: id, enclave: nil)
    let snapshot = try Transfer.parse(bytes, expectedID: id), destination = MemoryDestination(defaults: defaults())
    destination.defaults.set(Data([42]), forKey: Transfer.enclaveKey)
    XCTAssertThrowsError(try Transfer.apply(snapshot: snapshot, bytes: bytes, bridge: MemoryBridge(bytes: bytes, id: id), destination: destination, enclave: nil))
    XCTAssertNil(destination.savedJournal)
    XCTAssertNil(destination.savedToken)
    XCTAssertEqual(destination.defaults.data(forKey: Transfer.enclaveKey), Data([42]))
  }

  func test_parser_fences_attempt_expiry_unknown_fields_and_software_state() throws {
    let source = defaults(), id = UUID(), now = Date()
    let bytes = try Transfer.export(defaults: source, token: token, transferID: id, now: now, enclave: nil)
    XCTAssertThrowsError(try Transfer.parse(bytes, expectedID: UUID(), now: now))
    XCTAssertThrowsError(try Transfer.parse(bytes, expectedID: id, now: now.addingTimeInterval(86_401)))
    var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    raw["unrecognized"] = "fixture"
    XCTAssertThrowsError(try Transfer.parse(JSONSerialization.data(withJSONObject: raw), expectedID: id, now: now))
    source.set(Data([1]), forKey: Transfer.softwareKey)
    XCTAssertThrowsError(try Transfer.export(defaults: source, token: token, transferID: id, enclave: nil))
  }
}

private final class MemoryBridge: MobileIdentityTransfer.Bridge {
  var bytes: Data?
  var state: MobileIdentityTransfer.Fence
  var revokeOnConsume = false
  init(bytes: Data, id: UUID) { self.bytes = bytes; state = .ready(id) }
  func payload() throws -> Data? { bytes }
  func fence() throws -> MobileIdentityTransfer.Fence? { state }
  func consume(_ id: UUID) throws -> Bool {
    if revokeOnConsume { state = .revoked(id); return false }
    guard state == .ready(id) else { return false }
    state = .consumed(id); return true
  }
  func discardConsumedPayload(_ id: UUID) throws { if state == .consumed(id) { bytes = nil } }
}

private final class MemoryDestination: MobileIdentityTransfer.Destination {
  enum Fail { case token, completion }
  let defaults: UserDefaults
  var savedToken: SessionToken?
  var savedJournal: Data?
  var failure: Fail?
  init(defaults: UserDefaults) { self.defaults = defaults }
  func token() throws -> SessionToken? { savedToken }
  func saveToken(_ token: SessionToken) throws {
    if failure == .token { throw MobileIdentityTransfer.Failure.unavailable }
    savedToken = token
  }
  func journal() throws -> Data? { savedJournal }
  func saveJournal(_ data: Data) throws {
    if failure == .completion, try MobileIdentityTransfer.readJournal(data).completed {
      throw MobileIdentityTransfer.Failure.unavailable
    }
    savedJournal = data
  }
}
