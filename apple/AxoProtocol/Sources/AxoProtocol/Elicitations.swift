import Foundation

/// What an agent on a Mac asks its person (RFD0029). Only the person answers, from a signed-in
/// client: the agent waits for Yes or No.
public struct Elicitation: Decodable, Equatable, Hashable, Sendable, Identifiable {
  public enum Kind: String, Decodable, Sendable {
    case confirm
  }

  /// A lowercase UUID.
  public let id: String
  public let sessionId: SessionID
  public let kind: Kind
  /// The agent's words, shown as the agent's.
  public let message: String
  /// Unix milliseconds.
  public let createdAt: Int64
  public let expiresAt: Int64

  public init(id: String, sessionId: SessionID, kind: Kind = .confirm, message: String, createdAt: Int64, expiresAt: Int64) {
    self.id = id
    self.sessionId = sessionId
    self.kind = kind
    self.message = message
    self.createdAt = createdAt
    self.expiresAt = expiresAt
  }
}

/// What a person may answer.
public enum ElicitationAnswer: String, Codable, Sendable {
  case accept
  case decline
}

/// How an elicitation ended: the person's answer, or `cancel` when nobody answered in time, the
/// asker went away, or its Mac went offline.
public enum ElicitationAction: String, Decodable, Sendable {
  case accept
  case decline
  case cancel
}

/// `ELICITATION_ERRORS` of `@axo/protocol`.
public enum ElicitationError {
  /// Answered already, expired, or never asked.
  public static let notPending = -32011
}
