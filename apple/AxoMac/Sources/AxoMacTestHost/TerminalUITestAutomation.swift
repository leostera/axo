import AppKit
import AxoProtocol
import Foundation

@testable import AxoMac

@MainActor
final class TerminalUITestAutomation {
  private struct Request: Decodable {
    let id: String
    let operation: String
    let keyCode: UInt16?
    let modifiers: [String]?
    let character: String?
    let text: String?
    let minimumSurfaceCount: Int?
    let sessionId: SessionID?
  }

  private struct Response: Encodable {
    let id: String
    let error: String?
  }

  private let sessions: TerminalSessionsModel
  private let ghostty: GhosttyRuntime

  init(sessions: TerminalSessionsModel, ghostty: GhosttyRuntime) {
    self.sessions = sessions
    self.ghostty = ghostty
  }

  func run(in directory: URL) async {
    let requestURL = directory.appendingPathComponent("request.json")
    while !Task.isCancelled {
      if let data = try? Data(contentsOf: requestURL) {
        try? FileManager.default.removeItem(at: requestURL)
        await process(data, in: directory)
      }
      try? await Task.sleep(for: .milliseconds(25))
    }
  }

  private func process(_ data: Data, in directory: URL) async {
    let response: Response
    do {
      let request = try JSONDecoder().decode(Request.self, from: data)
      try await execute(request)
      response = Response(id: request.id, error: nil)
    } catch {
      let id = (try? JSONDecoder().decode(Request.self, from: data).id) ?? "unknown"
      response = Response(id: id, error: error.localizedDescription)
    }

    let responseURL = directory.appendingPathComponent("response-\(response.id).json")
    guard let encoded = try? JSONEncoder().encode(response) else { return }
    try? encoded.write(to: responseURL, options: .atomic)
  }

  private func execute(_ request: Request) async throws {
    switch request.operation {
    case "keypress":
      try sendKey(request)
    case "text":
      guard let text = request.text, let shellID = sessions.focusedShellID else {
        throw AutomationError.noFocusedTerminal
      }
      try type(text, into: shellID)
    case "wait-ready":
      try await waitForTerminalSurface()
    case "wait-surface-count":
      try await waitForSurfaceCount(request.minimumSurfaceCount ?? 0)
    case "refresh":
      await sessions.refresh()
    case "select-session":
      guard let sessionId = request.sessionId, sessions.session(for: sessionId) != nil else {
        throw AutomationError.noSession
      }
      sessions.showSession(sessionId)
      await sessions.refresh()
    default:
      throw AutomationError.unknownOperation(request.operation)
    }
  }

  private func waitForTerminalSurface() async throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      await sessions.refresh()
      if let shellID = sessions.focusedShellID,
        sessions.layout != nil,
        ghostty.surfaces.hasSurface(for: shellID)
      {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw AutomationError.terminalSurfaceTimedOut
  }

  private func waitForSurfaceCount(_ count: Int) async throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      await sessions.refresh()
      ghostty.reconcileSurfaces(with: sessions.sessions.flatMap(\.shells))
      if ghostty.surfaces.surfaceCount == count { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw AutomationError.surfaceCountTimedOut(count, ghostty.surfaces.surfaceCount)
  }

  private func type(_ text: String, into shellID: ShellID) throws {
    let lines = text.components(separatedBy: "\n")
    for (index, line) in lines.enumerated() {
      if !line.isEmpty, !ghostty.insertText(line, into: shellID) {
        throw AutomationError.noFocusedTerminal
      }
      if index < lines.count - 1 {
        try sendKey(keyCode: 0x24, character: "\r", modifiers: [])
      }
    }
  }

  private func sendKey(_ request: Request) throws {
    guard let keyCode = request.keyCode,
      let character = request.character
    else { throw AutomationError.missingKey }
    try sendKey(keyCode: keyCode, character: character, modifiers: request.modifiers ?? [])
  }

  private func sendKey(keyCode: UInt16, character: String, modifiers requestedModifiers: [String])
    throws
  {
    var modifiers: NSEvent.ModifierFlags = []
    for modifier in requestedModifiers {
      switch modifier {
      case "command": modifiers.insert(.command)
      case "shift": modifiers.insert(.shift)
      case "control": modifiers.insert(.control)
      case "option": modifiers.insert(.option)
      default: throw AutomationError.unknownModifier(modifier)
      }
    }

    let windowNumber = NSApp.keyWindow?.windowNumber ?? 0
    guard
      let keyDown = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: windowNumber,
        context: nil,
        characters: modifiers.contains(.shift) ? character.uppercased() : character,
        charactersIgnoringModifiers: character,
        isARepeat: false,
        keyCode: keyCode
      ),
      let keyUp = NSEvent.keyEvent(
        with: .keyUp,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: windowNumber,
        context: nil,
        characters: modifiers.contains(.shift) ? character.uppercased() : character,
        charactersIgnoringModifiers: character,
        isARepeat: false,
        keyCode: keyCode
      )
    else { throw AutomationError.couldNotCreateKeyEvent }

    NSApp.sendEvent(keyDown)
    NSApp.sendEvent(keyUp)
  }
}

private enum AutomationError: Error, LocalizedError {
  case noFocusedTerminal
  case noSession
  case terminalSurfaceTimedOut
  case surfaceCountTimedOut(Int, Int)
  case unknownOperation(String)
  case missingKey
  case unknownModifier(String)
  case couldNotCreateKeyEvent

  var errorDescription: String? {
    switch self {
    case .noFocusedTerminal: "There is no focused terminal surface to receive text."
    case .noSession: "The requested test Session is not open."
    case .terminalSurfaceTimedOut:
      "The selected shell did not create a Ghostty surface within ten seconds."
    case .surfaceCountTimedOut(let expected, let actual):
      "Expected \(expected) Ghostty surfaces, but found \(actual)."
    case .unknownOperation(let value): "Unknown UI-test operation: \(value)."
    case .missingKey: "The UI-test keypress is missing its key code or character."
    case .unknownModifier(let value): "Unknown UI-test keyboard modifier: \(value)."
    case .couldNotCreateKeyEvent: "AppKit could not create the requested keyboard event."
    }
  }
}
