import Darwin
import XCTest

@testable import AxoMac

final class TerminalPTYSizeTests: XCTestCase {
  func testEmptyGridIsNotReported() {
    XCTAssertNil(TerminalGridSize(columns: 0, rows: 40, widthPixels: 10, heightPixels: 10))
    XCTAssertNil(TerminalGridSize(columns: 120, rows: 0, widthPixels: 10, heightPixels: 10))
  }

  func testOversizedDimensionsClamp() throws {
    let grid = try XCTUnwrap(
      TerminalGridSize(columns: 70_000, rows: 40, widthPixels: 100_000, heightPixels: 800))
    XCTAssertEqual(grid.columns, UInt16.max)
    XCTAssertEqual(grid.widthPixels, UInt16.max)
  }

  func testCorrectsAStalePTYAndLeavesACorrectOneAlone() throws {
    var master: Int32 = -1
    var slave: Int32 = -1
    var stale = winsize(ws_row: 17, ws_col: 52, ws_xpixel: 0, ws_ypixel: 0)
    XCTAssertEqual(openpty(&master, &slave, nil, nil, &stale), 0)
    defer {
      close(master)
      close(slave)
    }
    let reporter = try XCTUnwrap(TerminalPTYSizeReporter(ptyDescriptor: master, shellID: 1))
    let grid = try XCTUnwrap(
      TerminalGridSize(columns: 240, rows: 70, widthPixels: 3840, heightPixels: 2240))

    XCTAssertTrue(reporter.report(grid))
    var current = winsize()
    XCTAssertEqual(ioctl(slave, TIOCGWINSZ, &current), 0)
    XCTAssertEqual(TerminalGridSize(current), grid)

    XCTAssertFalse(reporter.report(grid), "an unchanged size must not be re-sent")
  }

  func testReporterOwnsItsDescriptor() throws {
    var master: Int32 = -1
    var slave: Int32 = -1
    XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
    defer { close(slave) }
    let reporter = try XCTUnwrap(TerminalPTYSizeReporter(ptyDescriptor: master, shellID: 1))
    close(master)
    let grid = try XCTUnwrap(TerminalGridSize(columns: 100, rows: 30, widthPixels: 0, heightPixels: 0))
    XCTAssertTrue(reporter.report(grid), "the duplicate outlives the caller's descriptor")
  }
}
