import AppKit
import SwiftUI
import AxoDaemonManager
import AxoProtocol
import AxoRPC
import Darwin
import GhosttyKit
import Foundation
import XCTest

@testable import AxoMac

@MainActor
final class TerminalWorkbenchE2ETests: XCTestCase {
  func testExitingOneNestedShellKeepsSiblingShellsAndLayoutUsable() async throws {
    try await withWorkbench { model, daemon in
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let firstShell = try XCTUnwrap(model.session(for: sessionID)?.shells.first)

      await model.split(.right)
      let secondShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first { $0.id != firstShell.id })
      await model.split(.down)
      let thirdShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first {
          $0.id != firstShell.id && $0.id != secondShell.id
        }
      )

      try daemon.sendExit(to: secondShell)
      try await waitUntilShellIsGone(secondShell.id, from: model)

      XCTAssertEqual(model.selectedSessionID, sessionID)
      XCTAssertEqual(model.focusedShellID, thirdShell.id)
      XCTAssertEqual(model.layout?.shellIDs, [firstShell.id, thirdShell.id])
      try daemon.assertCanRunCommand(in: firstShell)
      try daemon.assertCanRunCommand(in: thirdShell)
    }
  }

  /// Relaunching Axo reattaches to programs that keep running. A new surface's grid is
  /// libghostty's default window size until it is laid out; that must never reach the PTY.
  func testAttachingAnUnlaidOutSurfaceLeavesTheRunningProgramsSizeAlone() async throws {
    try await withWorkbench { model, _ in
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let shell = try XCTUnwrap(model.session(for: sessionID)?.shells.first)
      let probe = try TerminalAttachment.open(
        socketPath: try UnixSocketPath(shell.attachSocketPath), shellID: shell.id)
      defer { probe.close() }
      var size = winsize(ws_row: 37, ws_col: 101, ws_xpixel: 0, ws_ypixel: 0)
      XCTAssertEqual(ioctl(probe.ptyDescriptor, TIOCSWINSZ, &size), 0)

      let runtime = GhosttyRuntime()
      try XCTSkipIf(runtime.errorMessage != nil, "libghostty unavailable: \(runtime.errorMessage ?? "")")
      let (_, view) = runtime.surfaces.presentation(
        for: shell, initialSize: .zero, onFocus: {}, onStatusChange: { _ in }, onSplit: { _ in },
        onClose: {})
      let deadline = ContinuousClock.now + .seconds(5)
      while view.connection != .connected {
        XCTAssertNil(view.connection.failureMessage)
        guard ContinuousClock.now < deadline else { return XCTFail("the surface never attached") }
        try await Task.sleep(for: .milliseconds(20))
      }
      // libghostty adopts the PTY on its I/O thread; give it time to act.
      try await Task.sleep(for: .milliseconds(500))

      func ptySize() -> [UInt16] {
        var observed = winsize()
        XCTAssertEqual(ioctl(probe.ptyDescriptor, TIOCGWINSZ, &observed), 0)
        return [observed.ws_row, observed.ws_col]
      }
      let surface = try XCTUnwrap(view.surface)
      func surfaceGrid() -> [UInt16] {
        let size = ghostty_surface_size(surface)
        return [size.rows, size.columns]
      }
      XCTAssertEqual(ptySize(), [37, 101])

      // Laying the surface out gives the PTY its real grid at once...
      runtime.surfaces.sizeOffscreenSurfaces(
        layouts: [.pane(shell.id)], terminalAreaSize: CGSize(width: 600, height: 400),
        backingScale: 2)
      XCTAssertNotEqual(surfaceGrid(), [37, 101])
      XCTAssertEqual(ptySize(), surfaceGrid())

      // ...and later resizes still flow through libghostty.
      runtime.surfaces.sizeOffscreenSurfaces(
        layouts: [.pane(shell.id)], terminalAreaSize: CGSize(width: 900, height: 700),
        backingScale: 2)
      let resizeDeadline = ContinuousClock.now + .seconds(3)
      while ptySize() != surfaceGrid(), ContinuousClock.now < resizeDeadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertEqual(ptySize(), surfaceGrid())
    }
  }

  /// A surface parses Axod's replay as soon as it exists, before AppKit lays it out. Created at
  /// libghostty's default size, a replay written for the pane's real width soft-wraps and stays
  /// mangled after the reflow: zsh's PROMPT_SP mark (`%`, width-1 spaces, `\r \r`) survived on
  /// every restored shell. Seeded with the pane's layout size, the replay lands as written.
  func testReplayIsParsedAtThePanesWidthNotTheDefaultSurfaceSize() async throws {
    try await withWorkbench { model, _ in
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let shell = try XCTUnwrap(model.session(for: sessionID)?.shells.first)
      let runtime = GhosttyRuntime()
      try XCTSkipIf(runtime.errorMessage != nil, "libghostty unavailable: \(runtime.errorMessage ?? "")")
      // A wide pane: the default 800x600 surface is far narrower.
      runtime.surfaces.sizeOffscreenSurfaces(
        layouts: [.pane(shell.id)], terminalAreaSize: CGSize(width: 1500, height: 700), backingScale: 2)

      @MainActor func present() async throws -> GhosttySurfaceNSView {
        let (_, view) = runtime.surfaces.presentation(
          for: shell, initialSize: .zero, onFocus: {}, onStatusChange: { _ in }, onSplit: { _ in },
          onClose: {})
        let deadline = ContinuousClock.now + .seconds(5)
        while view.connection != .connected || view.surface == nil {
          let failure = view.connection.failureMessage
          XCTAssertNil(failure)
          guard ContinuousClock.now < deadline else { throw XCTSkip("the surface never attached") }
          try await Task.sleep(for: .milliseconds(20))
        }
        return view
      }

      // The pane's grid, which the program must have been laid out for.
      let measuring = try await present()
      let columns = ghostty_surface_size(try XCTUnwrap(measuring.surface)).columns
      XCTAssertGreaterThan(columns, 120)
      runtime.reconcileSurfaces(with: [])

      // The program writes zsh's PROMPT_SP sequence for that width while nothing is attached.
      let probe = try TerminalAttachment.open(
        socketPath: try UnixSocketPath(shell.attachSocketPath), shellID: shell.id)
      defer { probe.close() }
      var size = winsize(ws_row: 30, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
      XCTAssertEqual(ioctl(probe.ptyDescriptor, TIOCSWINSZ, &size), 0)
      let command =
        "printf '\\033[H\\033[2J\\033[7m%%\\033[0m%\(Int(columns) - 1)s\\r \\r\\033[J; %s' '' READY; cat\n"
      XCTAssertEqual(command.withCString { write(probe.ptyDescriptor, $0, strlen($0)) }, command.utf8.count)
      // Wait until the program has run it (a login shell may still be starting).
      var output = Data()
      let ready = Data("; READY".utf8)
      let outputDeadline = ContinuousClock.now + .seconds(10)
      var buffer = [UInt8](repeating: 0, count: 4096)
      while output.range(of: ready) == nil {
        guard ContinuousClock.now < outputDeadline else { return XCTFail("the command never ran") }
        var poller = pollfd(fd: probe.outputDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, 100) > 0 else { continue }
        let count = read(probe.outputDescriptor, &buffer, buffer.count)
        guard count > 0 else { return XCTFail("the attach stream ended") }
        output.append(contentsOf: buffer[..<count])
      }

      // A new surface replays it.
      let view = try await present()
      var screen = view.accessibilityVisibleText()
      let parseDeadline = ContinuousClock.now + .seconds(3)
      while !screen.contains("; READY"), ContinuousClock.now < parseDeadline {
        try await Task.sleep(for: .milliseconds(50))
        screen = view.accessibilityVisibleText()
      }
      let firstLine = screen.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
      XCTAssertEqual(firstLine.trimmingCharacters(in: .whitespaces), "; READY", "screen: \(screen)")
      XCTAssertFalse(screen.contains("%"), "screen: \(screen)")
    }
  }

  /// A fullscreen animation changes the terminal area every frame. Hidden surfaces must not
  /// follow each frame (a reflow and SIGWINCH per hidden program per frame); they follow once the
  /// geometry settles.
  func testHiddenSurfacesFollowTheWindowOnlyAfterItsGeometrySettles() async throws {
    try await withWorkbench { model, _ in
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let shell = try XCTUnwrap(model.session(for: sessionID)?.shells.first)
      let runtime = GhosttyRuntime()
      try XCTSkipIf(runtime.errorMessage != nil, "libghostty unavailable: \(runtime.errorMessage ?? "")")
      let (_, view) = runtime.surfaces.presentation(
        for: shell, initialSize: .zero, onFocus: {}, onStatusChange: { _ in }, onSplit: { _ in },
        onClose: {})
      let deadline = ContinuousClock.now + .seconds(5)
      while view.connection != .connected {
        XCTAssertNil(view.connection.failureMessage)
        guard ContinuousClock.now < deadline else { return XCTFail("the surface never attached") }
        try await Task.sleep(for: .milliseconds(20))
      }
      let surface = try XCTUnwrap(view.surface)
      func surfaceGrid() -> [UInt16] {
        let size = ghostty_surface_size(surface)
        return [size.rows, size.columns]
      }

      // The first geometry applies at once: there is nothing to animate from.
      runtime.surfaces.scheduleOffscreenSizing(
        layouts: [.pane(shell.id)], terminalAreaSize: CGSize(width: 600, height: 400), backingScale: 2)
      let initialGrid = surfaceGrid()

      // An animation: many frames in quick succession leave the hidden grid alone...
      for step in 1...10 {
        runtime.surfaces.scheduleOffscreenSizing(
          layouts: [.pane(shell.id)],
          terminalAreaSize: CGSize(width: 600 + 30 * step, height: 400 + 30 * step), backingScale: 2)
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(surfaceGrid(), initialGrid)

      // ...and once it settles the hidden surface takes the final size, matching a direct sizing.
      try await Task.sleep(for: TerminalSurfaceRegistry.offscreenSizingSettleDelay + .milliseconds(150))
      let settledGrid = surfaceGrid()
      XCTAssertNotEqual(settledGrid, initialGrid)
      runtime.surfaces.sizeOffscreenSurfaces(
        layouts: [.pane(shell.id)], terminalAreaSize: CGSize(width: 900, height: 700), backingScale: 2)
      XCTAssertEqual(surfaceGrid(), settledGrid)
    }
  }

  /// Times switching Sessions in the real workbench view (SwiftUI + AppKit + libghostty) hosted
  /// in an offscreen window. A benchmark, not a pass/fail bound: read `BENCH` in the test log.
  /// It takes ~5 s, so it runs only when asked:
  /// `bazel test //apple/AxoMac:TerminalWorkbenchE2ETests --test_env=AXO_RUN_BENCHMARKS=1
  /// --test_filter=testBenchmarkSwitchingSessions --test_sharding_strategy=disabled
  /// --test_output=all` (a filtered sharded run fails its empty shards).
  func testBenchmarkSwitchingSessions() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["AXO_RUN_BENCHMARKS"] == "1",
      "Benchmarks run only with AXO_RUN_BENCHMARKS=1.")
    try await withWorkbench { model, _ in
      let runtime = GhosttyRuntime()
      try XCTSkipIf(runtime.errorMessage != nil, "libghostty unavailable: \(runtime.errorMessage ?? "")")
      for _ in 0..<7 { await model.createSession() }
      for session in model.sessions {
        model.showSession(session.id)
        await model.split(.right)
      }
      let sessionIDs = model.sessions.map(\.id)
      XCTAssertEqual(sessionIDs.count, 8)

      let suite = "axo-bench-\(UUID().uuidString)"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let root = TerminalWorkbenchView(
        daemon: DaemonController(defaults: defaults), sessions: model,
        isPresentingWorkspaceCreation: .constant(false), daemonIsRunningOverride: true
      ).environment(runtime)
      let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let host = NSHostingView(rootView: root)
      window.contentView = host
      defer { window.close() }

      func settle() {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
      }
      // Warm up: show every Session once and let its surfaces attach.
      for id in sessionIDs {
        model.showSession(id)
        settle()
        try await Task.sleep(for: .milliseconds(150))
        settle()
      }

      var samples: [Double] = []
      for round in 0..<5 {
        for id in (round.isMultiple(of: 2) ? sessionIDs : sessionIDs.reversed()) {
          let start = ContinuousClock.now
          model.showSession(id)
          settle()
          let elapsed = ContinuousClock.now - start
          samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000)
          try await Task.sleep(for: .milliseconds(20))
        }
      }
      samples.sort()
      let median = samples[samples.count / 2]
      let p90 = samples[samples.count * 9 / 10]
      print("BENCH session_switch_ms n=\(samples.count) p50=\(String(format: "%.1f", median)) p90=\(String(format: "%.1f", p90)) max=\(String(format: "%.1f", samples.last ?? 0))")
    }
  }

  func testRefreshFocusesTheNewestCreatedPane() async throws {
    try await withWorkbench { model, daemon in
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let firstShell = try XCTUnwrap(model.session(for: sessionID)?.shells.first)
      let socketPath = try UnixSocketPath(daemon.socketPath.path)

      let newestShell = try await UnixSocketRPC.createShell(in: sessionID, at: socketPath)
      await model.refresh()

      XCTAssertEqual(model.focusedShellID, newestShell.id)
      XCTAssertEqual(model.layout?.shellIDs, [firstShell.id, newestShell.id])
    }
  }

  func testPaneHierarchySurvivesWorkbenchModelRecreation() async throws {
    let daemon = try DaemonFixture()
    defer { daemon.stop() }
    let socketPath = try UnixSocketPath(daemon.socketPath.path)
    let defaultsSuite = "axo-terminal-layout-test-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    let firstModel = TerminalSessionsModel(
      socketPath: socketPath,
      selectedSessionDefaults: defaults
    )
    await firstModel.refresh()
    await firstModel.createSession()
    let sessionID = try XCTUnwrap(firstModel.selectedSessionID)
    let firstShell = try XCTUnwrap(firstModel.session(for: sessionID)?.shells.first)

    await firstModel.split(.right)
    await firstModel.split(.down)
    if case .split(let splitID, _, _, _, _) = firstModel.layout {
      firstModel.resizeSplit(splitID, to: 0.63)
    }
    let expectedLayout = try XCTUnwrap(firstModel.layout)
    XCTAssertEqual(expectedLayout.orderedShellIDs.count, 3)
    try await waitUntilLayout(expectedLayout, for: sessionID, at: socketPath)

    let reopenedModel = TerminalSessionsModel(
      socketPath: socketPath,
      selectedSessionDefaults: defaults
    )
    await reopenedModel.refresh()

    XCTAssertEqual(reopenedModel.selectedSessionID, sessionID)
    XCTAssertEqual(reopenedModel.layout, expectedLayout)
    XCTAssertEqual(reopenedModel.layout?.firstShellID, firstShell.id)
  }

  func testClosingNewWorkspaceSessionReturnsToPreviousSessionInWorkspace() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-session-focus-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await withWorkbench { model, _ in
      await model.createWorkspace(
        name: "Session Focus",
        directoryPath: directory.path,
        directoryBookmark: nil
      )
      XCTAssertNil(model.workspaceCreationError)

      let previousSessionID = try XCTUnwrap(model.selectedSessionID)
      let workspaceID = try XCTUnwrap(model.session(for: previousSessionID)?.workspaceId)
      await model.createSessionInCurrentContext()

      let newSessionID = try XCTUnwrap(model.selectedSessionID)
      XCTAssertNotEqual(newSessionID, previousSessionID)
      XCTAssertEqual(model.session(for: newSessionID)?.workspaceId, workspaceID)
      let shell = try XCTUnwrap(model.session(for: newSessionID)?.shells.first)

      await model.closeShell(shell.id)

      XCTAssertEqual(model.selectedSessionID, previousSessionID)
      XCTAssertEqual(model.session(for: previousSessionID)?.workspaceId, workspaceID)
      XCTAssertNil(model.errorMessage)
    }
  }

  func testPaneNavigationCyclesInLayoutOrder() async throws {
    try await withWorkbench { model, _ in
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let firstShell = try XCTUnwrap(model.session(for: sessionID)?.shells.first)

      await model.split(.right)
      let secondShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first { $0.id != firstShell.id }
      )
      await model.split(.down)
      let thirdShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first {
          $0.id != firstShell.id && $0.id != secondShell.id
        }
      )
      XCTAssertEqual(model.layout?.orderedShellIDs, [firstShell.id, secondShell.id, thirdShell.id])

      model.focusPreviousPane()
      XCTAssertEqual(model.focusedShellID, secondShell.id)
      model.focusPreviousPane()
      XCTAssertEqual(model.focusedShellID, firstShell.id)
      model.focusPreviousPane()
      XCTAssertEqual(model.focusedShellID, thirdShell.id)
      model.focusNextPane()
      XCTAssertEqual(model.focusedShellID, firstShell.id)
    }
  }

  func testSessionNavigationCyclesInSessionOrder() async throws {
    try await withWorkbench { model, daemon in
      let firstSessionID = try XCTUnwrap(model.selectedSessionID)
      await model.createSession()
      let secondSessionID = try XCTUnwrap(model.selectedSessionID)
      XCTAssertNotEqual(firstSessionID, secondSessionID)
      let secondSession = try XCTUnwrap(model.session(for: secondSessionID))
      XCTAssertNil(secondSession.workspaceId)
      XCTAssertEqual(secondSession.initialPwd, daemon.homeDirectory.path)

      model.showNextSession()
      XCTAssertEqual(model.selectedSessionID, firstSessionID)
      model.showNextSession()
      XCTAssertEqual(model.selectedSessionID, secondSessionID)
      model.showPreviousSession()
      XCTAssertEqual(model.selectedSessionID, firstSessionID)
      model.showPreviousSession()
      XCTAssertEqual(model.selectedSessionID, secondSessionID)
    }
  }

  func testSessionNavigationFollowsWorkspaceThenStandaloneSidebarOrder() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-sidebar-order-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await withWorkbench { model, _ in
      let firstStandaloneID = try XCTUnwrap(model.selectedSessionID)
      await model.createWorkspace(
        name: "Sidebar Order",
        directoryPath: directory.path,
        directoryBookmark: nil
      )
      let firstWorkspaceSessionID = try XCTUnwrap(model.selectedSessionID)
      let workspaceID = try XCTUnwrap(model.session(for: firstWorkspaceSessionID)?.workspaceId)
      await model.createSession(in: workspaceID)
      let secondWorkspaceSessionID = try XCTUnwrap(model.selectedSessionID)
      await model.createSession()
      let secondStandaloneID = try XCTUnwrap(model.selectedSessionID)

      let sidebarOrder = [
        firstWorkspaceSessionID,
        secondWorkspaceSessionID,
        firstStandaloneID,
        secondStandaloneID,
      ]
      XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), sidebarOrder)

      model.showNextSession()
      XCTAssertEqual(model.selectedSessionID, firstWorkspaceSessionID)
      model.showNextSession()
      XCTAssertEqual(model.selectedSessionID, secondWorkspaceSessionID)
      model.showPreviousSession()
      XCTAssertEqual(model.selectedSessionID, firstWorkspaceSessionID)
      model.showPreviousSession()
      XCTAssertEqual(model.selectedSessionID, secondStandaloneID)
    }
  }

  func testClosingLastWorkspaceSessionRequiresConfirmationToArchiveWorkspace() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-last-session-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await withWorkbench { model, _ in
      await model.createWorkspace(
        name: "Last Session",
        directoryPath: directory.path,
        directoryBookmark: nil
      )
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let workspaceID = try XCTUnwrap(model.session(for: sessionID)?.workspaceId)

      await model.requestCloseSession(sessionID)

      XCTAssertEqual(model.pendingWorkspaceArchiveConfirmation?.workspaceID, workspaceID)
      XCTAssertEqual(model.pendingWorkspaceArchiveConfirmation?.sessionID, sessionID)
      XCTAssertNotNil(model.session(for: sessionID))
      XCTAssertTrue(model.workspaces.contains { $0.workspaceId == workspaceID })

      let confirmation = try XCTUnwrap(model.pendingWorkspaceArchiveConfirmation)
      await model.confirmWorkspaceArchiveAndCloseSession(confirmation)

      XCTAssertNil(model.pendingWorkspaceArchiveConfirmation)
      XCTAssertNil(model.session(for: sessionID))
      XCTAssertFalse(model.workspaces.contains { $0.workspaceId == workspaceID })
      XCTAssertNil(model.errorMessage)
    }
  }

  func testCommandWClosureCollapsesNestedPaneWithoutKillingSiblings() async throws {
    try await withWorkbench { model, daemon in
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let firstShell = try XCTUnwrap(model.session(for: sessionID)?.shells.first)
      await model.split(.right)
      let secondShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first { $0.id != firstShell.id }
      )
      await model.split(.down)
      let thirdShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first {
          $0.id != firstShell.id && $0.id != secondShell.id
        }
      )
      XCTAssertEqual(model.focusedShellID, thirdShell.id)

      await model.closeShell(try XCTUnwrap(model.focusedShellID))

      XCTAssertEqual(model.layout?.shellIDs, [firstShell.id, secondShell.id])
      XCTAssertEqual(model.focusedShellID, secondShell.id)
      try daemon.assertCanRunCommand(in: firstShell)
      try daemon.assertCanRunCommand(in: secondShell)
    }
  }

  func testExitingTheOnlyShellSelectsTheDaemonReplacement() async throws {
    try await withWorkbench { model, daemon in
      let oldSessionID = try XCTUnwrap(model.selectedSessionID)
      let oldShell = try XCTUnwrap(model.session(for: oldSessionID)?.shells.first)

      try daemon.sendExit(to: oldShell)
      try await waitUntilSessionIsGone(oldSessionID, from: model)

      let replacementID = try XCTUnwrap(model.selectedSessionID)
      XCTAssertNotEqual(replacementID, oldSessionID)
      let replacementShell = try XCTUnwrap(model.session(for: replacementID)?.shells.first)
      XCTAssertEqual(model.layout, .pane(replacementShell.id))
      XCTAssertEqual(model.focusedShellID, replacementShell.id)
      try daemon.assertCanRunCommand(in: replacementShell)
    }
  }

  func testExitingUnselectedSessionPaneDoesNotResurrectItOnReturn() async throws {
    try await withWorkbench { model, daemon in
      let firstSessionID = try XCTUnwrap(model.selectedSessionID)
      let firstShell = try XCTUnwrap(model.session(for: firstSessionID)?.shells.first)
      await model.split(.right)
      let secondShell = try XCTUnwrap(
        model.session(for: firstSessionID)?.shells.first { $0.id != firstShell.id }
      )
      await model.split(.down)
      let thirdShell = try XCTUnwrap(
        model.session(for: firstSessionID)?.shells.first {
          $0.id != firstShell.id && $0.id != secondShell.id
        }
      )

      await model.createSession()
      let otherSessionID = try XCTUnwrap(model.selectedSessionID)
      XCTAssertNotEqual(otherSessionID, firstSessionID)

      try daemon.sendExit(to: secondShell)
      try await waitUntilShellIsGone(secondShell.id, from: model)
      XCTAssertEqual(model.selectedSessionID, otherSessionID)

      model.showSession(firstSessionID)
      XCTAssertEqual(model.layout?.shellIDs, [firstShell.id, thirdShell.id])
      XCTAssertFalse(model.layout?.contains(shellID: secondShell.id) ?? true)
      try daemon.assertCanRunCommand(in: firstShell)
      try daemon.assertCanRunCommand(in: thirdShell)
    }
  }

  func testExitingAllShellsInOneTabLeavesOtherTabIntact() async throws {
    try await withWorkbench { model, daemon in
      let originalSessionID = try XCTUnwrap(model.selectedSessionID)
      let originalShell = try XCTUnwrap(model.session(for: originalSessionID)?.shells.first)

      await model.createSession()
      let exitedSessionID = try XCTUnwrap(model.selectedSessionID)
      let firstExitedShell = try XCTUnwrap(model.session(for: exitedSessionID)?.shells.first)
      await model.split(.right)
      let lastExitedShell = try XCTUnwrap(
        model.session(for: exitedSessionID)?.shells.first { $0.id != firstExitedShell.id }
      )

      try daemon.sendExit(to: firstExitedShell)
      try await waitUntilShellIsGone(firstExitedShell.id, from: model)
      XCTAssertEqual(model.selectedSessionID, exitedSessionID)
      try daemon.sendExit(to: lastExitedShell)
      try await waitUntilSessionIsGone(exitedSessionID, from: model)

      XCTAssertEqual(model.selectedSessionID, originalSessionID)
      XCTAssertEqual(model.layout, .pane(originalShell.id))
      XCTAssertEqual(model.session(for: originalSessionID)?.shells, [originalShell])
      try daemon.assertCanRunCommand(in: originalShell)
    }
  }

  func testRepeatedNestedShellExitsCollapseOnlyTheirOwnBranches() async throws {
    try await withWorkbench { model, daemon in
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let initialShell = try XCTUnwrap(model.session(for: sessionID)?.shells.first)

      await model.split(.right)
      let secondShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first { $0.id != initialShell.id }
      )
      await model.split(.down)
      let thirdShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first {
          $0.id != initialShell.id && $0.id != secondShell.id
        }
      )
      await model.split(.right)
      let fourthShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first {
          $0.id != initialShell.id && $0.id != secondShell.id && $0.id != thirdShell.id
        }
      )

      try daemon.sendExit(to: thirdShell)
      try await waitUntilShellIsGone(thirdShell.id, from: model)
      try daemon.sendExit(to: secondShell)
      try await waitUntilShellIsGone(secondShell.id, from: model)

      XCTAssertEqual(model.layout?.shellIDs, [initialShell.id, fourthShell.id])
      try daemon.assertCanRunCommand(in: initialShell)
      try daemon.assertCanRunCommand(in: fourthShell)
    }
  }

  private func waitUntilLayout(
    _ expected: TerminalLayout,
    for sessionID: SessionID,
    at socketPath: UnixSocketPath
  ) async throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      let sessions = try await UnixSocketRPC.listSessionSnapshot(at: socketPath).sessions
      if let storedLayout = sessions.first(where: { $0.id == sessionID })?.layout,
        TerminalLayout(storedLayout) == expected
      {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTFail("axod did not persist the session pane hierarchy")
  }

  private func withWorkbench(
    _ test: (TerminalSessionsModel, DaemonFixture) async throws -> Void
  ) async throws {
    let daemon = try DaemonFixture()
    defer { daemon.stop() }
    let socketPath = try UnixSocketPath(daemon.socketPath.path)
    let model = TerminalSessionsModel(socketPath: socketPath)
    await model.refresh()
    XCTAssertNil(model.errorMessage)
    if model.sessions.isEmpty { await model.createSession() }
    XCTAssertNotNil(model.selectedSessionID)

    try await test(model, daemon)
  }

  private func waitUntilShellIsGone(
    _ shellID: ShellID,
    from model: TerminalSessionsModel
  ) async throws {
    let deadline = Date().addingTimeInterval(6)
    while Date() < deadline {
      await model.refresh()
      if !model.sessions.flatMap(\.shells).contains(where: { $0.id == shellID }) {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Shell \(shellID) was not reaped within six seconds")
  }

  private func waitUntilSessionIsGone(
    _ sessionID: SessionID,
    from model: TerminalSessionsModel
  ) async throws {
    let deadline = Date().addingTimeInterval(6)
    while Date() < deadline {
      await model.refresh()
      if model.session(for: sessionID) == nil {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Session \(sessionID) was not reaped within six seconds")
  }
}

@MainActor
private final class DaemonFixture {
  let executableURL: URL
  let socketPath: URL
  /// The daemon's `HOME`; standalone Sessions start here.
  let homeDirectory: URL
  private let root: URL
  private let daemon: Process

  init() throws {
    executableURL = try Self.runfile(named: "AXOD_TEST_BINARY")
    root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent(
        "axo-wb-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))",
        isDirectory: true
      )
    socketPath = root.appendingPathComponent("axod.sock")
    let serverDirectory = root.appendingPathComponent("server", isDirectory: true)
    homeDirectory = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: serverDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)

    daemon = Process()
    daemon.executableURL = executableURL
    daemon.arguments = ["--socket", socketPath.path, "--server-dir", serverDirectory.path]
    // Pi panes run the declared inert fixtures, never the developer's Pi or extension.
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = homeDirectory.path
    environment["AXO_PI_EXTENSION_PATH"] = try Self.runfile(
      named: "AXO_PI_EXTENSION_PATH", executable: false
    ).path
    environment["AXO_PI_EXECUTABLE"] = try Self.runfile(named: "AXO_TEST_PI_EXECUTABLE").path
    daemon.environment = environment
    daemon.standardOutput = FileHandle.nullDevice
    daemon.standardError = FileHandle.nullDevice
    try daemon.run()
    try waitForSocket()
  }

  func sendExit(to shell: TerminalShell) throws {
    let attachment = try attach(to: shell, output: FileHandle.nullDevice)
    try attachment.input.fileHandleForWriting.write(contentsOf: Data("exit\n".utf8))
  }

  func assertCanRunCommand(in shell: TerminalShell) throws {
    let output = Pipe()
    let attachment = try attach(to: shell, output: output)
    defer { stop(attachment.process) }

    let suffix = "SHELL_\(shell.id)_READY"
    let expectedMarker = Data("AXO_E2E_\(suffix)".utf8)
    let command = "printf 'AXO_E2E_' && printf '\(suffix)\\n'\n"
    try attachment.input.fileHandleForWriting.write(contentsOf: Data(command.utf8))

    let descriptor = output.fileHandleForReading.fileDescriptor
    let deadline = Date().addingTimeInterval(4)
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while Date() < deadline {
      var readyDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let timeout = Int32(max(1, deadline.timeIntervalSinceNow * 1_000))
      let ready = Darwin.poll(&readyDescriptor, 1, timeout)
      if ready == -1, errno == EINTR { continue }
      guard ready > 0 else { break }
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      if count == -1, errno == EINTR || errno == EAGAIN { continue }
      guard count > 0 else { break }
      received.append(contentsOf: buffer.prefix(count))
      if received.range(of: expectedMarker) != nil { return }
    }
    XCTFail(
      "Shell \(shell.id) did not execute a command after a sibling exited. PTY output: \(String(decoding: received, as: UTF8.self))"
    )
  }

  func stop() {
    stop(daemon)
    try? FileManager.default.removeItem(at: root)
  }

  private func attach(to shell: TerminalShell, output: Any) throws -> Attachment {
    let input = Pipe()
    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
      "terminal-attach",
      "--attach-socket", shell.attachSocketPath,
      "--shell-id", shell.id.description,
    ]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    return Attachment(process: process, input: input)
  }

  private func waitForSocket() throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if socketAcceptsConnections(atPath: socketPath.path) { return }
      guard daemon.isRunning else {
        let logPath = root.appendingPathComponent("server/stderr.log").path
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "<no server log>"
        throw E2EError.daemonExitedEarly(executableURL.path, daemon.terminationStatus, log)
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    throw E2EError.daemonTimedOut
  }

  private func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let gracefulDeadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < gracefulDeadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    guard process.isRunning else { return }
    _ = Darwin.kill(process.processIdentifier, SIGKILL)
    let killDeadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < killDeadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
  }

  private static func runfile(named variable: String, executable: Bool = true) throws -> URL {
    guard let relativePath = ProcessInfo.processInfo.environment[variable] else {
      throw E2EError.missingRunfile(variable)
    }
    let fileManager = FileManager.default
    var candidates = [URL(fileURLWithPath: relativePath)]
    if let root = ProcessInfo.processInfo.environment["RUNFILES_DIR"]
      ?? ProcessInfo.processInfo.environment["TEST_SRCDIR"]
    {
      let runfiles = URL(fileURLWithPath: root, isDirectory: true)
      candidates.append(runfiles.appendingPathComponent(relativePath))
      if let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] {
        candidates.append(
          runfiles.appendingPathComponent(workspace).appendingPathComponent(relativePath))
      }
      candidates.append(
        runfiles.appendingPathComponent("_main").appendingPathComponent(relativePath))
    }
    guard
      let file = candidates.first(where: {
        executable
          ? fileManager.isExecutableFile(atPath: $0.path)
          : fileManager.fileExists(atPath: $0.path)
      })
    else {
      throw E2EError.runfileNotFound(relativePath)
    }
    return file
  }
}

private struct Attachment {
  let process: Process
  let input: Pipe
}

private enum E2EError: Error, LocalizedError {
  case missingRunfile(String)
  case runfileNotFound(String)
  case daemonExitedEarly(String, Int32, String)
  case daemonTimedOut

  var errorDescription: String? {
    switch self {
    case .missingRunfile(let name): "Missing Bazel runfile environment variable \(name)."
    case .runfileNotFound(let path): "Could not find executable Bazel runfile \(path)."
    case .daemonExitedEarly(let path, let status, let log):
      "The isolated axod process at \(path) exited with status \(status) before creating its socket. Log: \(log)"
    case .daemonTimedOut: "The isolated axod process did not create its socket within five seconds."
    }
  }
}

/// Whether a Unix-domain socket at `path` accepts connections. Its file exists from `bind()`,
/// before axod's `listen()`; a connect between the two is refused, so existence is not readiness.
private func socketAcceptsConnections(atPath path: String) -> Bool {
  let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else { return false }
  defer { Darwin.close(descriptor) }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    buffer.copyBytes(from: bytes)
  }
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  return withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
    }
  }
}
