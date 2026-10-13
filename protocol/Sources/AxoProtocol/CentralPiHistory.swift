import Foundation

public enum CentralPiHistoryReadMode: String, Sendable { case live, stopped }
public enum CentralPiHistoryCollection: String, Sendable { case branch, entries }
/// Only a parsed continuation can be submitted. Bound to one source/runtime/chat,
/// collection and exact canonical head, not a caller-selected numeric offset.
public struct CentralPiHistoryCursor: Equatable, Sendable {
    public let target: CentralPiBindingTarget
    public let readMode: CentralPiHistoryReadMode
    public let collection: CentralPiHistoryCollection
    public let headDigest: String
    public let after: String
    var json: JSONValue { get throws {
        try .object(["target": target.json, "readMode": .string(readMode.rawValue), "collection": .string(collection.rawValue), "headDigest": .string(headDigest), "after": .string(after)])
    } }
}
public struct CentralPiHistoryPage: Equatable, Sendable {
    public let target: CentralPiBindingTarget
    public let readMode: CentralPiHistoryReadMode
    public let collection: CentralPiHistoryCollection
    public let headDigest: String
    public let leafId: String?
    public let entries: [CentralPiCanonicalProjection]
    public let cursor: CentralPiHistoryCursor?
}
extension CentralJSON {
    func piHistory(_ value: JSONValue, target: CentralPiBindingTarget, readMode: CentralPiHistoryReadMode, collection: CentralPiHistoryCollection, cursor prior: CentralPiHistoryCursor?, limit: Int) throws -> CentralPiHistoryPage {
        let fields = try object(value, keys: ["target", "readMode", "collection", "headDigest", "leafId", "entries", "cursor"])
        guard try string(field(fields, "readMode")) == readMode.rawValue, try string(field(fields, "collection")) == collection.rawValue else { throw failure }
        let actual = try piHistoryTarget(field(fields, "target"), expected: target)
        let digest = try historyDigest(field(fields, "headDigest"))
        let leafValue = try field(fields, "leafId"), leaf = leafValue == .null ? nil : try recordedID(leafValue)
        let entries = try array(field(fields, "entries"), maximum: limit).map(canonicalProjection)
        guard Set(entries.map(\.entryId)).count == entries.count, prior.map({ $0.headDigest == digest }) ?? true else { throw failure }
        if let prior { guard !entries.contains(where: { $0.entryId == prior.after }) else { throw failure } }
        let nextValue = try field(fields, "cursor")
        let next: CentralPiHistoryCursor?
        if nextValue == .null { next = nil } else {
            let continuation = try object(nextValue, keys: ["target", "readMode", "collection", "headDigest", "after"])
            _ = try piHistoryTarget(field(continuation, "target"), expected: target)
            let after = try recordedID(field(continuation, "after"))
            guard try string(field(continuation, "readMode")) == readMode.rawValue, try string(field(continuation, "collection")) == collection.rawValue,
                  try historyDigest(field(continuation, "headDigest")) == digest, after == entries.last?.entryId else { throw failure }
            next = CentralPiHistoryCursor(target: actual, readMode: readMode, collection: collection, headDigest: digest, after: after)
        }
        return CentralPiHistoryPage(target: actual, readMode: readMode, collection: collection, headDigest: digest, leafId: leaf, entries: entries, cursor: next)
    }
    func piHistoryTarget(_ value: JSONValue, expected: CentralPiBindingTarget) throws -> CentralPiBindingTarget {
        let actual = try piBinding(value, source: expected.source, workspaceId: expected.workspaceId, sessionId: expected.sessionId)
        guard actual == expected else { throw failure }
        return actual
    }
    func historyDigest(_ value: JSONValue) throws -> String {
        let digest = try string(value)
        guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw failure }
        return digest
    }
    func recordedID(_ value: JSONValue) throws -> String {
        let id = try string(value)
        guard !id.isEmpty, id.utf8.count <= 128, !id.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw failure }
        return id
    }
    private func canonicalProjection(_ value: JSONValue) throws -> CentralPiCanonicalProjection {
        let fields = try object(value, keys: ["entryId", "parentId", "timestamp", "kind", "role", "text", "truncated", "toolCallId", "toolName", "toolCalls"])
        _ = try recordedID(field(fields, "entryId")); _ = try recordedID(field(fields, "kind"))
        for key in ["parentId", "toolCallId", "toolName"] { let value = try field(fields, key); if value != .null { _ = try recordedID(value) } }
        guard try string(field(fields, "timestamp")).utf8.count <= 128, try string(field(fields, "text")).utf8.count <= 2048 else { throw failure }
        let role = try field(fields, "role")
        if role != .null { let text = try recordedID(role); guard text.utf8.count <= 64 else { throw failure } }
        _ = try boolean(field(fields, "truncated"))
        for call in try array(field(fields, "toolCalls"), maximum: 32) {
            let fields = try object(call, keys: ["id", "name"]); _ = try recordedID(field(fields, "id")); _ = try recordedID(field(fields, "name"))
        }
        return try JSONDecoder().decode(CentralPiCanonicalProjection.self, from: JSONEncoder().encode(value))
    }
}
