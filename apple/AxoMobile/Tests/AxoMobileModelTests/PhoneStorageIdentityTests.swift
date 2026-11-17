import AxoMobileModel
import XCTest

final class PhoneStorageIdentityTests: XCTestCase {
  func testExistingUpdateKeepsItsExactTokenService() {
    XCTAssertEqual(
      PhoneStorageIdentity(bundleIdentifier: "dev.leostera.axo.phone")?.tokenService,
      "dev.leostera.axo.phone.access")
  }

  func testCanonicalAppHasSeparateStorageNotAnImplicitMigration() {
    XCTAssertEqual(
      PhoneStorageIdentity(bundleIdentifier: "dev.leostera.axo")?.tokenService,
      "dev.leostera.axo.access")
    XCTAssertNotEqual(PhoneStorageIdentity.canonical.tokenService, PhoneStorageIdentity.existingPhone.tokenService)
  }

  func testUnknownOrMissingIdentityCannotSelectCredentialStorage() {
    XCTAssertNil(PhoneStorageIdentity(bundleIdentifier: nil))
    XCTAssertNil(PhoneStorageIdentity(bundleIdentifier: ""))
    XCTAssertNil(PhoneStorageIdentity(bundleIdentifier: "dev.leostera.axo.watch"))
    XCTAssertNil(PhoneStorageIdentity(bundleIdentifier: "dev.leostera.axo.phone.other"))
  }
}
