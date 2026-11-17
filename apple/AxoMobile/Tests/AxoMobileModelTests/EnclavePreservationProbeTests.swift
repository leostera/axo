import AxoMobileModel
import AxoProtocol
import Foundation
import XCTest

final class EnclavePreservationProbeTests: XCTestCase {
  typealias Probe = EnclavePreservationProbe
  private let reference = Data("synthetic-opaque-reference-never-real-key-material".utf8)
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let transferID = UUID()

  private func withDefaults(_ body: (UserDefaults, UserDefaults) throws -> Void) rethrows {
    let sourceName = "dev.leostera.axo.tests.probe-source.\(UUID())"
    let targetName = "dev.leostera.axo.tests.probe-target.\(UUID())"
    let source = UserDefaults(suiteName: sourceName)!
    let target = UserDefaults(suiteName: targetName)!
    defer {
      source.removePersistentDomain(forName: sourceName)
      target.removePersistentDomain(forName: targetName)
    }
    try body(source, target)
  }

  func testBothRolesProveTheSameKeyWithoutCreatingOrInstallingAnIdentity() throws {
    for role in [Probe.Role.mobile, .watch] {
      try withDefaults { source, target in
        let signer = SoftwareDeviceSigner()
        var creations = 0
        let enclave = PhoneDeviceKey.Enclave(restore: { data in
          XCTAssertEqual(data, self.reference)
          return signer
        }, create: { creations += 1; throw Probe.Failure.unavailable })
        source.set(reference, forKey: "axo.deviceKey.enclave")
        source.set("keep", forKey: "unrelated-preference")
        let store = ProbeStore()
        XCTAssertEqual(try Probe.prepare(role: role, bundleID: role.sourceBundleID,
          defaults: source, store: store, now: now, transferID: transferID, enclave: enclave), .prepared)
        XCTAssertEqual(try Probe.verify(role: role, bundleID: role.destinationBundleID,
          defaults: target, store: store, now: now, expectedTransferID: transferID, enclave: enclave), .verified)
        XCTAssertEqual(creations, 0)
        XCTAssertNil(target.object(forKey: "axo.deviceKey.enclave"))
        XCTAssertNil(target.object(forKey: "axo.deviceKey.software"))
        XCTAssertEqual(source.data(forKey: "axo.deviceKey.enclave"), reference)
        XCTAssertEqual(source.string(forKey: "unrelated-preference"), "keep")
      }
    }
  }

  func testMissingIdentityIsExplicitNotAClaimOfEnclavePreservation() throws {
    try withDefaults { source, target in
      let store = ProbeStore()
      XCTAssertEqual(try Probe.prepare(role: .mobile, bundleID: Probe.Role.mobile.sourceBundleID,
        defaults: source, store: store, now: now, transferID: transferID, enclave: nil), .noExistingKey)
      XCTAssertEqual(try Probe.verify(role: .mobile, bundleID: Probe.Role.mobile.destinationBundleID,
        defaults: target, store: store, now: now, expectedTransferID: transferID, enclave: nil), .noExistingKey)
      XCTAssertNil(source.object(forKey: "axo.deviceKey.enclave"))
      XCTAssertNil(target.object(forKey: "axo.deviceKey.enclave"))
    }
  }

  func testSoftwareAndUnavailableOrMalformedExistingKeysNeverBecomeAbsence() throws {
    for value: Any in [reference, "bad-type", Data()] {
      try withDefaults { source, _ in
        source.set(value, forKey: "axo.deviceKey.enclave")
        let store = ProbeStore()
        XCTAssertThrowsError(try Probe.prepare(role: .mobile, bundleID: Probe.Role.mobile.sourceBundleID,
          defaults: source, store: store, now: now, transferID: transferID, enclave: nil))
        XCTAssertEqual(store.saves, 0)
      }
    }
    try withDefaults { source, _ in
      source.set(Data(repeating: 1, count: 32), forKey: "axo.deviceKey.software")
      let store = ProbeStore()
      XCTAssertThrowsError(try Probe.prepare(role: .watch, bundleID: Probe.Role.watch.sourceBundleID,
        defaults: source, store: store, now: now, transferID: transferID, enclave: nil)) {
        XCTAssertEqual($0 as? Probe.Failure, .unsupportedSoftwareKey)
      }
      XCTAssertEqual(store.saves, 0)
    }
  }

  func testWrongBundleOrRoleCannotUseAnotherEnvelope() throws {
    try withDefaults { source, target in
      let store = ProbeStore()
      XCTAssertThrowsError(try Probe.prepare(role: .mobile, bundleID: Probe.Role.mobile.destinationBundleID,
        defaults: source, store: store, now: now, transferID: transferID, enclave: nil))
      XCTAssertEqual(store.saves, 0)
      _ = try Probe.prepare(role: .mobile, bundleID: Probe.Role.mobile.sourceBundleID,
        defaults: source, store: store, now: now, transferID: transferID, enclave: nil)
      XCTAssertThrowsError(try Probe.verify(role: .watch, bundleID: Probe.Role.watch.destinationBundleID,
        defaults: target, store: store, now: now, expectedTransferID: transferID, enclave: nil)) {
        XCTAssertEqual($0 as? Probe.Failure, .wrongIdentity)
      }
    }
  }

  func testAnOldSharedEnvelopeCannotSatisfyANewSourceAttempt() throws {
    try withDefaults { source, target in
      let store = ProbeStore()
      _ = try Probe.prepare(role: .mobile, bundleID: Probe.Role.mobile.sourceBundleID,
        defaults: source, store: store, now: now, transferID: transferID, enclave: nil)
      for expected: UUID? in [nil, UUID()] {
        XCTAssertThrowsError(try Probe.verify(role: .mobile, bundleID: Probe.Role.mobile.destinationBundleID,
          defaults: target, store: store, now: now, expectedTransferID: expected, enclave: nil)) {
          XCTAssertEqual($0 as? Probe.Failure, .wrongIdentity)
        }
      }
    }
  }

  func testExpiredAndFutureEnvelopesFailBeforeHardwareUse() throws {
    try withDefaults { source, target in
      let store = ProbeStore()
      _ = try Probe.prepare(role: .mobile, bundleID: Probe.Role.mobile.sourceBundleID,
        defaults: source, store: store, now: now, transferID: transferID, enclave: nil)
      for instant in [now.addingTimeInterval(86_401), now.addingTimeInterval(-31)] {
        XCTAssertThrowsError(try Probe.verify(role: .mobile, bundleID: Probe.Role.mobile.destinationBundleID,
          defaults: target, store: store, now: instant, expectedTransferID: transferID, enclave: nil)) {
          XCTAssertEqual($0 as? Probe.Failure, .expired)
        }
      }
    }
  }

  func testConflictingDestinationIsNeverOverwrittenEvenForAKeylessSource() throws {
    try withDefaults { source, target in
      let store = ProbeStore()
      _ = try Probe.prepare(role: .watch, bundleID: Probe.Role.watch.sourceBundleID,
        defaults: source, store: store, now: now, transferID: transferID, enclave: nil)
      target.set(reference, forKey: "axo.deviceKey.enclave")
      XCTAssertThrowsError(try Probe.verify(role: .watch, bundleID: Probe.Role.watch.destinationBundleID,
        defaults: target, store: store, now: now, expectedTransferID: transferID, enclave: nil)) {
        XCTAssertEqual($0 as? Probe.Failure, .conflictingDestination)
      }
      XCTAssertEqual(target.data(forKey: "axo.deviceKey.enclave"), reference)
    }
  }

  func testMalformedOversizedAndUnknownFieldsAreRejected() throws {
    try withDefaults { source, target in
      let store = ProbeStore()
      _ = try Probe.prepare(role: .mobile, bundleID: Probe.Role.mobile.sourceBundleID,
        defaults: source, store: store, now: now, transferID: transferID, enclave: nil)
      var fields = try JSONSerialization.jsonObject(with: store.bytes!) as! [String: Any]
      fields["unexpected"] = "not-allowed"
      let unknown = try JSONSerialization.data(withJSONObject: fields)
      for bytes in [Data(), Data("null".utf8), Data("{".utf8), Data(repeating: 0, count: Probe.maximumBytes + 1), unknown] {
        store.bytes = bytes
        XCTAssertThrowsError(try Probe.verify(role: .mobile, bundleID: Probe.Role.mobile.destinationBundleID,
          defaults: target, store: store, now: now, expectedTransferID: transferID, enclave: nil)) {
          XCTAssertEqual($0 as? Probe.Failure, .malformed)
        }
      }
    }
  }

  func testAnyRequestedDestinationStaysGatedIncludingInvalidConfiguration() {
    for role in [Probe.Role.mobile, .watch] {
      XCTAssertTrue(EnclaveProbeRuntime.requestsDestinationGate(role: role, bundleID: role.destinationBundleID, requested: true))
      XCTAssertTrue(EnclaveProbeRuntime.requestsDestinationGate(role: role, bundleID: nil, requested: true))
      XCTAssertFalse(EnclaveProbeRuntime.requestsDestinationGate(role: role, bundleID: role.sourceBundleID, requested: true))
      XCTAssertFalse(EnclaveProbeRuntime.requestsDestinationGate(role: role, bundleID: role.destinationBundleID, requested: false))
    }
  }

  func testReportContainsOnlyFixedNonSecretFields() throws {
    let report = EnclaveProbeRuntime.Report(runID: UUID(), role: .mobile,
      bundleID: Probe.Role.mobile.destinationBundleID, status: .verified)
    let data = try JSONEncoder().encode(report)
    let fields = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertEqual(Set(fields.keys), ["schema", "runID", "role", "bundleID", "status"])
    XCTAssertEqual(fields["status"] as? String, "verified")
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(String(decoding: reference, as: UTF8.self)))
  }

  func testSharedGroupScopeRequiresTheExactSuffixAndARealPrefixShape() throws {
    _ = try EnclaveProbeKeychain(accessGroup: "OTHERPRE01.dev.leostera.axo.migration")
    for group in ["", "dev.leostera.axo.migration", "OTHERPRE01.*", "OTHERPRE01.dev.leostera.axo.migration\n",
                  "OTHERPRE01.dev.leostera.axo.other", "otherpre01.dev.leostera.axo.migration"] {
      XCTAssertThrowsError(try EnclaveProbeKeychain(accessGroup: group))
    }
  }
}

/// Intentionally ignores the lookup role so tests prove that the envelope binds its own role.
private final class ProbeStore: EnclavePreservationProbe.Storing {
  var bytes: Data?
  var saves = 0
  func load(for role: EnclavePreservationProbe.Role) throws -> Data? { bytes }
  func save(_ data: Data, for role: EnclavePreservationProbe.Role) throws { bytes = data; saves += 1 }
}
