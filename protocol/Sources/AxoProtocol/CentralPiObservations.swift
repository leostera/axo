import Foundation

/// Minted only by the central result parser. The exact admitted identity is not
/// a launch capability; a stopped target does not authorize reading its file.
public struct CentralPiBindingTarget: Equatable, Sendable {
    public let source: CentralSource
    public let workspaceId: UUID?
    public let sessionId: UUID
    public let paneId: UUID
    public let runtime: TerminalRuntime
    public let chatId: UUID
    var json: JSONValue { get throws {
        let encodedRuntime = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(runtime))
        return .object(["machineId": .id(source.machine.machineId), "hostGeneration": .id(source.machine.hostGeneration), "storeGeneration": .id(source.storeGeneration), "workspaceId": .nullableID(workspaceId), "sessionId": .id(sessionId), "paneId": .id(paneId), "runtime": encodedRuntime, "chatId": .id(chatId)])
    } }
}
public struct CentralPiQuestionOption: Equatable, Sendable {
    public let id: UUID
    public let label: String
}
public struct CentralPiQuestion: Equatable, Sendable {
    public let id: UUID
    public let interactionId: UUID
    public let title: String
    public let options: [CentralPiQuestionOption]
}
public struct CentralPiLiveState: Equatable, Sendable {
    public let title: String?
    public let leafId: String?
    public let busy: Bool
    public let interactionId: UUID?
    public let uiWaits: Int
    public let question: CentralPiQuestion?
    public let pending: Bool
    public let recovery: Bool
}
public enum CentralPiObservation: Equatable, Sendable {
    /// No committed admission. This includes unfinished admission and is never
    /// evidence that a new conversation/writer may safely replace an attempt.
    case notAdmitted
    case live(target: CentralPiBindingTarget, state: CentralPiLiveState)
    /// Exact completion proof, not PID absence or a control-socket failure.
    case stopped(target: CentralPiBindingTarget)
}

extension CentralJSON {
    func piObservation(_ value: JSONValue, source: CentralSource, workspaceId: UUID?, sessionId: UUID) throws -> CentralPiObservation {
        guard case .object(let rawFields) = value else { throw failure }
        let kind = try string(field(rawFields, "kind"))
        if kind == "notAdmitted" {
            _ = try object(value, keys: ["kind"])
            return .notAdmitted
        }
        guard kind == "live" || kind == "stopped" else { throw failure }
        let fields = try object(value, keys: kind == "live" ? ["kind", "target", "state"] : ["kind", "target"])
        let target = try piBinding(field(fields, "target"), source: source, workspaceId: workspaceId, sessionId: sessionId)
        if kind == "stopped" { return .stopped(target: target) }
        guard target.runtime.hostGeneration == source.machine.hostGeneration else { throw failure }
        return try .live(target: target, state: piState(field(fields, "state")))
    }
    func piBinding(_ value: JSONValue, source: CentralSource, workspaceId: UUID?, sessionId: UUID) throws -> CentralPiBindingTarget {
        let fields = try object(value, keys: ["machineId", "hostGeneration", "storeGeneration", "workspaceId", "sessionId", "paneId", "runtime", "chatId"])
        let machine = try MachineTarget(machineId: id(field(fields, "machineId")), hostGeneration: id(field(fields, "hostGeneration")))
        let actual = try CentralSource(machine: machine, storeGeneration: id(field(fields, "storeGeneration")))
        let workspace = try optionalID(field(fields, "workspaceId")), session = try id(field(fields, "sessionId")), pane = try id(field(fields, "paneId"))
        let runtime = try runtime(field(fields, "runtime")), chat = try id(field(fields, "chatId"))
        guard actual == source, workspace == workspaceId, session == sessionId,
              runtime.target.sessionId == session, runtime.target.paneId == pane else { throw failure }
        return CentralPiBindingTarget(source: source, workspaceId: workspace, sessionId: session, paneId: pane, runtime: runtime, chatId: chat)
    }
    private func piState(_ value: JSONValue) throws -> CentralPiLiveState {
        let fields = try object(value, keys: ["title", "leafId", "busy", "interactionId", "uiWaits", "question", "pending", "recovery"])
        let titleValue = try field(fields, "title"), leafValue = try field(fields, "leafId")
        let title = titleValue == .null ? nil : try string(titleValue), leaf = leafValue == .null ? nil : try string(leafValue)
        guard title.map(validTitle) ?? true, leaf.map(validLeaf) ?? true else { throw failure }
        let interaction = try optionalID(field(fields, "interactionId")), waits = try integer(field(fields, "uiWaits"))
        guard (0...65535).contains(waits) else { throw failure }
        let questionValue = try field(fields, "question")
        let question = questionValue == .null ? nil : try piQuestion(questionValue)
        if let question { guard waits > 0, question.interactionId == interaction else { throw failure } }
        return try CentralPiLiveState(title: title, leafId: leaf, busy: boolean(field(fields, "busy")), interactionId: interaction, uiWaits: waits, question: question, pending: boolean(field(fields, "pending")), recovery: boolean(field(fields, "recovery")))
    }
    private func validTitle(_ title: String) -> Bool {
        !title.isEmpty && title.utf16.count <= 80 &&
        title.trimmingCharacters(in: .whitespacesAndNewlines) == title &&
        !title.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
    private func validLeaf(_ leaf: String) -> Bool {
        !leaf.isEmpty && leaf.utf8.count <= 128 &&
        !leaf.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
    private func piQuestion(_ value: JSONValue) throws -> CentralPiQuestion {
        let fields = try object(value, keys: ["id", "interactionId", "title", "options"])
        let title = try questionText(field(fields, "title"), maximum: 2000)
        let options = try array(field(fields, "options"), maximum: 8, minimum: 2).map { value in
            let option = try object(value, keys: ["id", "label"])
            return try CentralPiQuestionOption(id: id(field(option, "id")), label: questionText(field(option, "label"), maximum: 500))
        }
        guard Set(options.map(\.id)).count == options.count else { throw failure }
        return try CentralPiQuestion(id: id(field(fields, "id")), interactionId: id(field(fields, "interactionId")), title: title, options: options)
    }
    private func questionText(_ value: JSONValue, maximum: Int) throws -> String {
        let text = try string(value)
        guard !text.isEmpty, text.utf16.count <= maximum, !text.utf8.contains(0) else { throw failure }
        return text
    }
}
