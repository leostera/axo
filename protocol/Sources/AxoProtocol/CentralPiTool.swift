import Foundation

public struct CentralPiToolCursor: Equatable, Sendable {
    public let target: CentralPiBindingTarget
    public let readMode: CentralPiHistoryReadMode
    public let entryId: String
    public let toolCallId: String
    public let headDigest: String
    public let offset: Int
    var json: JSONValue { get throws {
        try .object(["target": target.json, "readMode": .string(readMode.rawValue), "entryId": .string(entryId), "toolCallId": .string(toolCallId), "headDigest": .string(headDigest), "offset": .number(Double(offset))])
    } }
}
public struct CentralPiToolChunk: Equatable, Sendable {
    public let target: CentralPiBindingTarget
    public let readMode: CentralPiHistoryReadMode
    public let entryId: String
    public let toolCallId: String
    public let headDigest: String
    public let offset: Int
    public let text: String
    public let totalBytes: Int
    public let cursor: CentralPiToolCursor?
}
extension CentralJSON {
    func piTool(_ value: JSONValue, target: CentralPiBindingTarget, readMode: CentralPiHistoryReadMode, entryId: String, toolCallId: String, cursor prior: CentralPiToolCursor?, limit: Int) throws -> CentralPiToolChunk {
        let fields = try object(value, keys: ["target", "readMode", "entryId", "toolCallId", "headDigest", "offset", "text", "totalBytes", "cursor"])
        let actual = try piHistoryTarget(field(fields, "target"), expected: target)
        let digest = try historyDigest(field(fields, "headDigest"))
        let offset = try integer(field(fields, "offset")), total = try integer(field(fields, "totalBytes"))
        let text = try string(field(fields, "text")), nextOffset = offset + text.utf8.count
        guard try string(field(fields, "readMode")) == readMode.rawValue, try recordedID(field(fields, "entryId")) == entryId,
              try recordedID(field(fields, "toolCallId")) == toolCallId, offset == (prior?.offset ?? 0),
              (0...4 * 1024 * 1024).contains(total), offset >= 0, offset <= total,
              text.utf8.count <= limit, nextOffset <= total, prior.map({ $0.headDigest == digest }) ?? true else { throw failure }
        let nextValue = try field(fields, "cursor")
        let next: CentralPiToolCursor?
        if nextValue == .null {
            guard nextOffset == total else { throw failure }
            next = nil
        } else {
            let cursor = try object(nextValue, keys: ["target", "readMode", "entryId", "toolCallId", "headDigest", "offset"])
            _ = try piHistoryTarget(field(cursor, "target"), expected: target)
            guard try string(field(cursor, "readMode")) == readMode.rawValue, try recordedID(field(cursor, "entryId")) == entryId,
                  try recordedID(field(cursor, "toolCallId")) == toolCallId, try historyDigest(field(cursor, "headDigest")) == digest,
                  try integer(field(cursor, "offset")) == nextOffset, !text.isEmpty, nextOffset < total else { throw failure }
            next = CentralPiToolCursor(target: actual, readMode: readMode, entryId: entryId, toolCallId: toolCallId, headDigest: digest, offset: nextOffset)
        }
        return CentralPiToolChunk(target: actual, readMode: readMode, entryId: entryId, toolCallId: toolCallId, headDigest: digest, offset: offset, text: text, totalBytes: total, cursor: next)
    }
}
