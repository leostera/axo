import AxoRPC
import Combine
import Foundation

@MainActor
final class TerminalAttachmentModel: ObservableObject {
  @Published private(set) var output = ""
  @Published private(set) var status = "Connecting to Axo D…"
  @Published private(set) var canSendCommands = false

  private let session: TerminalSession
  private let helperURL: URL
  private var process: Process?
  private var inputPipe: Pipe?
  private var outputPipe: Pipe?
  private var outputDecoder = TerminalOutputDecoder()

  init(session: TerminalSession, helperURL: URL) {
    self.session = session
    self.helperURL = helperURL
  }

  func start() {
    guard process == nil else { return }
    guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
      status = "Bundled axod terminal-attach helper is missing."
      return
    }

    let child = Process()
    let input = Pipe()
    let output = Pipe()
    child.executableURL = helperURL
    child.arguments = [
      "terminal-attach",
      "--attach-socket", session.attachSocketPath,
      "--session-id", String(session.id),
    ]
    child.standardInput = input
    child.standardOutput = output
    child.standardError = FileHandle.nullDevice
    child.terminationHandler = { [weak self] child in
      Task { @MainActor [weak self] in
        self?.attachmentEnded(child)
      }
    }

    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor [weak self] in
        self?.append(data)
      }
    }

    do {
      try child.run()
      process = child
      inputPipe = input
      outputPipe = output
      status = "Attached to PTY · \(session.ptyDevice)"
      canSendCommands = true
    } catch {
      output.fileHandleForReading.readabilityHandler = nil
      status = "Could not attach to session: \(error.localizedDescription)"
    }
  }

  func stop() {
    guard let child = process else { return }
    process = nil
    canSendCommands = false
    inputPipe?.fileHandleForWriting.closeFile()
    inputPipe = nil
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    outputPipe = nil
    if child.isRunning {
      child.terminate()
    }
    status = "Detached"
  }

  func sendCommand(_ command: String) {
    guard canSendCommands, let inputPipe else { return }
    do {
      try inputPipe.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    } catch {
      status = "Could not write to PTY: \(error.localizedDescription)"
      canSendCommands = false
    }
  }

  private func append(_ data: Data) {
    let text = outputDecoder.decode(data)
    guard !text.isEmpty else { return }
    output.append(contentsOf: text)
    if output.count > 100_000 {
      output.removeFirst(output.count - 100_000)
    }
  }

  private func attachmentEnded(_ child: Process) {
    guard process === child else { return }
    process = nil
    inputPipe = nil
    outputPipe = nil
    canSendCommands = false
    if child.terminationStatus == 0 {
      status = "Session shell exited."
    } else {
      status = "PTY attachment ended (exit \(child.terminationStatus))."
    }
  }
}

private struct TerminalOutputDecoder {
  private enum EscapeState {
    case normal
    case escaped
    case controlSequence
    case operatingSystemCommand
    case operatingSystemCommandEscaped
  }

  private var state = EscapeState.normal

  mutating func decode(_ data: Data) -> String {
    var visibleBytes = [UInt8]()
    visibleBytes.reserveCapacity(data.count)

    for byte in data {
      switch state {
      case .normal:
        if byte == 0x1B {
          state = .escaped
        } else if byte == 0x0A || byte == 0x09 || byte >= 0x20 {
          visibleBytes.append(byte)
        }
      case .escaped:
        switch byte {
        case 0x5B: state = .controlSequence
        case 0x5D: state = .operatingSystemCommand
        default: state = .normal
        }
      case .controlSequence:
        if (0x40...0x7E).contains(byte) {
          state = .normal
        }
      case .operatingSystemCommand:
        if byte == 0x07 {
          state = .normal
        } else if byte == 0x1B {
          state = .operatingSystemCommandEscaped
        }
      case .operatingSystemCommandEscaped:
        state = byte == 0x5C ? .normal : .operatingSystemCommand
      }
    }

    return String(decoding: visibleBytes, as: UTF8.self)
  }
}
