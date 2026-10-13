import Foundation

public enum CentralPiAction: Equatable, Sendable {
    case send(text: String)
    case steer(interactionId: UUID, text: String)
    case cancel(interactionId: UUID)
    case answer(interactionId: UUID, questionId: UUID, optionId: UUID)
    var identifiers: [UUID] { switch self {
    case .send: return []
    case .steer(let interaction, _), .cancel(let interaction): return [interaction]
    case .answer(let interaction, let question, let option): return [interaction, question, option]
    } }
    var text: String? { switch self { case .send(let text), .steer(_, let text): return text; default: return nil } }
    var descriptor: CentralPiActionDescriptor { switch self {
    case .send: return .send
    case .steer(let interaction, _): return .steer(interactionId: interaction)
    case .cancel(let interaction): return .cancel(interactionId: interaction)
    case .answer(let interaction, let question, let option): return .answer(interactionId: interaction, questionId: question, optionId: option)
    } }
    var json: JSONValue {
        var fields = descriptor.fields
        if let text { fields["text"] = .string(text) }
        return .object(fields)
    }
}
public enum CentralPiActionDescriptor: Equatable, Sendable {
    case send
    case steer(interactionId: UUID)
    case cancel(interactionId: UUID)
    case answer(interactionId: UUID, questionId: UUID, optionId: UUID)
    var fields: [String: JSONValue] { switch self {
    case .send: return ["kind": .string("send")]
    case .steer(let id): return ["kind": .string("steer"), "interactionId": .id(id)]
    case .cancel(let id): return ["kind": .string("cancel"), "interactionId": .id(id)]
    case .answer(let interaction, let question, let option): return ["kind": .string("answer"), "interactionId": .id(interaction), "questionId": .id(question), "optionId": .id(option)]
    } }
}
/// Volatile caller capture, not a durable draft or replay queue. Only the bounded
/// factory mints it; reconciliation keeps the original host/runtime/chat frozen.
public struct CentralPiCommandCapture: Equatable, Sendable {
    public let target: CentralPiBindingTarget
    public let commandId: UUID
    public let expectedRevision: CentralRevision
    public let action: CentralPiAction
    var parameters: JSONValue { get throws {
        try .object(["target": target.json, "commandId": .id(commandId), "expectedRevision": .number(Double(expectedRevision.rawValue)), "action": action.json])
    } }
}
public enum CentralPiRejection: String, Sendable {
    case notReady, capacity, stale, busy, blocked, invalid, recoveryRequired, sourceChanged, stopping
}
public enum CentralPiDisposition: Equatable, Sendable {
    case unconfirmed, dispatched, outcomeUnknown, rejected(CentralPiRejection)
}
public struct CentralPiConfigurationCapture: Equatable, Sendable {
    public let paneRevision: CentralRevision
    public let sessionRevision: CentralRevision
    public let workspaceRevision: CentralRevision?
}
/// Bounded original metadata only. Dispatched means extension acknowledgement,
/// not execution, delivery, settlement or current readiness.
public struct CentralPiOriginal: Equatable, Sendable {
    public let target: CentralPiBindingTarget
    public let commandId: UUID
    public let expectedRevision: CentralRevision
    public let acceptedRevision: CentralRevision
    public let configuration: CentralPiConfigurationCapture
    public let action: CentralPiActionDescriptor
    public let disposition: CentralPiDisposition
}
extension CentralJSON {
    func piOriginal(_ value: JSONValue, capture: CentralPiCommandCapture, revision envelope: CentralRevision) throws -> CentralPiOriginal {
        let fields = try object(value, keys: ["target", "commandId", "expectedRevision", "acceptedRevision", "configuration", "action", "disposition"])
        let target = try piHistoryTarget(field(fields, "target"), expected: capture.target)
        let command = try id(field(fields, "commandId")), expected = try revision(field(fields, "expectedRevision")), accepted = try revision(field(fields, "acceptedRevision"))
        let action = try piActionDescriptor(field(fields, "action"))
        guard command == capture.commandId, expected == capture.expectedRevision, accepted.rawValue == expected.rawValue + 1, accepted <= envelope, action == capture.action.descriptor else { throw failure }
        let config = try object(field(fields, "configuration"), keys: ["paneRevision", "sessionRevision", "workspaceRevision"])
        let pane = try revision(field(config, "paneRevision")), session = try revision(field(config, "sessionRevision"))
        let workspaceValue = try field(config, "workspaceRevision"), workspace = workspaceValue == .null ? nil : try revision(workspaceValue)
        guard pane <= expected, session <= expected, workspace.map({ $0 <= expected }) ?? true, (workspace == nil) == (target.workspaceId == nil) else { throw failure }
        let rawDisposition = try field(fields, "disposition")
        guard case .object(let dispositionFields) = rawDisposition, let kindValue = dispositionFields["kind"] else { throw failure }
        let kind = try string(kindValue), disposition: CentralPiDisposition
        _ = try object(rawDisposition, keys: kind == "rejected" ? ["kind", "reason"] : ["kind"])
        switch kind {
        case "unconfirmed": disposition = .unconfirmed
        case "dispatched": disposition = .dispatched
        case "outcomeUnknown": disposition = .outcomeUnknown
        case "rejected":
            guard let reason = try CentralPiRejection(rawValue: string(field(dispositionFields, "reason"))) else { throw failure }
            disposition = .rejected(reason)
        default: throw failure
        }
        return CentralPiOriginal(target: target, commandId: command, expectedRevision: expected, acceptedRevision: accepted, configuration: .init(paneRevision: pane, sessionRevision: session, workspaceRevision: workspace), action: action, disposition: disposition)
    }
    private func piActionDescriptor(_ value: JSONValue) throws -> CentralPiActionDescriptor {
        guard case .object(let fields) = value, let kindValue = fields["kind"] else { throw failure }
        let kind = try string(kindValue)
        switch kind {
        case "send": _ = try object(value, keys: ["kind"]); return .send
        case "steer", "cancel":
            _ = try object(value, keys: ["kind", "interactionId"])
            let interaction = try id(field(fields, "interactionId"))
            return kind == "steer" ? .steer(interactionId: interaction) : .cancel(interactionId: interaction)
        case "answer":
            _ = try object(value, keys: ["kind", "interactionId", "questionId", "optionId"])
            return try .answer(interactionId: id(field(fields, "interactionId")), questionId: id(field(fields, "questionId")), optionId: id(field(fields, "optionId")))
        default: throw failure
        }
    }
}
