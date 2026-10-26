import Foundation

/// A parsed GitHub owner/repository pair from the command-palette `gh:` / `github:` syntax.
struct GitHubRepository: Hashable, Sendable {
  let owner: String
  let name: String

  private init(owner: String, name: String) {
    self.owner = owner
    self.name = name
  }

  var slug: String { "\(owner)/\(name)" }
  var sshURL: String { "git@github.com:\(slug).git" }
  /// Parsed components are ASCII path segments, so this fixed GitHub URL is always constructible.
  var httpsURL: URL { URL(string: "https://github.com/\(slug).git")! }

  static func parsePaletteInput(_ input: String) -> GitHubRepository? {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let slug: Substring
    if input.hasPrefix("github:") {
      slug = input.dropFirst("github:".count)
    } else if input.hasPrefix("gh:") {
      slug = input.dropFirst("gh:".count)
    } else {
      return nil
    }

    let parts = slug.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2,
      let owner = parts.first.map(String.init),
      let name = parts.last.map(String.init),
      validOwner(owner), validRepositoryName(name)
    else { return nil }
    return GitHubRepository(owner: owner, name: name)
  }

  private static func validOwner(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 39,
      value.first != "-", value.last != "-"
    else { return false }
    return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
  }

  private static func validRepositoryName(_ value: String) -> Bool {
    guard !value.isEmpty, value != ".", value != "..", value.count <= 100 else { return false }
    return value.allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
    }
  }
}

enum GitHubWorkspaceCloneError: LocalizedError {
  case destinationAlreadyExists(URL)
  case cloneFailed(ssh: String, https: String)

  var errorDescription: String? {
    switch self {
    case .destinationAlreadyExists(let directory):
      "\(directory.path) already exists but is not a Git repository. Move it or rename it before cloning."
    case .cloneFailed(let ssh, let https):
      "SSH clone failed (\(ssh)); HTTPS fallback failed (\(https))."
    }
  }
}

private struct GitCloneAttemptError: LocalizedError {
  let details: String
  var errorDescription: String { details.isEmpty ? "Git could not clone this repository." : details }
}

enum GitHubWorkspaceCloner {
  static func clone(_ repository: GitHubRepository) async throws -> URL {
    let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("Developer/github.com", isDirectory: true)
    let ownerDirectory = root.appendingPathComponent(repository.owner, isDirectory: true)
    let destination = ownerDirectory.appendingPathComponent(repository.name, isDirectory: true)

    try FileManager.default.createDirectory(
      at: ownerDirectory, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: destination.path) {
      guard FileManager.default.fileExists(
        atPath: destination.appendingPathComponent(".git").path
      ) else {
        throw GitHubWorkspaceCloneError.destinationAlreadyExists(destination)
      }
      return destination
    }

    let staging = ownerDirectory.appendingPathComponent(
      ".axo-clone-\(UUID().uuidString)", isDirectory: true)
    let sshError: Error
    do {
      try await runGitClone(repository.sshURL, destination: staging, workingDirectory: ownerDirectory)
    } catch {
      sshError = error
      try? FileManager.default.removeItem(at: staging)
      do {
        try await runGitClone(
          repository.httpsURL.absoluteString, destination: staging, workingDirectory: ownerDirectory)
      } catch {
        try? FileManager.default.removeItem(at: staging)
        throw GitHubWorkspaceCloneError.cloneFailed(
          ssh: sshError.localizedDescription, https: error.localizedDescription)
      }
      return try installClone(staging, at: destination)
    }
    return try installClone(staging, at: destination)
  }

  private static func installClone(_ staging: URL, at destination: URL) throws -> URL {
    do {
      try FileManager.default.moveItem(at: staging, to: destination)
      return destination
    } catch {
      // Another Axo instance may have cloned the same repo while this clone was in progress.
      if FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path) {
        try? FileManager.default.removeItem(at: staging)
        return destination
      }
      try? FileManager.default.removeItem(at: staging)
      throw error
    }
  }

  private static func runGitClone(
    _ remote: String, destination: URL, workingDirectory: URL
  ) async throws {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let process = Process()
          let output = Pipe()
          process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
          process.arguments = ["clone", "--", remote, destination.path]
          process.currentDirectoryURL = workingDirectory
          process.standardInput = FileHandle.nullDevice
          var environment = ProcessInfo.processInfo.environment
          environment["GIT_TERMINAL_PROMPT"] = "0"
          environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=10"
          process.environment = environment
          process.standardOutput = output
          process.standardError = output
          try process.run()
          let outputData = output.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          guard process.terminationStatus == 0 else {
            let details = String(data: outputData, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw GitCloneAttemptError(details: details)
          }
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
