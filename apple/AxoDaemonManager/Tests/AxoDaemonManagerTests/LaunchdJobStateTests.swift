import XCTest

@testable import AxoDaemonManager

final class LaunchdJobStateTests: XCTestCase {
  func testAJobThatCannotSpawnIsFailingToRun() {
    // axod after an install deleted the bundle it was registered from.
    let state = LaunchdJobState.parse(
      """
      gui/501/dev.leostera.axo.axod = {
      \tactive count = 0
      \tstate = spawn scheduled
      \truns = 31
      \tlast exit code = 78: EX_CONFIG
      \tresource coalition = {
      \t\tstate = active
      \t}
      }
      """)
    XCTAssertEqual(state, LaunchdJobState(isLoaded: true, isRunning: false, lastExitCode: 78))
    XCTAssertTrue(state.isFailingToRun)
  }

  func testARunningJobIsNotFailing() {
    let state = LaunchdJobState.parse(
      """
      gui/501/dev.leostera.axo.axod = {
      \tstate = running
      \tpid = 21975
      \tlast exit code = 1
      }
      """)
    XCTAssertTrue(state.isRunning)
    XCTAssertFalse(state.isFailingToRun)
  }

  func testAJobThatQuitCleanlyIsNotFailing() {
    // Axo after Quit Axo: loaded, not running, exited 0.
    let state = LaunchdJobState.parse(
      """
      gui/501/dev.leostera.axo.app = {
      \tstate = not running
      \tlast exit code = 0
      }
      """)
    XCTAssertFalse(state.isFailingToRun)
  }

  func testANestedPidIsNotTheJobs() {
    let state = LaunchdJobState.parse(
      """
      gui/501/dev.leostera.axo.axod = {
      \tstate = spawn scheduled
      \tlast exit code = 78: EX_CONFIG
      \tsomething = {
      \t\tpid = 12
      \t}
      }
      """)
    XCTAssertFalse(state.isRunning)
  }

  func testAJobThatIsNotLoadedIsNotFailing() {
    XCTAssertEqual(LaunchdJobState.parse(nil), LaunchdJobState(isLoaded: false, isRunning: false))
    XCTAssertFalse(LaunchdJobState.parse(nil).isFailingToRun)
  }
}
