import Foundation

/// Separate the decision from supporting detail without summarizing away approval scope.
public struct ApprovalCopy: Equatable, Sendable {
  public let headline: String
  public let detail: String?
  public let requiresReview: Bool

  public init(_ message: String) {
    requiresReview = message.count > 140
    guard let delimiter = message.firstIndex(where: { $0 == "?" || $0 == "\n" }) else {
      headline = message
      detail = nil
      return
    }
    let end = message.index(after: delimiter)
    headline = String(message[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    let remaining = String(message[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
    detail = remaining.isEmpty ? nil : remaining
  }
}
