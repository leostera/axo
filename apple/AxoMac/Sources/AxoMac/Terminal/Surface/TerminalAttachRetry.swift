import AxoClient
import AxoProtocol

/// Initial-handshake failures have no Ghostty stream to signal another attach. Retry only
/// transient transport failures, with a finite budget; never restart Pi or replay input.
struct TerminalAttachRetry {
  static let delays: [Duration] = [.seconds(2), .seconds(4), .seconds(8), .seconds(8)]
  private var failures: [ShellID: Int] = [:]

  mutating func delay(after error: Error, for shellID: ShellID) -> Duration? {
    guard let error = error as? TerminalAttachmentError, error.isRetryable else { return nil }
    let count = failures[shellID, default: 0]
    guard count < Self.delays.count else { return nil }
    failures[shellID] = count + 1
    return Self.delays[count]
  }

  mutating func forget(_ shellID: ShellID) { failures[shellID] = nil }
}
