import ServiceManagement
import XCTest

@testable import AxoDaemonManager

final class RegistrationDecisionTests: XCTestCase {
  func testFirstRunRequestsRegistrationOnce() {
    XCTAssertEqual(
      RegistrationDecision.resolve(
        serviceStatus: .notRegistered,
        registrationIntentRecorded: false
      ),
      .registerOnce
    )
  }

  func testPreviouslyRequestedServiceIsNotSilentlyReRegistered() {
    XCTAssertEqual(
      RegistrationDecision.resolve(
        serviceStatus: .notRegistered,
        registrationIntentRecorded: true
      ),
      .userDisabled
    )
  }

  func testApprovalAndEnabledStatusesRemainDistinct() {
    XCTAssertEqual(
      RegistrationDecision.resolve(
        serviceStatus: .requiresApproval,
        registrationIntentRecorded: true
      ),
      .approvalRequired
    )
    XCTAssertEqual(
      RegistrationDecision.resolve(
        serviceStatus: .enabled,
        registrationIntentRecorded: false
      ),
      .alreadyEnabled
    )
  }
}
