import Foundation

public struct ShellPaneAddParameters: Codable, Equatable, Sendable {
    public let target: WorkSessionTarget
    public let commandId: UUID
    public let profileId: String?
    public init(target: WorkSessionTarget, commandId: UUID, profileId: String? = nil) {
        self.target = target; self.commandId = commandId; self.profileId = profileId
    }
}

public enum ShellPaneIntent: Decodable, Equatable, Sendable {
    case add(target: WorkSessionTarget, profileId: String?)
    case remove(target: WorkSessionTarget, paneId: UUID, runtime: TerminalRuntime?)
    private enum Keys: String, CodingKey { case operation, target, profileId, paneId, runtime }
    private enum Operation: String, Decodable { case addPane, removePane }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Keys.self)
        let target = try fields.decode(WorkSessionTarget.self, forKey: .target)
        switch try fields.decode(Operation.self, forKey: .operation) {
        case .addPane: self = .add(target: target, profileId: try fields.decodeIfPresent(String.self, forKey: .profileId))
        case .removePane: self = .remove(target: target, paneId: try fields.decode(UUID.self, forKey: .paneId), runtime: try fields.decodeIfPresent(TerminalRuntime.self, forKey: .runtime))
        }
    }
}

public enum ShellPaneRejection: String, Decodable, Equatable, Sendable {
    case invalidRequest = "invalid_request", staleHost = "stale_host", staleRuntime = "stale_runtime"
    case staleAttachment = "stale_attachment", notFound = "not_found", conflict, capacity
    case alreadyAttached = "already_attached", notRunning = "not_running", recoveryRequired = "recovery_required"
    case launchFailed = "launch_failed", storageFailed = "storage_failed", inputBlocked = "input_blocked"
    case invalidSize = "invalid_size", invalidTransition = "invalid_transition"
}
public enum ShellPaneDisposition: Decodable, Equatable, Sendable {
    case prepared, added, removed, rejected(ShellPaneRejection)
    private enum Keys: String, CodingKey { case kind, reason }
    private enum Kind: String, Decodable { case prepared, added, removed, rejected }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Keys.self)
        switch try fields.decode(Kind.self, forKey: .kind) {
        case .prepared: self = .prepared
        case .added: self = .added
        case .removed: self = .removed
        case .rejected: self = .rejected(try fields.decode(ShellPaneRejection.self, forKey: .reason))
        }
    }
}
public struct ShellPaneReceipt: Decodable, Equatable, Sendable {
    public let commandId: UUID
    public let intent: ShellPaneIntent
    public let paneId: UUID
    public let runtime: TerminalRuntime?
    public let disposition: ShellPaneDisposition
}
public struct ShellPaneAddResult: Decodable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let receipt: ShellPaneReceipt
    public let pane: ShellPaneRecord
}
