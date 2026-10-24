import AxoDaemonManager
import XCTest

@testable import AxoMac

final class PreferenceKeyTests: XCTestCase {
  func testAppAndDaemonPreferenceKeysAreUnique() {
    let keys = AxoPreferenceKey.all + DaemonPreferenceKey.all
    XCTAssertEqual(Set(keys).count, keys.count)
  }
}
