import Foundation

/// What an agent on a Mac asks its person (RFD0029). Only the person answers, from a signed-in
/// client: the agent waits for Yes or No.
public struct Elicitation: Decodable, Equatable, Hashable, Sendable, Identifiable {
  public enum Kind: String, Decodable, Sendable {
    case confirm
    /// Values the agent must not see, for a form on the Mac (RFD0029): sealed to its key.
    case input
  }

  /// Who asks: the agent, in its own words, or Axo's computer-use gate, describing what it is about
  /// to do. axod lets only its own tools ask as one.
  public enum Asker: String, Decodable, Sendable {
    case agent
    case computerUse
  }

  /// A lowercase UUID.
  public let id: String
  public let sessionId: SessionID
  public let kind: Kind
  public let askedBy: Asker
  /// The asker's words, shown as theirs.
  public let message: String
  /// For `input`: the fields, where they go, and the key to seal them to.
  public let input: InputRequest?
  /// Unix milliseconds.
  public let createdAt: Int64
  public let expiresAt: Int64

  public init(
    id: String, sessionId: SessionID, kind: Kind = .confirm, askedBy: Asker = .agent, message: String, input: InputRequest? = nil,
    createdAt: Int64, expiresAt: Int64
  ) {
    self.id = id
    self.sessionId = sessionId
    self.kind = kind
    self.askedBy = askedBy
    self.message = message
    self.input = input
    self.createdAt = createdAt
    self.expiresAt = expiresAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, sessionId, kind, askedBy, message, input, createdAt, expiresAt
  }

  /// An older axod sends no `askedBy`: its questions are all the agent's.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    sessionId = try container.decode(SessionID.self, forKey: .sessionId)
    kind = try container.decode(Kind.self, forKey: .kind)
    askedBy = try container.decodeIfPresent(Asker.self, forKey: .askedBy) ?? .agent
    message = try container.decode(String.self, forKey: .message)
    input = try container.decodeIfPresent(InputRequest.self, forKey: .input)
    createdAt = try container.decode(Int64.self, forKey: .createdAt)
    expiresAt = try container.decode(Int64.self, forKey: .expiresAt)
  }
}

/// Where an input request's values go: all of it the Mac's own reading of the window.
public struct InputRequest: Decodable, Equatable, Hashable, Sendable {
  public struct Field: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Decodable, Sendable {
      case username, email, password, code, text
    }
    /// `f0`, `f1`, …: the key of its value.
    public let id: String
    public let label: String
    public let kind: Kind

    public init(id: String, label: String, kind: Kind) {
      self.id = id
      self.label = label
      self.kind = kind
    }
  }

  public let app: String
  public let window: String
  /// The page's origin, from the browser itself; nil outside a browser.
  public let origin: String?
  public let fields: [Field]
  public let submit: String?
  /// The Mac's input key: base64 of an uncompressed P-256 point.
  public let key: String

  public init(app: String, window: String, origin: String?, fields: [Field], submit: String? = nil, key: String) {
    self.app = app
    self.window = window
    self.origin = origin
    self.fields = fields
    self.submit = submit
    self.key = key
  }
}

/// Values sealed to a Mac's input key, as base64.
public struct SealedInput: Codable, Equatable, Sendable {
  public let enc: String
  public let ciphertext: String

  public init(enc: String, ciphertext: String) {
    self.enc = enc
    self.ciphertext = ciphertext
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
  /// Only the person answers: on a Mac, only Axo.app, by code signature.
  public static let notAPerson = -32012
  /// An input answer that is missing, did not open, or does not fit its fields; it still waits.
  public static let badInput = -32014
  /// Not signed by its device for this answer; it still waits.
  public static let badSignature = -32015
}

/// `axo.elicitation.list`: what waits for the person on this Mac, oldest first.
public struct PendingElicitations: Decodable, Sendable {
  public let elicitations: [Elicitation]
}

/// `axo.elicitation.resolve` on `axod.sock`, from Axo.app.
public struct LocalElicitationAnswer: Encodable, Sendable {
  public let elicitationId: String
  public let action: ElicitationAnswer
  /// An input request's values by field id: on this Mac's own socket, in the clear.
  public let values: [String: String]?

  public init(elicitationId: String, action: ElicitationAnswer, values: [String: String]? = nil) {
    self.elicitationId = elicitationId
    self.action = action
    self.values = values
  }
}

/// `axo.elicitation.resolve`'s result.
public struct ElicitationResolution: Decodable, Sendable {
  public let resolved: Bool
}
