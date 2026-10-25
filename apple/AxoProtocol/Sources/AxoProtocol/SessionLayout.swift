import Foundation

public enum SessionSplitDirection: String, Codable, Sendable {
  case right
  case down
}

public indirect enum SessionLayout: Codable, Equatable, Sendable {
  case pane(shellID: ShellID)
  case split(
    id: UUID,
    direction: SessionSplitDirection,
    ratio: Double,
    first: SessionLayout,
    second: SessionLayout
  )

  private enum CodingKeys: String, CodingKey {
    case kind
    case shellID = "shellId"
    case id
    case direction
    case ratio
    case first
    case second
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "pane":
      self = .pane(shellID: try container.decode(ShellID.self, forKey: .shellID))
    case "split":
      self = .split(
        id: try container.decode(UUID.self, forKey: .id),
        direction: try container.decode(SessionSplitDirection.self, forKey: .direction),
        ratio: try container.decode(Double.self, forKey: .ratio),
        first: try container.decode(SessionLayout.self, forKey: .first),
        second: try container.decode(SessionLayout.self, forKey: .second)
      )
    case let kind:
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Unknown session layout node kind: \(kind)"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pane(let shellID):
      try container.encode("pane", forKey: .kind)
      try container.encode(shellID, forKey: .shellID)
    case .split(let id, let direction, let ratio, let first, let second):
      try container.encode("split", forKey: .kind)
      try container.encode(id, forKey: .id)
      try container.encode(direction, forKey: .direction)
      try container.encode(ratio, forKey: .ratio)
      try container.encode(first, forKey: .first)
      try container.encode(second, forKey: .second)
    }
  }
}
