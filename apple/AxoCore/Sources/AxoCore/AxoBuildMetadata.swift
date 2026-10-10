import Foundation

/// Packaged display metadata, never inferred from the working directory or a running process.
public struct AxoBuildMetadata: Equatable, Sendable {
    public let version: String
    public let daemonVersion: String
    public let build: String
    public let commit: String
    public var commitURL: URL? {
        guard commit != "Unavailable" else { return nil }
        return URL(string: "https://github.com/leostera/axo/commit/\(commit)")
    }

    public init(info: [String: Any]) {
        version = Self.text(info["CFBundleShortVersionString"]) ?? "Unavailable"
        build = Self.text(info["CFBundleVersion"]) ?? "Unavailable"
        let bundled = Self.text(info["AxoBundledAxodVersion"])
        daemonVersion = bundled?.split(separator: " ").first.map(String.init) ?? "Unavailable"
        let revision = Self.text(info["AxoBuildCommit"])
        if let revision, (8...40).contains(revision.count), revision.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) {
            commit = revision
        } else {
            commit = "Unavailable"
        }
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 120,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }
}
