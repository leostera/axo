import AppKit
import GhosttyKit
import XCTest

@testable import AxoMac

@MainActor
final class TerminalPointerInputTests: XCTestCase {
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
