/// The destination's read-only compatibility decision for the authenticated source snapshot.
public struct SessionForkPlan: Decodable, Equatable, Sendable {
  public enum Decision: Equatable, Sendable {
    case keep
    case choose([CodingAgent])
    case unavailable
  }

  public let sourceAgent: CodingAgent
  public let historyFormat: String
  public let decision: Decision

  private enum CodingKeys: String, CodingKey { case sourceAgent, historyFormat, decision }
  private enum DecisionKeys: String, CodingKey { case kind, agent, agents }
  private enum Kind: String, Decodable { case keep, choose, unavailable }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sourceAgent = try container.decode(CodingAgent.self, forKey: .sourceAgent)
    historyFormat = try container.decode(String.self, forKey: .historyFormat)
    guard !historyFormat.isEmpty else {
      throw DecodingError.dataCorruptedError(forKey: .historyFormat, in: container, debugDescription: "Missing history format")
    }
    let choice = try container.nestedContainer(keyedBy: DecisionKeys.self, forKey: .decision)
    switch try choice.decode(Kind.self, forKey: .kind) {
    case .keep:
      guard try choice.decode(CodingAgent.self, forKey: .agent) == sourceAgent else {
        throw DecodingError.dataCorruptedError(forKey: .agent, in: choice, debugDescription: "Keep must preserve the source harness")
      }
      decision = .keep
    case .choose:
      let agents = try choice.decode([CodingAgent].self, forKey: .agents)
      guard !agents.isEmpty, Set(agents).count == agents.count, !agents.contains(sourceAgent) else {
        throw DecodingError.dataCorruptedError(forKey: .agents, in: choice, debugDescription: "Expected distinct alternative harnesses")
      }
      decision = .choose(agents)
    case .unavailable:
      decision = .unavailable
    }
  }
}
