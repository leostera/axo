import AxoMobileModel
import AxoProtocol
import CryptoKit
import Foundation
import XCTest

final class DeviceKeyTests: XCTestCase {
  private let enclaveName = "axo.deviceKey.enclave"
  private let softwareName = "axo.deviceKey.software"
  private let reference = Data("synthetic-enclave-reference-not-a-key".utf8)

  private func withDefaults(_ body: (UserDefaults, String) throws -> Void) rethrows {
    let suite = "dev.leostera.axo.tests.device-key.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults, suite)
  }

  func testNotificationRestorationNeverCreatesAMissingIdentity() throws {
    try withDefaults { defaults, suite in
      var creations = 0
      let before = defaults.persistentDomain(forName: suite)
      let enclave = PhoneDeviceKey.Enclave(restore: { _ in throw TestFailure.unavailable },
        create: { creations += 1; throw TestFailure.unavailable })
      XCTAssertThrowsError(try PhoneDeviceKey.existing(in: defaults, enclave: enclave))
      XCTAssertEqual(creations, 0)
      XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, before as NSDictionary?)
      XCTAssertNil(defaults.object(forKey: softwareName))
    }
  }

  func testUnavailableExistingEnclaveDoesNotCreateOrFallBack() throws {
    try withDefaults { defaults, _ in
      defaults.set(reference, forKey: enclaveName)
      let software = P256.Signing.PrivateKey()
      defaults.set(software.rawRepresentation, forKey: softwareName)
      XCTAssertThrowsError(try PhoneDeviceKey.stored(in: defaults, enclave: nil)) {
        XCTAssertEqual($0 as? PhoneDeviceKey.StorageError, .unavailable)
      }
      XCTAssertEqual(defaults.data(forKey: enclaveName), reference)
      XCTAssertEqual(defaults.data(forKey: softwareName), software.rawRepresentation)
    }
  }

  func testFailedEnclaveRestorationNeverInvokesCreationOrChangesDefaults() throws {
    try withDefaults { defaults, suite in
      defaults.set(reference, forKey: enclaveName)
      let before = defaults.persistentDomain(forName: suite)! as NSDictionary
      var creations = 0
      let enclave = PhoneDeviceKey.Enclave(
        restore: { _ in throw TestFailure.unavailable },
        create: { creations += 1; throw TestFailure.unavailable }
      )
      XCTAssertThrowsError(try PhoneDeviceKey.stored(in: defaults, enclave: enclave)) {
        XCTAssertEqual($0 as? PhoneDeviceKey.StorageError, .cannotRestore)
      }
      XCTAssertEqual(creations, 0)
      XCTAssertEqual(defaults.persistentDomain(forName: suite)! as NSDictionary, before)
    }
  }

  func testMalformedStoredValuesAreNotMistakenForMissingKeys() throws {
    for name in [enclaveName, softwareName] {
      for value: Any in ["not-data", Data()] {
        try withDefaults { defaults, _ in
          defaults.set(value, forKey: name)
          var creations = 0
          let enclave = PhoneDeviceKey.Enclave(
            restore: { _ in throw TestFailure.unavailable },
            create: { creations += 1; throw TestFailure.unavailable }
          )
          XCTAssertThrowsError(try PhoneDeviceKey.stored(in: defaults, enclave: enclave)) {
            XCTAssertEqual($0 as? PhoneDeviceKey.StorageError, .cannotRestore)
          }
          XCTAssertEqual(creations, 0)
        }
      }
    }
  }

  func testExistingSoftwareIdentityIsPreservedWhenEnclaveBecomesAvailable() throws {
    try withDefaults { defaults, _ in
      let key = P256.Signing.PrivateKey()
      defaults.set(key.rawRepresentation, forKey: softwareName)
      var creations = 0
      let enclave = PhoneDeviceKey.Enclave(
        restore: { _ in throw TestFailure.unavailable },
        create: { creations += 1; throw TestFailure.unavailable }
      )
      let restored = try PhoneDeviceKey.stored(in: defaults, enclave: enclave)
      XCTAssertEqual(restored.publicKey, SoftwareDeviceSigner(key: key).publicKey)
      XCTAssertNil(defaults.object(forKey: enclaveName))
      XCTAssertEqual(creations, 0)
    }
  }

  func testNewEnclaveIdentityIsCreatedOnceAndSubsequentlyRestored() throws {
    try withDefaults { defaults, _ in
      let signer = SoftwareDeviceSigner()
      var creations = 0
      var restorations = 0
      let enclave = PhoneDeviceKey.Enclave(
        restore: { data in
          XCTAssertEqual(data, self.reference)
          restorations += 1
          return signer
        },
        create: {
          creations += 1
          return .init(signer: signer, representation: self.reference)
        }
      )
      XCTAssertEqual(try PhoneDeviceKey.stored(in: defaults, enclave: enclave).publicKey, signer.publicKey)
      XCTAssertEqual(try PhoneDeviceKey.stored(in: defaults, enclave: enclave).publicKey, signer.publicKey)
      XCTAssertEqual(creations, 1)
      XCTAssertEqual(restorations, 1)
      XCTAssertEqual(defaults.data(forKey: enclaveName), reference)
      XCTAssertNil(defaults.object(forKey: softwareName))
    }
  }

  func testFailedCreationDoesNotPersistAnotherIdentity() throws {
    try withDefaults { defaults, _ in
      let enclave = PhoneDeviceKey.Enclave(
        restore: { _ in throw TestFailure.unavailable },
        create: { throw TestFailure.unavailable }
      )
      XCTAssertThrowsError(try PhoneDeviceKey.stored(in: defaults, enclave: enclave)) {
        XCTAssertEqual($0 as? PhoneDeviceKey.StorageError, .cannotCreate)
      }
      XCTAssertNil(defaults.object(forKey: enclaveName))
      XCTAssertNil(defaults.object(forKey: softwareName))
    }
  }

  func testMigrationRestoresAndProvesTheExactExistingPublicKeyWithoutCreation() throws {
    let signer = SoftwareDeviceSigner()
    var creations = 0
    let enclave = PhoneDeviceKey.Enclave(
      restore: { data in XCTAssertEqual(data, self.reference); return signer },
      create: { creations += 1; throw TestFailure.unavailable }
    )
    let restored = try PhoneDeviceKey.restoreForMigration(reference, expectedPublicKey: signer.publicKey, enclave: enclave)
    XCTAssertEqual(restored.publicKey, signer.publicKey)
    XCTAssertEqual(creations, 0)
    XCTAssertThrowsError(try PhoneDeviceKey.restoreForMigration(reference, expectedPublicKey: SoftwareDeviceSigner().publicKey, enclave: enclave)) {
      XCTAssertEqual($0 as? PhoneDeviceKey.StorageError, .identityMismatch)
    }
    XCTAssertEqual(creations, 0)
  }

  func testMigrationRejectsAReportedPublicKeyWithoutSigningPossession() {
    let expected = SoftwareDeviceSigner()
    let liar = LyingSigner(publicKey: expected.publicKey, actual: SoftwareDeviceSigner())
    let enclave = PhoneDeviceKey.Enclave(
      restore: { _ in liar },
      create: { XCTFail("Migration must never create an identity"); throw TestFailure.unavailable }
    )
    XCTAssertThrowsError(try PhoneDeviceKey.restoreForMigration(reference, expectedPublicKey: expected.publicKey, enclave: enclave)) {
      XCTAssertEqual($0 as? PhoneDeviceKey.StorageError, .identityMismatch)
    }
  }

  func testMigrationRejectsMissingOversizedOrUnavailableReferences() {
    for data in [Data(), Data(repeating: 0, count: 16_385)] {
      XCTAssertThrowsError(try PhoneDeviceKey.restoreForMigration(data, expectedPublicKey: "", enclave: nil)) {
        XCTAssertEqual($0 as? PhoneDeviceKey.StorageError, .missingMigrationKey)
      }
    }
    XCTAssertThrowsError(try PhoneDeviceKey.restoreForMigration(reference, expectedPublicKey: "", enclave: nil)) {
      XCTAssertEqual($0 as? PhoneDeviceKey.StorageError, .unavailable)
    }
  }
}

private enum TestFailure: Error { case unavailable }
private struct LyingSigner: DeviceSigner {
  let publicKey: String
  let actual: SoftwareDeviceSigner
  func sign(_ message: Data) throws -> Data { try actual.sign(message) }
}
