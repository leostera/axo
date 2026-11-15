import Foundation
import Observation

/// Read-only inspection is separate from explicit installation. No launch/upgrade path writes PATH.
@MainActor
@Observable
final class CLICommandInstallation {
  static let shared = CLICommandInstallation(bundle: Bundle.main.bundleURL,
    destination: systemDestination, perform: runInstaller)
  static let systemDestination = URL(fileURLWithPath: "/usr/local/bin/axo")

  enum Status: Equatable {
    case missing
    case installed
    case conflict
    case unavailable(String)

    var title: String {
      switch self {
      case .missing: "Not installed"
      case .installed: "Installed"
      case .conflict: "Another command exists"
      case .unavailable: "Unavailable"
      }
    }
    var canInstall: Bool { self == .missing }
  }

  let source: URL
  let destination: URL
  private(set) var status: Status = .missing
  private(set) var isInstalling = false
  private(set) var failure: String?
  @ObservationIgnored private let perform: (URL) async throws -> Void

  init(bundle: URL, destination: URL,
    perform: @escaping (URL) async throws -> Void)
  {
    source = bundle.appendingPathComponent("Contents/Helpers/axo").resolvingSymlinksInPath()
    self.destination = destination.standardizedFileURL
    self.perform = perform
    refresh()
  }

  func refresh() {
    guard !isInstalling else { return }
    status = Self.inspect(source: source, destination: destination)
    if status == .installed { failure = nil }
  }

  static func inspect(source: URL, destination: URL) -> Status {
    if source.path.contains("/AppTranslocation/")
      || (try? source.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    {
      return .unavailable("Move Axo to Applications, open it there, then install the command.")
    }
    let files = FileManager.default
    guard files.isExecutableFile(atPath: source.path) else {
      return .unavailable("This copy of Axo is missing its command-line tool. Install the latest Axo app.")
    }
    // readlink sees dangling links too. Never mistake one for an empty destination.
    if let target = try? files.destinationOfSymbolicLink(atPath: destination.path) {
      let url = target.hasPrefix("/") ? URL(fileURLWithPath: target)
        : destination.deletingLastPathComponent().appendingPathComponent(target)
      return url.standardizedFileURL == source.standardizedFileURL ? .installed : .conflict
    }
    do {
      _ = try files.attributesOfItem(atPath: destination.path)
      return .conflict
    } catch let error as NSError {
      if error.domain == NSCocoaErrorDomain
        && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
      {
        return .missing
      }
      return .unavailable("Could not inspect the command location. Check its permissions.")
    }
  }

  /// Only an explicit Settings/menu action calls this. A second click cannot open another prompt.
  func install() async {
    guard !isInstalling else { return }
    refresh()
    guard status.canInstall else { return }
    failure = nil
    isInstalling = true
    do {
      try await perform(source)
      status = Self.inspect(source: source, destination: destination)
      if status != .installed {
        failure = "The command was not installed at the expected location. No existing command was replaced."
      }
    } catch {
      status = Self.inspect(source: source, destination: destination)
      failure = status == .installed ? nil : error.localizedDescription
    }
    isInstalling = false
  }

  /// Run the bundled CLI unprivileged. Its --system installer authorizes a fixed OS filesystem
  /// script if needed; it never executes the bundled CLI as administrator.
  private static func runInstaller(_ executable: URL) async throws {
    UserDefaults.standard.set(true, forKey: AxoPreferenceKey.cliCommandSetupOffered)
    try await Task.detached(priority: .userInitiated) {
      let process = Process()
      let errors = Pipe()
      process.executableURL = executable
      process.arguments = ["cli", "install", "--system"]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = errors
      try process.run()
      // This command's controlled error output is short; no scripts or credentials are returned.
      process.waitUntilExit()
      let data = errors.fileHandleForReading.readDataToEndOfFile()
      guard process.terminationStatus == 0 else {
        let text = String(data: data.prefix(4096), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = text.flatMap { $0.isEmpty ? nil : $0 }
          ?? "Could not install the command. Try again or check the destination permissions."
        throw NSError(domain: "dev.leostera.axo.cli-install", code: Int(process.terminationStatus),
          userInfo: [NSLocalizedDescriptionKey: message])
      }
    }.value
  }
}
