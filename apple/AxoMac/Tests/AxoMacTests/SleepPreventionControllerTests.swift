import Foundation
import XCTest

@testable import AxoMac

@MainActor
final class SleepPreventionControllerTests: XCTestCase {
  func testPreferenceControlsOneSystemSleepActivity() throws {
    let suiteName = "axo-sleep-prevention-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var activityStarts = 0
    var activityEnds = 0
    let controller = SleepPreventionController(
      defaults: defaults,
      beginActivity: {
        activityStarts += 1
        return NSObject()
      },
      endActivity: { _ in activityEnds += 1 }
    )

    XCTAssertFalse(controller.isEnabled)
    XCTAssertEqual(activityStarts, 0)
    XCTAssertEqual(activityEnds, 0)

    controller.setEnabled(true)
    controller.setEnabled(true)
    XCTAssertTrue(controller.isEnabled)
    XCTAssertTrue(defaults.bool(forKey: SleepPreventionController.preferenceKey))
    XCTAssertEqual(activityStarts, 1)

    controller.setEnabled(false)
    XCTAssertFalse(controller.isEnabled)
    XCTAssertFalse(defaults.bool(forKey: SleepPreventionController.preferenceKey))
    XCTAssertEqual(activityEnds, 1)
  }

  func testSavedPreferenceStartsActivityOnInitialization() throws {
    let suiteName = "axo-sleep-prevention-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: SleepPreventionController.preferenceKey)

    var activityStarts = 0
    let controller = SleepPreventionController(
      defaults: defaults,
      beginActivity: {
        activityStarts += 1
        return NSObject()
      },
      endActivity: { _ in }
    )

    XCTAssertTrue(controller.isEnabled)
    XCTAssertEqual(activityStarts, 1)
    controller.setEnabled(false)
  }
}
