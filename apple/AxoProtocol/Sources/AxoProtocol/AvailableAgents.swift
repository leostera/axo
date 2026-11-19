import Foundation

/// Runnable agents reported by the selected host; no executable paths cross the relay.
public struct AvailableAgents: Codable, Equatable, Sendable {
  public let agents: [CodingAgent]
  public init(agents: [CodingAgent]) { self.agents = agents }
}

/// The local daemon includes diagnostics; clients need only the runnable entries.
public struct LocalAgentCatalog: Decodable, Sendable {
  public struct Entry: Decodable, Sendable {
    public let agent: CodingAgent
    public let installed: Bool
  }
  public let agents: [Entry]
}
