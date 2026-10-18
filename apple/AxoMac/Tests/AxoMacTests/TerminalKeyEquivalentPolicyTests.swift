import AppKit
import XCTest

@testable import AxoMac

@MainActor
final class TerminalKeyEquivalentPolicyTests: XCTestCase {
  func testAxoMenuTakesPrecedenceOverMatchingGhosttyBinding() {
    XCTAssertEqual(
      TerminalKeyEquivalentPolicy.route(appMenuHandled: true, ghosttyBindingMatched: true),
      .axoMenu
    )
  }

  func testGhosttyBindingRunsWhenNoAxoMenuItemMatches() {
    XCTAssertEqual(
      TerminalKeyEquivalentPolicy.route(appMenuHandled: false, ghosttyBindingMatched: true),
      .ghosttyBinding
    )
  }

  func testUnmatchedKeyEquivalentFallsThroughToAppKit() {
    XCTAssertEqual(
      TerminalKeyEquivalentPolicy.route(appMenuHandled: false, ghosttyBindingMatched: false),
      .appKit
    )
  }

  func testControlReturnIsNormalizedButPlainReturnIsNot() throws {
    let controlReturn = try keyEvent("\r", modifiers: .control)
    let plainReturn = try keyEvent("\r", modifiers: [])

    XCTAssertEqual(TerminalKeyEquivalentPolicy.normalizedControlEquivalent(for: controlReturn), "\r")
    XCTAssertNil(TerminalKeyEquivalentPolicy.normalizedControlEquivalent(for: plainReturn))
  }

  func testControlSlashWorkaroundRequiresControlAlone() throws {
    let controlSlash = try keyEvent("/", modifiers: .control)
    let modifiedControlSlash = try keyEvent("/", modifiers: [.control, .shift])
    let commandSlash = try keyEvent("/", modifiers: [.control, .command])

    XCTAssertEqual(TerminalKeyEquivalentPolicy.normalizedControlEquivalent(for: controlSlash), "_")
    XCTAssertNil(TerminalKeyEquivalentPolicy.normalizedControlEquivalent(for: modifiedControlSlash))
    XCTAssertNil(TerminalKeyEquivalentPolicy.normalizedControlEquivalent(for: commandSlash))
  }

  func testOnlyCommandKeyUpsAreForwardedByTheLocalMonitor() throws {
    let commandKeyUp = try keyEvent("x", type: .keyUp, modifiers: .command)
    let controlKeyUp = try keyEvent("x", type: .keyUp, modifiers: .control)
    let commandKeyDown = try keyEvent("x", type: .keyDown, modifiers: .command)

    XCTAssertTrue(TerminalKeyEquivalentPolicy.shouldForwardCommandKeyUp(commandKeyUp))
    XCTAssertFalse(TerminalKeyEquivalentPolicy.shouldForwardCommandKeyUp(controlKeyUp))
    XCTAssertFalse(TerminalKeyEquivalentPolicy.shouldForwardCommandKeyUp(commandKeyDown))
  }

  func testRedispatchRequiresTheSameNonAmbiguousEventTimestamp() {
    XCTAssertTrue(TerminalKeyEquivalentPolicy.matchesRedispatch(eventTimestamp: 1.25, previousTimestamp: 1.25))
    XCTAssertFalse(TerminalKeyEquivalentPolicy.matchesRedispatch(eventTimestamp: 1.25, previousTimestamp: 1.5))
    XCTAssertFalse(TerminalKeyEquivalentPolicy.matchesRedispatch(eventTimestamp: 1.25, previousTimestamp: nil))
  }

  private func keyEvent(
    _ characters: String,
    type: NSEvent.EventType = .keyDown,
    modifiers: NSEvent.ModifierFlags
  ) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 1.25,
        windowNumber: 1,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
      )
    )
  }
}
