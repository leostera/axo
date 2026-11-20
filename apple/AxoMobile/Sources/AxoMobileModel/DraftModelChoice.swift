import AxoProtocol

/// Explicit intent for a new chat, not a report that a running Pi already uses it.
public struct DraftModelChoice: Equatable, Sendable {
  public let model: PiModel
  public let thinkingLevel: ThinkingLevel?

  public init?(model: PiModel, thinkingLevel: ThinkingLevel? = nil) {
    if let thinkingLevel, !model.thinkingLevels.contains(thinkingLevel) { return nil }
    self.model = model
    self.thinkingLevel = thinkingLevel ?? model.thinkingLevels.first
  }

  public var runtime: PiRuntime {
    PiRuntime(model: PiModelRef(provider: model.provider, id: model.id, name: model.name), thinkingLevel: thinkingLevel)
  }
}
