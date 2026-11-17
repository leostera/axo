import AxoProtocol

/// Explicit intent for a new chat, not a report that a running Pi already uses it.
public struct DraftModelChoice: Equatable, Sendable {
  public let model: PiModel
  public let thinkingLevel: ThinkingLevel

  public init?(model: PiModel, thinkingLevel: ThinkingLevel? = nil) {
    guard let level = thinkingLevel ?? model.thinkingLevels.first, model.thinkingLevels.contains(level) else { return nil }
    self.model = model
    self.thinkingLevel = level
  }

  public var runtime: PiRuntime {
    PiRuntime(model: PiModelRef(provider: model.provider, id: model.id, name: model.name), thinkingLevel: thinkingLevel)
  }
}
