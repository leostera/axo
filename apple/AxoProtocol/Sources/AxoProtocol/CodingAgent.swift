import Foundation

/// The coding agent a Session runs, chosen when it is created and kept (RFD0072). The raw
/// values are the names axod and ATXF use.
public enum CodingAgent: String, Codable, Sendable, CaseIterable, Identifiable {
  case pi
  case codex
  case opencode
  case claudeCode = "claude-code"

  public var id: String { rawValue }

  /// The agent's name as its makers write it.
  public var displayName: String {
    switch self {
    case .pi: "Pi"
    case .codex: "Codex"
    case .opencode: "OpenCode"
    case .claudeCode: "Claude Code"
    }
  }
}
