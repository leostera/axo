#if DEBUG && targetEnvironment(simulator)
import AxoClient
import AxoProtocol
import Foundation

/// Owned synthetic uploads for simulator tests; never connects to account assets.
actor PreviewAttachmentUploads {
  let mode: String?
  private var attempts: [String: Int] = [:]

  init(mode: String?) { self.mode = mode }

  func upload(_ data: Data, name: String, mimeType: String) async throws -> Attachment {
    attempts[name, default: 0] += 1
    if mode == "slow" { try await Task.sleep(for: .seconds(30)) }
    if mode == "retry", name == "first.png", attempts[name, default: 0] <= 3 {
      throw RelayError.unreachable("Fixture connection interrupted")
    }
    try await Task.sleep(for: .milliseconds(mode == "retry" ? 1_000 : 100))
    return Attachment(asset: "sha256:" + String(repeating: "ab", count: 32), name: name, mimeType: mimeType, size: data.count)
  }
}
#endif
