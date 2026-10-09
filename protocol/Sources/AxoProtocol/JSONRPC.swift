import Foundation

public enum RPCID: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            throw DecodingError.typeMismatch(
                RPCID.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "RPC IDs must be strings, safe finite numbers, or null.")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    fileprivate var isValid: Bool {
        switch self {
        case .string(let value): value.utf16.count <= 128
        case .number(let value): value.isFinite && abs(value) <= 9_007_199_254_740_991
        case .null: true
        }
    }
}

public struct RPCRequest: Codable, Equatable, Sendable {
    public let jsonrpc: String
    /// `nil` means notification; `.null` is a response-bearing request ID.
    public let id: RPCID?
    public let method: String
    public let params: JSONValue?

    public init(jsonrpc: String = "2.0", id: RPCID? = nil, method: String, params: JSONValue? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        id = container.contains(.id) ? try container.decode(RPCID.self, forKey: .id) : nil
        method = try container.decode(String.self, forKey: .method)
        params = container.contains(.params) ? try container.decode(JSONValue.self, forKey: .params) : nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        if let id { try container.encode(id, forKey: .id) }
        try container.encode(method, forKey: .method)
        if let params { try container.encode(params, forKey: .params) }
    }

    fileprivate var isValid: Bool {
        guard jsonrpc == "2.0", !method.isEmpty, method.utf16.count <= 128 else { return false }
        if let id, !id.isValid { return false }
        if let params {
            switch params {
            case .array, .object: break
            default: return false
            }
        }
        return true
    }
}

public struct RPCErrorBody: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        data = container.contains(.data) ? try container.decode(JSONValue.self, forKey: .data) : nil
        guard abs(Double(code)) <= 9_007_199_254_740_991, message.utf16.count <= 256,
              container.allKeys.allSatisfy({ [.code, .message, .data].contains($0) })
        else {
            throw DecodingError.dataCorruptedError(forKey: .code, in: container, debugDescription: "Invalid JSON-RPC error object.")
        }
    }
}

public struct RPCFailure: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: RPCID
    public let error: RPCErrorBody

    public init(id: RPCID = .null, code: Int, message: String) {
        self.jsonrpc = "2.0"
        self.id = id
        self.error = RPCErrorBody(code: code, message: message)
    }
}

public enum RPCResponse: Codable, Equatable, Sendable {
    case result(id: RPCID, value: JSONValue)
    case failure(id: RPCID, error: RPCErrorBody)

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .jsonrpc)
        let id = try container.decode(RPCID.self, forKey: .id)
        guard version == "2.0", id.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .jsonrpc, in: container, debugDescription: "Invalid JSON-RPC response envelope.")
        }
        let hasResult = container.contains(.result)
        let hasError = container.contains(.error)
        guard hasResult != hasError else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "A response must contain exactly one of result or error.")
        }
        guard container.allKeys.allSatisfy({ [.jsonrpc, .id, hasResult ? .result : .error].contains($0) }) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Unexpected response fields.")
        }
        if hasResult {
            self = .result(id: id, value: try container.decode(JSONValue.self, forKey: .result))
        } else {
            self = .failure(id: id, error: try container.decode(RPCErrorBody.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        switch self {
        case .result(let id, let value):
            try container.encode(id, forKey: .id)
            try container.encode(value, forKey: .result)
        case .failure(let id, let error):
            try container.encode(id, forKey: .id)
            try container.encode(error, forKey: .error)
        }
    }
}

public struct RPCProtocolError: Error, Equatable, Sendable, LocalizedError {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum DecodedRPCEntry: Equatable, Sendable {
    case request(RPCRequest)
    case invalid(RPCFailure)
}

public struct DecodedRPCMessage: Equatable, Sendable {
    public let isBatch: Bool
    public let entries: [DecodedRPCEntry]

    public init(isBatch: Bool, entries: [DecodedRPCEntry]) {
        self.isBatch = isBatch
        self.entries = entries
    }
}

/// The profile's bounded JSON-RPC 2.0 envelope decoder, shared by all transports.
public enum AxoProtocolCodec {
    public static let maximumFrameBytes = 65_536
    public static let maximumBatchCalls = 8

    public static func decode(_ raw: String) throws -> DecodedRPCMessage {
        guard raw.utf8.count <= maximumFrameBytes else {
            throw RPCProtocolError(code: -32600, message: "Frame limit")
        }

        let value: Any
        do {
            value = try JSONSerialization.jsonObject(
                with: Data(raw.utf8),
                options: [.fragmentsAllowed]
            )
        } catch {
            throw RPCProtocolError(code: -32700, message: "Parse error")
        }

        if let batch = value as? [Any] {
            guard !batch.isEmpty, batch.count <= maximumBatchCalls else {
                throw RPCProtocolError(code: -32600, message: "Batch limit")
            }
            return DecodedRPCMessage(isBatch: true, entries: batch.map(decodeEntry))
        }

        return DecodedRPCMessage(isBatch: false, entries: [decodeEntry(value)])
    }

    private static func decodeEntry(_ value: Any) -> DecodedRPCEntry {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let request = try? JSONDecoder().decode(RPCRequest.self, from: data),
              request.isValid
        else {
            return .invalid(RPCFailure(code: -32600, message: "Invalid Request"))
        }
        return .request(request)
    }
}
