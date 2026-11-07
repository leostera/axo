import Foundation

// What a client sees of, and changes in, a Session's Pi (RFD0033): the model and thinking level
// it runs, the slash commands it takes from a client, and when a prompt sent while it works
// reaches it.

/// Pi's thinking levels, lowest first.
public enum ThinkingLevel: String, Codable, CaseIterable, Hashable, Sendable {
  case off, minimal, low, medium, high, xhigh, max

  /// As the message box shows it: "High", "Extra High".
  public var title: String {
    switch self {
    case .off: "Off"
    case .minimal: "Minimal"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra High"
    case .max: "Max"
    }
  }
}

/// A model as Pi's registry names it, with the name people read.
public struct PiModelRef: Codable, Hashable, Sendable {
  public let provider: String
  public let id: String
  public let name: String

  public init(provider: String, id: String, name: String) {
    self.provider = provider
    self.id = id
    self.name = name
  }
}

/// What a Session's Pi runs, once it has said.
public struct PiRuntime: Decodable, Equatable, Sendable {
  /// Nil when Pi has no model yet (no credentials anywhere).
  public let model: PiModelRef?
  /// Nil for a level this app does not know yet.
  public let thinkingLevel: ThinkingLevel?

  public init(model: PiModelRef?, thinkingLevel: ThinkingLevel?) {
    self.model = model
    self.thinkingLevel = thinkingLevel
  }

  private enum CodingKeys: String, CodingKey { case model, thinkingLevel }

  // Leniently: a newer Pi's level or a model this app can't read hides the label, not the Session.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    model = try? container.decodeIfPresent(PiModelRef.self, forKey: .model)
    thinkingLevel = try? container.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel)
  }

  /// "Opus 4.1 · High": what the message box shows. Nil when Pi has no model.
  public var label: String? {
    guard let model else { return nil }
    return [model.name, thinkingLevel?.title].compactMap { $0 }.joined(separator: " · ")
  }
}

/// A model the Session's Pi could switch to, with the thinking levels it supports.
public struct PiModel: Decodable, Hashable, Sendable, Identifiable {
  public let provider: String
  public let id: String
  public let name: String
  public let thinkingLevels: [ThinkingLevel]

  public init(provider: String, id: String, name: String, thinkingLevels: [ThinkingLevel]) {
    self.provider = provider
    self.id = id
    self.name = name
    self.thinkingLevels = thinkingLevels
  }

  private enum CodingKeys: String, CodingKey { case provider, id, name, thinkingLevels }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(String.self, forKey: .provider)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    // Levels this app doesn't know yet aren't offered.
    let levels = try container.decodeIfPresent([String].self, forKey: .thinkingLevels) ?? []
    thinkingLevels = levels.compactMap(ThinkingLevel.init(rawValue:))
  }

  public func isModel(_ ref: PiModelRef?) -> Bool { ref?.provider == provider && ref?.id == id }
}

/// A slash command a client's prompt can run in the Session's Pi.
public struct PiCommand: Decodable, Hashable, Sendable, Identifiable {
  public enum Source: String, Decodable, Sendable {
    case `extension`, prompt, skill
  }

  public let name: String
  public let description: String
  /// Nil for a kind this app does not know yet.
  public let source: Source?

  public var id: String { name }

  public init(name: String, description: String, source: Source?) {
    self.name = name
    self.description = description
    self.source = source
  }

  private enum CodingKeys: String, CodingKey { case name, description, source }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    source = try? container.decodeIfPresent(Source.self, forKey: .source)
  }
}

/// When a prompt sent while Pi works reaches it. Either way it is in the Session's log before the
/// Mac says it took it.
public enum PromptDelivery: String, Codable, Hashable, Sendable {
  /// After the turn Pi is working on, as the next one. The default.
  case followUp
  /// Within the turn Pi is working on, at its next step.
  case steer
}
