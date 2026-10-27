import AppKit
import GhosttyKit
import SwiftUI
import XCTest

@testable import AxoMac

@MainActor
private final class ClickTargetPanes {
  var views: [String: NSView] = [:]
}

private struct ClickTargetPane: NSViewRepresentable {
  let name: String
  let panes: ClickTargetPanes

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    panes.views[name] = view
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor
final class TerminalPointerInputTests: XCTestCase {
  /// The app's content view is a flipped NSHostingView; a click on each pane of `[1 [2 3]]`
  /// must resolve to that pane, not its vertical mirror.
  func testClickLocationResolvesToTheVisiblePaneOfANestedSplit() throws {
    let panes = ClickTargetPanes()
    let hostingView = NSHostingView(
      rootView: TerminalSplitView(
        id: UUID(), direction: .right, ratio: 0.5, onRatioChange: { _ in },
        first: { ClickTargetPane(name: "1", panes: panes) },
        second: {
          TerminalSplitView(
            id: UUID(), direction: .down, ratio: 0.5, onRatioChange: { _ in },
            first: { ClickTargetPane(name: "2", panes: panes) },
            second: { ClickTargetPane(name: "3", panes: panes) })
        }))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hostingView
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    hostingView.layoutSubtreeIfNeeded()
    XCTAssertTrue(hostingView.isFlipped)

    for name in ["1", "2", "3"] {
      let pane = try XCTUnwrap(panes.views[name])
      let center = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
      XCTAssertTrue(
        TerminalMouseInput.view(at: center, in: window) === pane,
        "A click on pane \(name) should land on pane \(name).")
    }
  }

  func testSupportedNSEventButtonsMapToGhosttyButtons() {
    let expected: [ghostty_input_mouse_button_e] = [
      GHOSTTY_MOUSE_LEFT,
      GHOSTTY_MOUSE_RIGHT,
      GHOSTTY_MOUSE_MIDDLE,
      GHOSTTY_MOUSE_EIGHT,
      GHOSTTY_MOUSE_NINE,
      GHOSTTY_MOUSE_SIX,
      GHOSTTY_MOUSE_SEVEN,
      GHOSTTY_MOUSE_FOUR,
      GHOSTTY_MOUSE_FIVE,
      GHOSTTY_MOUSE_TEN,
      GHOSTTY_MOUSE_ELEVEN,
    ]

    for (number, button) in expected.enumerated() {
      XCTAssertEqual(TerminalMouseInput.button(forEventButtonNumber: number), button)
    }
    XCTAssertEqual(TerminalMouseInput.button(forEventButtonNumber: 11), GHOSTTY_MOUSE_UNKNOWN)
  }

  func testScrollFlagsPreservePrecisionAndMomentum() {
    XCTAssertEqual(
      TerminalMouseInput.scrollFlags(isPrecise: false, momentumPhase: []), 0)
    XCTAssertEqual(
      TerminalMouseInput.scrollFlags(isPrecise: true, momentumPhase: []), 1)
    XCTAssertEqual(
      TerminalMouseInput.scrollFlags(isPrecise: true, momentumPhase: .began), 3)
    XCTAssertEqual(
      TerminalMouseInput.scrollFlags(isPrecise: false, momentumPhase: .changed), 6)
    XCTAssertEqual(
      TerminalMouseInput.scrollFlags(isPrecise: true, momentumPhase: .ended), 9)
  }

  func testPreciseScrollDeltasMatchGhosttyAppMultiplier() {
    XCTAssertEqual(TerminalMouseInput.scrollDeviceMultiplier(isPrecise: true), 2.0)
    XCTAssertEqual(TerminalMouseInput.scrollDeviceMultiplier(isPrecise: false), 1.0)
  }

  func testScrollbarDocumentHeightCoversScrollbackAndViewportPadding() {
    let state = TerminalScrollbarState(total: 1_000, offset: 960, length: 40)
    XCTAssertEqual(
      TerminalScrollbarGeometry.documentHeight(for: state, cellHeight: 16, contentHeight: 650),
      16_010)
    XCTAssertEqual(
      TerminalScrollbarGeometry.documentHeight(for: nil, cellHeight: 16, contentHeight: 650), 650)
    XCTAssertEqual(
      TerminalScrollbarGeometry.documentHeight(for: state, cellHeight: 0, contentHeight: 650), 650)
  }

  func testScrollbarOriginInvertsGhosttyTopOffsetIntoAppKitBottomOrigin() {
    XCTAssertEqual(
      TerminalScrollbarGeometry.scrollOrigin(
        for: TerminalScrollbarState(total: 1_000, offset: 960, length: 40), cellHeight: 16),
      0)
    XCTAssertEqual(
      TerminalScrollbarGeometry.scrollOrigin(
        for: TerminalScrollbarState(total: 1_000, offset: 0, length: 40), cellHeight: 16),
      15_360)
    XCTAssertEqual(
      TerminalScrollbarGeometry.scrollOrigin(
        for: TerminalScrollbarState(total: 10, offset: 8, length: 40), cellHeight: 16),
      0)
  }

  func testScrollbarDragMapsBackToTopOriginRow() {
    let state = TerminalScrollbarState(total: 1_000, offset: 300, length: 40)
    let documentHeight = TerminalScrollbarGeometry.documentHeight(
      for: state, cellHeight: 16, contentHeight: 640)
    let origin = TerminalScrollbarGeometry.scrollOrigin(for: state, cellHeight: 16)
    XCTAssertEqual(
      TerminalScrollbarGeometry.row(
        documentHeight: documentHeight, visibleOriginY: origin, visibleHeight: 640,
        cellHeight: 16),
      300)
    XCTAssertEqual(
      TerminalScrollbarGeometry.row(
        documentHeight: documentHeight, visibleOriginY: documentHeight, visibleHeight: 640,
        cellHeight: 16),
      0)
    XCTAssertNil(
      TerminalScrollbarGeometry.row(
        documentHeight: 640, visibleOriginY: 0, visibleHeight: 640, cellHeight: 0))
  }

  func testScrollbarConfigFollowsGhosttyRules() {
    XCTAssertTrue(TerminalScrollbarConfig.showsScrollbar(configValue: "system"))
    XCTAssertTrue(TerminalScrollbarConfig.showsScrollbar(configValue: nil))
    XCTAssertFalse(TerminalScrollbarConfig.showsScrollbar(configValue: "never"))
    XCTAssertTrue(TerminalScrollbarConfig.isDarkBackground(red: 0x28, green: 0x2c, blue: 0x34))
    XCTAssertFalse(TerminalScrollbarConfig.isDarkBackground(red: 0xff, green: 0xff, blue: 0xff))
  }

  func testScrollbarOverlayOnlyHitTestsItsScroller() {
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    let overlay = TerminalScrollbarOverlayView(frame: host.bounds)
    host.addSubview(overlay)
    overlay.update(
      state: TerminalScrollbarState(total: 200, offset: 100, length: 20), cellHeight: 15)
    overlay.layoutSubtreeIfNeeded()
    overlay.tile()

    XCTAssertNil(overlay.hitTest(CGPoint(x: 100, y: 150)), "terminal area must reach the surface")
    let scroller = try? XCTUnwrap(overlay.verticalScroller)
    if let scroller {
      let point = host.convert(CGPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), from: scroller)
      XCTAssertNotNil(overlay.hitTest(point))
    }
  }

  func testOnlyActiveWindowFocusTransfersConsumeLeftClick() {
    XCTAssertTrue(
      TerminalMouseInput.shouldConsumeFocusOnlyClick(
        surfaceIsFirstResponder: false,
        applicationIsActive: true,
        windowIsKey: true
      ))
    XCTAssertFalse(
      TerminalMouseInput.shouldConsumeFocusOnlyClick(
        surfaceIsFirstResponder: true,
        applicationIsActive: true,
        windowIsKey: true
      ))
    XCTAssertFalse(
      TerminalMouseInput.shouldConsumeFocusOnlyClick(
        surfaceIsFirstResponder: false,
        applicationIsActive: false,
        windowIsKey: true
      ))
    XCTAssertFalse(
      TerminalMouseInput.shouldConsumeFocusOnlyClick(
        surfaceIsFirstResponder: false,
        applicationIsActive: true,
        windowIsKey: false
      ))
  }

  func testContextMenuOffersOnlyAxoOwnedTerminalActions() {
    XCTAssertEqual(
      TerminalContextMenuPolicy.items(hasSelection: false),
      [.paste, .separator, .splitRight, .splitDown, .separator, .closePane])
    XCTAssertEqual(
      TerminalContextMenuPolicy.items(hasSelection: true),
      [.copy, .paste, .separator, .splitRight, .splitDown, .separator, .closePane])
  }

  func testServicesOnlyAdvertiseBoundedPlainTextTransfers() {
    let plainText = NSPasteboard.PasteboardType.string
    let utf8PlainText = NSPasteboard.PasteboardType("public.utf8-plain-text")
    let html = NSPasteboard.PasteboardType.html

    XCTAssertTrue(TerminalServicesPolicy.canServe(
      sendType: plainText, returnType: utf8PlainText, hasSelection: true))
    XCTAssertFalse(TerminalServicesPolicy.canServe(
      sendType: plainText, returnType: nil, hasSelection: false))
    XCTAssertFalse(TerminalServicesPolicy.canServe(
      sendType: nil, returnType: html, hasSelection: true))
    XCTAssertTrue(TerminalServicesPolicy.canServe(
      sendType: nil, returnType: nil, hasSelection: false))
  }

  func testDroppedScreenshotThumbnailsAreStagedWhereOtherProcessesCanReadThem() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-drop-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let thumbnail = root.appendingPathComponent(
      "TemporaryItems/NSIRD_screencaptureui_test/Screenshot 1.png")
    try FileManager.default.createDirectory(
      at: thumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("png".utf8).write(to: thumbnail)
    let projectFile = root.appendingPathComponent("project/main.swift")
    let staging = root.appendingPathComponent("staging", isDirectory: true)

    let staged = TerminalDropInput.staged([thumbnail, projectFile], in: staging)

    XCTAssertEqual(staged[1], projectFile, "other files keep their real path")
    XCTAssertEqual(staged[0].lastPathComponent, "Screenshot 1.png")
    XCTAssertTrue(staged[0].path.hasPrefix(staging.path))
    XCTAssertEqual(try Data(contentsOf: staged[0]), Data("png".utf8))
    XCTAssertTrue(TerminalDropInput.needsStaging(thumbnail))
    XCTAssertFalse(TerminalDropInput.needsStaging(projectFile))

    let missing = root.appendingPathComponent("TemporaryItems/gone.png")
    XCTAssertEqual(
      TerminalDropInput.staged([missing], in: staging), [missing],
      "a file that cannot be copied keeps its original path")
  }

  func testDroppedTextAndFileURLsUseOnlySupportedContent() {
    XCTAssertTrue(TerminalDropInput.accepts([.string]))
    XCTAssertTrue(TerminalDropInput.accepts([.fileURL]))
    XCTAssertFalse(TerminalDropInput.accepts([.html]))
    XCTAssertEqual(TerminalDropInput.text(plainText: "echo hello", fileURLs: nil), "echo hello")
    XCTAssertEqual(
      TerminalDropInput.text(
        plainText: nil,
        fileURLs: [URL(fileURLWithPath: "/tmp/one"), URL(fileURLWithPath: "/tmp/two")]),
      "/tmp/one\n/tmp/two")
    XCTAssertNil(TerminalDropInput.text(plainText: nil, fileURLs: [URL(string: "https://example.com")!]))
    XCTAssertNil(TerminalDropInput.text(plainText: "", fileURLs: nil))
  }

  func testQuickLookOnlyRunsOnEnabledForceClickTransition() {
    XCTAssertTrue(
      TerminalPressurePolicy.shouldShowQuickLook(
        previousStage: 1, currentStage: 2, forceClickEnabled: true))
    XCTAssertFalse(
      TerminalPressurePolicy.shouldShowQuickLook(
        previousStage: 2, currentStage: 2, forceClickEnabled: true))
    XCTAssertFalse(
      TerminalPressurePolicy.shouldShowQuickLook(
        previousStage: 1, currentStage: 2, forceClickEnabled: false))
  }

  func testCursorShapesMapToAppKitCursorFeedback() {
    XCTAssertTrue(
      TerminalCursorPolicy.cursor(for: GHOSTTY_MOUSE_SHAPE_DEFAULT) === NSCursor.arrow)
    XCTAssertTrue(
      TerminalCursorPolicy.cursor(for: GHOSTTY_MOUSE_SHAPE_POINTER) === NSCursor.pointingHand)
    XCTAssertTrue(
      TerminalCursorPolicy.cursor(for: GHOSTTY_MOUSE_SHAPE_TEXT) === NSCursor.iBeam)
    XCTAssertTrue(
      TerminalCursorPolicy.cursor(for: GHOSTTY_MOUSE_SHAPE_GRABBING) === NSCursor.closedHand)
    XCTAssertNil(TerminalCursorPolicy.cursor(for: GHOSTTY_MOUSE_SHAPE_CELL))
    XCTAssertNil(TerminalCursorPolicy.cursor(for: GHOSTTY_MOUSE_SHAPE_NO_DROP))
  }
}
