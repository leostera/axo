import UIKit
import XCTest

final class AxoMobileSidebarIndicatorTests: XCTestCase {
  private struct RowPixels: Equatable {
    let width: Int
    let height: Int
    let bytes: Data
  }

  @MainActor
  private func pixels(_ row: XCUIElement) throws -> RowPixels {
    let image = try XCTUnwrap(UIImage(data: row.screenshot().pngRepresentation)?.cgImage)
    let bytes = try XCTUnwrap(image.dataProvider?.data)
    return RowPixels(width: image.width, height: image.height, bytes: bytes as Data)
  }

  private struct Marker {
    let bounds: CGRect
    let color: [UInt8]
  }

  @MainActor
  private func marker(_ row: XCUIElement) throws -> Marker {
    let image = try XCTUnwrap(UIImage(data: row.screenshot().pngRepresentation)?.cgImage)
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    var bounds = CGRect.null
    var color: [UInt8] = []
    var chroma = -1
    for y in 0..<image.height {
      for x in 0..<image.width {
        let index = (y * image.width + x) * 4
        let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
        guard r > g + 40, g > b + 35, r > b + 100 else { continue }
        bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
        if r - b > chroma {
          chroma = r - b
          color = [bytes[index], bytes[index + 1], bytes[index + 2]]
        }
      }
    }
    XCTAssertFalse(bounds.isNull, "The working row has an orange indicator")
    return Marker(bounds: bounds, color: color)
  }

  @MainActor
  func testWorkingIndicatorIsStaticAndStaysWithItsConversationAfterPinningAnotherRow() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_MENU": "1"]
    app.launch()
    let working = app.buttons["Ship the remote Workbench"]
    XCTAssertTrue(working.waitForExistence(timeout: 15))
    XCTAssertTrue((working.value as? String)?.contains("Working") == true)
    let initial = try pixels(working)
    let originalMarker = try marker(working)
    Snapshots.save(working.screenshot().pngRepresentation, named: "sidebar-working-indicator-before")
    // The old phase animator changed the marker's opacity indefinitely, including while rows moved.
    Thread.sleep(forTimeInterval: 0.45)
    XCTAssertEqual(try pixels(working), initial, "An unchanged status indicator must not keep animating")

    let originalY = working.frame.minY
    app.buttons["Plan the week"].press(forDuration: 0.8)
    let pin = app.buttons["Pin to the top"]
    XCTAssertTrue(pin.waitForExistence(timeout: 5))
    pin.tapWhereItIs()
    let moved = NSPredicate { _, _ in working.frame.minY > originalY + 10 }
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: app)], timeout: 5), .completed)
    XCTAssertTrue((working.value as? String)?.contains("Working") == true)
    XCTAssertFalse((app.buttons["Plan the week"].value as? String)?.contains("Working") == true)
    Snapshots.save(working.screenshot().pngRepresentation, named: "sidebar-working-indicator-after-pin")
    let movedMarker = try marker(working)
    // Repositioning a row can change text antialiasing by a pixel; compare the actual indicator.
    XCTAssertEqual(movedMarker.bounds.midX, originalMarker.bounds.midX, accuracy: 1)
    XCTAssertEqual(movedMarker.bounds.midY, originalMarker.bounds.midY, accuracy: 1)
    XCTAssertEqual(movedMarker.bounds.width, originalMarker.bounds.width, accuracy: 1)
    XCTAssertEqual(movedMarker.bounds.height, originalMarker.bounds.height, accuracy: 1)
    XCTAssertEqual(movedMarker.color, originalMarker.color, "The row keeps the same static marker")
  }
}
