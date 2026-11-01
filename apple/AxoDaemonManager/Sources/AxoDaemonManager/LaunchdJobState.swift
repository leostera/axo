import Foundation

/// What `launchctl print` says about a job in the user's GUI domain.
struct LaunchdJobState: Equatable, CustomStringConvertible {
  /// The job is loaded.
  var isLoaded: Bool
  /// It has a running process.
  var isRunning: Bool
  /// Its last exit code; `nil` when it has never exited.
  var lastExitCode: Int?

  /// Loaded, not running, and its last run failed: launchd is retrying a job it cannot start
  /// (a refused signature, a bundle that is gone), and waiting for it will not help.
  var isFailingToRun: Bool {
    isLoaded && !isRunning && (lastExitCode ?? 0) != 0
  }

  var description: String {
    guard isLoaded else { return "not_loaded" }
    if isRunning { return "running" }
    return "exited_\(lastExitCode.map(String.init) ?? "never")"
  }

  /// Parses `launchctl print gui/<uid>/<label>`; `nil` output means it is not loaded.
  static func parse(_ output: String?) -> LaunchdJobState {
    guard let output else { return LaunchdJobState(isLoaded: false, isRunning: false) }
    var isRunning = false
    var lastExitCode: Int?
    // Only the job's own top-level lines (one tab deep): nested blocks repeat keys like `state`.
    for line in output.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
      let field = line.trimmingCharacters(in: .whitespaces)
      if field.hasPrefix("pid = ") {
        isRunning = true
      } else if field.hasPrefix("last exit code = ") {
        let value = field.dropFirst("last exit code = ".count)
        lastExitCode = Int(value.prefix { $0 == "-" || $0.isNumber })
      }
    }
    return LaunchdJobState(isLoaded: true, isRunning: isRunning, lastExitCode: lastExitCode)
  }

  static func read(label: String) async -> LaunchdJobState {
    let target = "gui/\(getuid())/\(label)"
    let output: String? = await Task.detached(priority: .userInitiated) {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      process.arguments = ["print", target]
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      guard (try? process.run()) != nil else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      return String(decoding: data, as: UTF8.self)
    }.value
    return parse(output)
  }
}
