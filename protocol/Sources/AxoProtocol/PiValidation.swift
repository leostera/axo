import Foundation

/// Semantic guards for Pi results. Codable shape checks alone do not bind replies to the captured runtime/chat.
public enum PiProtocolValidator {
    public static let maximumMessageBytes = 48 * 1_024
    public static let maximumHistoryEntryBytes = 48 * 1_024
    public static let maximumToolOutputBytes = 8_192

    public static func sessionStart(_ value: JSONValue, target: PiSessionTarget,
                                    commandId: UUID, persistence: PiPersistence) throws -> PiSessionStartResult {
        let method = AxoProtocol.Method.startSession
        guard let fields = object(value, keys: ["hostGeneration", "receipt", "chat", "admission"]),
              let generation = uuid(fields["hostGeneration"]), generation == target.hostGeneration,
              let receiptValue = fields["receipt"], validReceipt(receiptValue),
              let chatValue = fields["chat"], let admissionValue = string(fields["admission"]),
              let admission = PiAdmission(rawValue: admissionValue) else { throw invalid(method) }
        let receipt = try decode(receiptValue, as: PiCommandReceipt.self, method: method)
        guard receipt.commandId == commandId,
              receipt.intent == .start(target: target, persistence: persistence) else { throw invalid(method) }
        let chat: PiChatTarget?
        if chatValue.isNull {
            chat = nil
        } else {
            guard validChatTarget(chatValue, session: target),
                  let decoded = try? decode(chatValue, as: PiChatTarget.self, method: method),
                  decoded.hostGeneration == target.hostGeneration else { throw invalid(method) }
            chat = decoded
        }
        guard (admission == .notAdmitted) == (chat == nil),
              chat.map({ receipt.runtime == $0.runtime }) ?? true else { throw invalid(method) }
        return try decode(value, as: PiSessionStartResult.self, method: method)
    }

    public static func chatGet(_ value: JSONValue, target: PiChatTarget,
                               readMode: PiReadMode = .live) throws -> PiChatSnapshot {
        let method = AxoProtocol.Method.getChat
        guard let fields = object(value, keys: ["hostGeneration", "readMode", "target", "admission", "busy",
                                               "interactionId", "uiWaits", "question", "recovery", "leafId",
                                               "recentEntries", "viewingCount"]),
              let generation = uuid(fields["hostGeneration"]), generation == target.hostGeneration,
              string(fields["readMode"]) == readMode.rawValue,
              validChatTarget(fields["target"], expected: target),
              let admissionName = string(fields["admission"]), let admission = PiAdmission(rawValue: admissionName),
              case .bool(let busy)? = fields["busy"],
              let interaction = nullableUUID(fields["interactionId"]),
              let waits = integer(fields["uiWaits"]), (0...65_535).contains(waits),
              let questionValue = fields["question"], validQuestion(questionValue),
              case .bool(let recovery)? = fields["recovery"],
              let leaf = nullableString(fields["leafId"]), leaf.map(validRecordedID) ?? true,
              case .array(let entries)? = fields["recentEntries"], entries.count <= 10,
              entries.allSatisfy(validProjection), uniqueProjectionIDs(entries),
              let viewingCount = integer(fields["viewingCount"]), (0...16).contains(viewingCount)
        else { throw invalid(method) }
        if readMode == .live {
            guard admission == .ready else { throw invalid(method) }
        } else {
            guard admission == .stopped || admission == .failed,
                  !busy, interaction == nil, waits == 0, questionValue.isNull,
                  !recovery, viewingCount == 0 else { throw invalid(method) }
        }
        if !questionValue.isNull {
            guard let question = object(questionValue, keys: ["id", "interactionId", "title", "options"]),
                  uuid(question["interactionId"]) == interaction else { throw invalid(method) }
        }
        return try decode(value, as: PiChatSnapshot.self, method: method)
    }

    public static func chatHistory(_ value: JSONValue, target: PiChatTarget,
                                   readMode: PiReadMode = .live, limit: Int = 50,
                                   cursor: PiHistoryCursor? = nil) throws -> PiChatHistoryResult {
        let method = AxoProtocol.Method.getChatHistory
        guard (1...50).contains(limit), cursor.map({ $0.target == target && $0.readMode == readMode }) ?? true,
              let fields = object(value, keys: ["hostGeneration", "readMode", "target", "leafId", "entries", "next"]),
              let generation = uuid(fields["hostGeneration"]), generation == target.hostGeneration,
              string(fields["readMode"]) == readMode.rawValue,
              validChatTarget(fields["target"], expected: target),
              let leaf = nullableString(fields["leafId"]), leaf.map(validRecordedID) ?? true,
              cursor == nil || cursor?.leafId == leaf,
              case .array(let entries)? = fields["entries"], entries.count <= limit,
              entries.allSatisfy(validProjection), uniqueProjectionIDs(entries),
              let nextValue = fields["next"], validHistoryCursor(nextValue, target: target, readMode: readMode, leafId: leaf)
        else { throw invalid(method) }
        if let nextValue = fields["next"], !nextValue.isNull {
            guard case .object(let nextFields) = nextValue,
                  let after = string(nextFields["after"]),
                  case .array(let entries)? = fields["entries"],
                  let last = entries.last,
                  string(object(last, keys: projectionKeys)?["entryId"]) == after else { throw invalid(method) }
        }
        if let cursor, case .array(let entries)? = fields["entries"],
           entries.contains(where: { string(object($0, keys: projectionKeys)?["entryId"]) == cursor.after }) {
            throw invalid(method)
        }
        return try decode(value, as: PiChatHistoryResult.self, method: method)
    }

    public static func toolOutput(_ value: JSONValue, target: PiChatTarget, readMode: PiReadMode = .live,
                                  entryId: String, toolCallId: String, offset: Int,
                                  limit: Int = maximumToolOutputBytes) throws -> PiToolOutputResult {
        let method = AxoProtocol.Method.getToolOutput
        guard validRecordedID(entryId), validRecordedID(toolCallId),
              offset >= 0, offset <= 9_007_199_254_740_991,
              (1...maximumToolOutputBytes).contains(limit),
              let fields = object(value, keys: ["hostGeneration", "readMode", "target", "entryId", "toolCallId",
                                               "offset", "text", "nextOffset", "totalBytes"]),
              uuid(fields["hostGeneration"]) == target.hostGeneration,
              string(fields["readMode"]) == readMode.rawValue,
              validChatTarget(fields["target"], expected: target),
              string(fields["entryId"]) == entryId, string(fields["toolCallId"]) == toolCallId,
              integer(fields["offset"]) == offset,
              let text = string(fields["text"]), text.utf8.count <= limit,
              let nextOffset = nullableInteger(fields["nextOffset"]),
              let totalBytes = integer(fields["totalBytes"]), totalBytes >= 0,
              offset <= totalBytes, offset + text.utf8.count <= totalBytes else { throw invalid(method) }
        if let nextOffset {
            guard nextOffset == offset + text.utf8.count, nextOffset < totalBytes, !text.isEmpty else { throw invalid(method) }
        } else {
            guard offset + text.utf8.count == totalBytes else { throw invalid(method) }
        }
        return try decode(value, as: PiToolOutputResult.self, method: method)
    }

    public static func mutation(_ value: JSONValue, target: PiChatTarget, commandId: UUID,
                                operation: PiChatOperation, method: String) throws -> PiMutationResult {
        guard let fields = object(value, keys: ["hostGeneration", "receipt"]),
              uuid(fields["hostGeneration"]) == target.hostGeneration,
              let receiptValue = fields["receipt"], validReceipt(receiptValue) else { throw invalid(method) }
        let receipt = try decode(receiptValue, as: PiCommandReceipt.self, method: method)
        guard receipt.commandId == commandId,
              receipt.intent == .chat(target: target, operation: operation),
              receipt.runtime == nil || receipt.runtime == target.runtime else { throw invalid(method) }
        return try decode(value, as: PiMutationResult.self, method: method)
    }

    public static func validReceipt(_ value: JSONValue) -> Bool {
        guard let fields = object(value, keys: ["commandId", "intent", "disposition", "runtime"]),
              uuid(fields["commandId"]) != nil,
              validIntent(fields["intent"]), validDisposition(fields["disposition"]),
              let runtimeValue = fields["runtime"], runtimeValue.isNull || validRuntime(runtimeValue),
              let receipt = try? decode(value, as: PiCommandReceipt.self, method: "Pi receipt") else { return false }
        switch receipt.intent {
        case .start(let session, _):
            return receipt.runtime.map {
                $0.target.sessionId == session.sessionId && $0.target.paneId == session.paneId
            } ?? true
        case .chat(let chat, _):
            return receipt.runtime.map { $0 == chat.runtime } ?? true
        }
    }

    public static func validReceipt(_ value: JSONValue, target: MachineTarget) -> Bool {
        guard validReceipt(value),
              let receipt = try? decode(value, as: PiCommandReceipt.self, method: "Pi receipt") else { return false }
        switch receipt.intent {
        case .start(let session, _):
            return session.machineId == target.machineId && session.hostGeneration == target.hostGeneration
        case .chat(let chat, _):
            return chat.machineId == target.machineId && chat.hostGeneration == target.hostGeneration
        }
    }

    public static func validMessageText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
            && text.utf8.count <= maximumMessageBytes
    }

    private static let projectionKeys: Set<String> = ["entryId", "parentId", "timestamp", "kind", "role", "text",
                                                      "truncated", "toolCallId", "toolName", "toolCalls"]

    private static func validIntent(_ value: JSONValue?) -> Bool {
        guard case .object(let fields)? = value, let kind = string(fields["kind"]) else { return false }
        switch kind {
        case "start":
            guard Set(fields.keys) == ["kind", "target", "persistence"],
                  validSessionTarget(fields["target"]), validPersistence(fields["persistence"]) else { return false }
            return true
        case "chat":
            guard Set(fields.keys) == ["kind", "target", "operation"], validChatTarget(fields["target"]),
                  let operation = string(fields["operation"]) else { return false }
            return PiChatOperation(rawValue: operation) != nil
        default: return false
        }
    }

    private static func validDisposition(_ value: JSONValue?) -> Bool {
        guard case .object(let fields)? = value, let kind = string(fields["kind"]) else { return false }
        switch kind {
        case "prepared", "dispatched": return Set(fields.keys) == ["kind"]
        case "rejected": return Set(fields.keys) == ["kind", "code"] && integer(fields["code"]) != nil
        default: return false
        }
    }

    private static func validPersistence(_ value: JSONValue?) -> Bool {
        guard case .object(let fields)? = value, let kind = string(fields["kind"]) else { return false }
        switch kind {
        case "fresh": return Set(fields.keys) == ["kind"]
        case "resume":
            return Set(fields.keys) == ["kind", "chatId", "previousRuntime"]
                && uuid(fields["chatId"]) != nil && validRuntime(fields["previousRuntime"])
        default: return false
        }
    }

    private static func validSessionTarget(_ value: JSONValue?) -> Bool {
        guard let fields = object(value, keys: ["machineId", "hostGeneration", "workspaceId", "sessionId", "paneId"]) else { return false }
        return fields.allSatisfy { key, value in
            key == "workspaceId" ? value.isNull || uuid(value) != nil : uuid(value) != nil
        }
    }

    private static func validChatTarget(_ value: JSONValue?, session: PiSessionTarget? = nil) -> Bool {
        guard let fields = object(value, keys: ["machineId", "hostGeneration", "workspaceId", "sessionId", "paneId",
                                               "runtimeHostGeneration", "runtimeGeneration", "chatId"]),
              fields.allSatisfy({ key, value in
                  key == "workspaceId" ? value.isNull || uuid(value) != nil : uuid(value) != nil
              }) else { return false }
        guard let session else { return true }
        return uuid(fields["machineId"]) == session.machineId
            && uuid(fields["hostGeneration"]) == session.hostGeneration
            && uuid(fields["workspaceId"]) == session.workspaceId
            && uuid(fields["sessionId"]) == session.sessionId
            && uuid(fields["paneId"]) == session.paneId
    }

    private static func validChatTarget(_ value: JSONValue?, expected: PiChatTarget) -> Bool {
        guard let value, validChatTarget(value),
              let decoded = try? decode(value, as: PiChatTarget.self, method: "Pi target") else { return false }
        return decoded == expected
    }

    private static func validRuntime(_ value: JSONValue?) -> Bool {
        guard let fields = object(value, keys: ["host_generation", "target", "runtime_generation"]),
              uuid(fields["host_generation"]) != nil, uuid(fields["runtime_generation"]) != nil,
              let target = object(fields["target"], keys: ["session_id", "pane_id"]),
              uuid(target["session_id"]) != nil, uuid(target["pane_id"]) != nil else { return false }
        return true
    }

    private static func validQuestion(_ value: JSONValue) -> Bool {
        if value.isNull { return true }
        guard let fields = object(value, keys: ["id", "interactionId", "title", "options"]),
              uuid(fields["id"]) != nil, uuid(fields["interactionId"]) != nil,
              let title = string(fields["title"]), (1...2_000).contains(title.utf16.count),
              case .array(let options)? = fields["options"], (2...8).contains(options.count) else { return false }
        var ids = Set<UUID>()
        for option in options {
            guard let record = object(option, keys: ["id", "label"]), let id = uuid(record["id"]), ids.insert(id).inserted,
                  let label = string(record["label"]), (1...500).contains(label.utf16.count) else { return false }
        }
        return true
    }

    private static func validProjection(_ value: JSONValue) -> Bool {
        guard let fields = object(value, keys: projectionKeys),
              let id = string(fields["entryId"]), validRecordedID(id),
              let parent = nullableString(fields["parentId"]), parent.map(validRecordedID) ?? true,
              let timestamp = string(fields["timestamp"]), timestamp.utf8.count <= 128,
              let kind = string(fields["kind"]), (1...128).contains(kind.utf8.count),
              let role = nullableString(fields["role"]), role.map({ $0.utf8.count <= 64 }) ?? true,
              let text = string(fields["text"]), text.utf8.count <= 2_048,
              case .bool? = fields["truncated"],
              let toolCallId = nullableString(fields["toolCallId"]), toolCallId.map(validRecordedID) ?? true,
              let toolName = nullableString(fields["toolName"]), toolName.map(validRecordedID) ?? true,
              case .array(let calls)? = fields["toolCalls"], calls.count <= 32 else { return false }
        return calls.allSatisfy { call in
            guard let value = object(call, keys: ["id", "name"]),
                  let callId = string(value["id"]), validRecordedID(callId),
                  let name = string(value["name"]) else { return false }
            return validRecordedID(name)
        }
    }

    private static func uniqueProjectionIDs(_ values: [JSONValue]) -> Bool {
        var seen = Set<String>()
        return values.allSatisfy { value in
            guard let fields = object(value, keys: projectionKeys), let id = string(fields["entryId"]) else { return false }
            return seen.insert(id).inserted
        }
    }

    private static func validHistoryCursor(_ value: JSONValue, target: PiChatTarget,
                                           readMode: PiReadMode, leafId: String?) -> Bool {
        if value.isNull { return true }
        guard let fields = object(value, keys: ["target", "readMode", "leafId", "after"]),
              validChatTarget(fields["target"], expected: target), string(fields["readMode"]) == readMode.rawValue,
              nullableString(fields["leafId"]) == leafId,
              let after = string(fields["after"]), validRecordedID(after) else { return false }
        return true
    }

    private static func validRecordedID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func object(_ value: JSONValue?, keys: Set<String>) -> [String: JSONValue]? {
        guard case .object(let fields)? = value, Set(fields.keys) == keys else { return nil }
        return fields
    }

    private static func uuid(_ value: JSONValue?) -> UUID? {
        guard case .string(let raw)? = value else { return nil }
        return UUID(uuidString: raw)
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    private static func nullableString(_ value: JSONValue?) -> String?? {
        guard let value else { return nil }
        if value.isNull { return .some(nil) }
        guard case .string(let string) = value else { return nil }
        return .some(string)
    }

    private static func nullableUUID(_ value: JSONValue?) -> UUID?? {
        guard let value else { return nil }
        if value.isNull { return .some(nil) }
        guard let result = uuid(value) else { return nil }
        return .some(result)
    }

    private static func nullableInteger(_ value: JSONValue?) -> Int?? {
        guard let value else { return nil }
        if value.isNull { return .some(nil) }
        guard let result = integer(value) else { return nil }
        return .some(result)
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value, number.isFinite,
              number.rounded(.towardZero) == number, abs(number) <= 9_007_199_254_740_991 else { return nil }
        return Int(number)
    }

    private static func invalid(_ method: String) -> AxoProtocolValidationError { .invalidResult(method: method) }

    private static func decode<T: Decodable>(_ value: JSONValue, as type: T.Type, method: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)) }
        catch { throw invalid(method) }
    }
}

private extension JSONValue {
    var isNull: Bool { if case .null = self { return true }; return false }
}
