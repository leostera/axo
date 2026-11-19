import AppKit
import XCTest
@testable import AxoMac

final class PermissionDragTileTests: XCTestCase {
  @MainActor
  func testFriendlyPreviewStillDragsTheExactDaemonNotTheApplication() {
    let helper = URL(fileURLWithPath: "/Applications/Axo.app/Contents/Helpers/axod")
    let tile = PermissionDragTile(executable: helper)
    let item = tile.fileDragItem()
    XCTAssertEqual(item.item as? NSURL, helper as NSURL)
    XCTAssertNotEqual(item.item as? NSURL, URL(fileURLWithPath: "/Applications/Axo.app") as NSURL)
    XCTAssertEqual(item.draggingFrame, tile.bounds)
  }
}
