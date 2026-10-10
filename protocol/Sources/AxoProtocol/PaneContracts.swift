import Foundation

public enum ShellPaneState: String, Decodable, Equatable, Sendable {
    case adding, open, failed, closing, removed
}

public enum ShellPaneKind: String, Decodable, Equatable, Sendable { case shell }

public struct ShellPaneRecord: Decodable, Equatable, Sendable, Identifiable {
    public var id: UUID { paneId }
    public let paneId: UUID
    public let kind: ShellPaneKind
    public let profileId: String
    public let state: ShellPaneState
    public let runtime: TerminalRuntime?
    public let terminal: TerminalSnapshot?
}
