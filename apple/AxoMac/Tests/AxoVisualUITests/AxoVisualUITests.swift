import AppKit
import AxoRPC
import CoreGraphics
import Foundation
import Vision
import XCTest

@testable import AxoMac


/// Real-UI acceptance tests against an isolated Axod, driven through the AXO_TEST_HOST app.
/// Tests live in per-feature extensions so `-only-testing:AxoVisualUITests/AxoVisualUITests/<test>`
/// keeps working; shared fixture code is in `UITestFixture.swift`.
@MainActor
final class AxoVisualUITests: XCTestCase {}

/// Polling helpers shared by the feature extensions.
extension AxoVisualUITests {
  func assertNoAxoUITestAppIsAlreadyRunning() throws {
    let frontendBundleIDs: Set<String> = [
      "dev.leostera.axo",
      "dev.leostera.axo.ui-tests",
    ]
    let running = NSWorkspace.shared.runningApplications.first {
      guard let bundleIdentifier = $0.bundleIdentifier else { return false }
      return frontendBundleIDs.contains(bundleIdentifier) && !$0.isTerminated
    }
    guard let running else { return }
    throw UITestError.frontendAlreadyRunning(
      "\(running.bundleIdentifier ?? "unknown Axo bundle") (pid \(running.processIdentifier))")
  }

  func waitForFile(at url: URL, timeout: TimeInterval) async throws -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let data = try? Data(contentsOf: url) { return data }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw UITestError.timedOut("isolated terminal probe did not create \(url.lastPathComponent)")
  }

  func pythonStringLiteral(_ value: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let encoded = try encoder.encode(value)
    return String(decoding: encoded, as: UTF8.self)
  }

  func waitForPiTranscript(at path: String, containing marker: String) async throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if let transcript = try? String(contentsOfFile: path, encoding: .utf8), transcript.contains(marker) {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw UITestError.timedOut("Pi did not persist the interactive Session transcript")
  }

  func waitForPiBinding(sessionID: SessionID, model: TerminalSessionsModel) async throws {
    let deadline = Date().addingTimeInterval(90)
    while Date() < deadline {
      await model.refresh()
      if model.session(for: sessionID)?.piSessionId != nil { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw UITestError.timedOut("axod did not verify the exact Pi session-file binding")
  }

  func waitForWorkspaceSession(model: TerminalSessionsModel) async throws {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      await model.refresh()
      if model.sessions.contains(where: { $0.workspaceId != nil }) { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw UITestError.timedOut(
      "axod did not create the Workspace Agent Session: \(model.errorMessage ?? "no RPC error reported")")
  }

  func waitForSessionCount(_ count: Int, model: TerminalSessionsModel) async throws {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      await model.refresh()
      if model.sessions.count == count { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw UITestError.sessionCountTimedOut(count, model.sessions.count)
  }

  func waitForShellCount(
    _ count: Int,
    sessionID: SessionID,
    model: TerminalSessionsModel
  ) async throws {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      await model.refresh()
      if model.session(for: sessionID)?.shells.count == count { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw UITestError.shellCountTimedOut(
      count, model.session(for: sessionID)?.shells.count ?? 0, sessionID)
  }
}
