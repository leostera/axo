import Foundation

/// A canonical display name, parsed before it becomes mutation input.
/// Deliberately not Codable: wire decoders must use this constructor.
public struct WorkbenchName: Hashable, Sendable {
    public enum ParseError: Error, Equatable {
        case empty
        case tooLong
        case controlCharacter
    }

    public static let maximumUTF8Bytes = 120
    public let value: String

    public init(_ input: String) throws {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ParseError.empty }
        guard name.utf8.count <= Self.maximumUTF8Bytes else { throw ParseError.tooLong }
        guard !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ParseError.controlCharacter
        }
        value = name
    }
}
