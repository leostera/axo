import Foundation
import XCTest

@testable import AxoPhoneModel

final class PlainTerminalTextSpeedTests: XCTestCase {
  /// A full-screen agent redraws its screen over and over: coloured, cursor-moving, long lines.
  private func redraw() -> Data {
    var screen = "\u{1B}[H"
    for row in 0..<40 {
      screen += "\u{1B}[\(row + 1);1H\u{1B}[38;5;244m"
      screen += String(repeating: "│ some agent output that fills the row ", count: 3) + "\u{1B}[0m\r\n"
    }
    return Data(screen.utf8)
  }

  func testReadingAFullScreenRedrawStormTakesWellUnderAFrameEach() {
    var text = PlainTerminalText()
    let chunk = redraw()
    let start = Date()
    for _ in 0..<200 { text.append(chunk) }
    let perChunk = Date().timeIntervalSince(start) / 200
    print("per chunk of \(chunk.count) bytes: \(perChunk * 1000) ms")
    XCTAssertLessThan(perChunk, 0.002, "the phone reads every chunk on the main thread")
  }
}
