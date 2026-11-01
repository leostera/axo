import ServiceManagement
import XCTest

@testable import AxoDaemonManager

final class RegistrationDecisionTests: XCTestCase {
  func testFirstRunRequestsRegistrationOnce() {
    XCTAssertEqual(
      RegistrationDecision.resolve(
        serviceStatus: .notRegistered,
        registrationIntentRecorded: false,
        definitionBundled: true
      ),
      .registerOnce
    )
  }

  func testPreviouslyRequestedServiceIsNotSilentlyReRegistered() {
    XCTAssertEqual(
      RegistrationDecision.resolve(
        serviceStatus: .notRegistered,
        registrationIntentRecorded: true,
        definitionBundled: true
      ),
      .userDisabled
    )
  }

  func testApprovalAndEnabledStatusesRemainDistinct() {
    XCTAssertEqual(
      RegistrationDecision.resolve(
        serviceStatus: .requiresApproval,
        registrationIntentRecorded: true,
        definitionBundled: true
      ),
      .approvalRequired
    )
    XCTAssertEqual(
      RegistrationDecision.resolve(
        serviceStatus: .enabled,
        registrationIntentRecorded: false,
        definitionBundled: true
      ),
      .alreadyEnabled
    )
  }

  /// A Mac that never ran Axo reports `.notFound` for the bundled LaunchAgent until it is registered.
  func testUnknownServiceWithBundledPlistIsRegistered() {
    XCTAssertEqual(
      RegistrationDecision.resolve(
        serviceStatus: .notFound,
        registrationIntentRecorded: false,
        definitionBundled: true
      ),
      .registerOnce
    )
  }

  func testUnknownServiceWithoutBundledPlistIsMissing() {
    XCTAssertEqual(
      RegistrationDecision.resolve(
        serviceStatus: .notFound,
        registrationIntentRecorded: false,
        definitionBundled: false
      ),
      .missingService
    )
  }
}
