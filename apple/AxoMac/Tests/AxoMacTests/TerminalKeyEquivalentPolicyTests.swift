import AppKit
import XCTest

@testable import AxoMac

@MainActor
final class TerminalKeyEquivalentPolicyTests: XCTestCase {
  func testAxoMenuTakesPrecedenceOverMatchingGhosttyBinding() {
    XCTAssertEqual(
      TerminalKeyEquivalentPolicy.route(
        appMenuHandled: true, terminalFocused: false, ghosttyBindingMatched: true),
      .axoMenu
    )
  }

  func testGhosttyBindingRunsWhenNoAxoMenuItemMatches() {
    XCTAssertEqual(
      TerminalKeyEquivalentPolicy.route(
        appMenuHandled: false, terminalFocused: true, ghosttyBindingMatched: true),
      .ghosttyBinding
    )
  }

  func testUnmatchedKeyEquivalentFallsThroughToAppKit() {
    XCTAssertEqual(
      TerminalKeyEquivalentPolicy.route(
        appMenuHandled: false, terminalFocused: true, ghosttyBindingMatched: false),
      .appKit
    )
  }

  func testUnfocusedSurfaceDoesNotClaimTerminalBindings() {
    XCTAssertEqual(
      TerminalKeyEquivalentPolicy.route(
        appMenuHandled: false, terminalFocused: false, ghosttyBindingMatched: true),
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

  func testRedispatchRequiresTheSameNonAmbiguousEventTimestamp() throws {
    XCTAssertTrue(TerminalKeyEquivalentPolicy.matchesRedispatch(eventTimestamp: 1.25, previousTimestamp: 1.25))
    XCTAssertFalse(TerminalKeyEquivalentPolicy.matchesRedispatch(eventTimestamp: 1.25, previousTimestamp: 1.5))
    XCTAssertFalse(TerminalKeyEquivalentPolicy.matchesRedispatch(eventTimestamp: 1.25, previousTimestamp: nil))

    let syntheticCommandEvent = try keyEvent(".", modifiers: .command, timestamp: 0)
    XCTAssertFalse(TerminalKeyEquivalentPolicy.shouldRedispatchThroughAppKit(syntheticCommandEvent))
  }

  private func keyEvent(
    _ characters: String,
    type: NSEvent.EventType = .keyDown,
    modifiers: NSEvent.ModifierFlags,
    timestamp: TimeInterval = 1.25
  ) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: timestamp,
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
