import AxoDaemonManager
import Foundation

/// Advisory text from the exact public commit in the captured release. It never authorizes an
/// install, changes latest.json, or supplies executable content to the signature verifier.
enum AppUpdateReleaseNotes {
  static let maximumBytes = 128 * 1024
  static let maximumSectionBytes = 24 * 1024

  static func section(in changelog: String, version: String) -> String? {
    guard changelog.utf8.count <= maximumBytes else { return nil }
    let lines = changelog.components(separatedBy: "\n")
    let heading = "## \(version)"
    guard let start = lines.firstIndex(where: { $0 == heading || $0.hasPrefix(heading + " ") }) else { return nil }
    let tail = lines.dropFirst(start + 1)
    let body = tail.prefix(while: { !$0.hasPrefix("## ") }).joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty, body.utf8.count <= maximumSectionBytes,
      body.components(separatedBy: "\n").count <= 256 else { return nil }
    return body
  }

  static func fetch(_ release: PublishedBuild) async throws -> String? {
    let url = URL(string: "https://raw.githubusercontent.com/leostera/axo/\(release.commit)/CHANGELOG.md")!
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 10
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.setValue("text/plain", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      response.expectedContentLength <= Int64(maximumBytes) else { return nil }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < maximumBytes else { return nil }
      data.append(byte)
    }
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    return section(in: text, version: release.version)
  }
}
