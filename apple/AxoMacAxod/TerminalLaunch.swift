import AxoProtocol
import Foundation

/// Closed presentation intent. This renderer cannot launch Pi or an ordinary shell.
struct TerminalLaunch {
    struct Key: Hashable {
        let machineID: UUID
        let hostGeneration: UUID
        let sessionID: UUID
        let paneID: UUID
        let runtimeGeneration: UUID
    }
    let key: Key
    let directory: String
    let command: String

    private init(key: Key, directory: String, command: String) {
        self.key = key
        self.directory = directory
        self.command = command
    }

    static func attachment(root: URL, machineID: UUID, runtime: TerminalRuntime, helper: URL) throws -> Self {
        guard root.isFileURL, helper.isFileURL, root.path.hasPrefix("/"), helper.path.hasPrefix("/"),
              !root.path.contains("\u{0}"), !helper.path.contains("\u{0}"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw LaunchError.missingHelper
        }
        let key = Key(machineID: machineID, hostGeneration: runtime.hostGeneration,
                      sessionID: runtime.target.sessionId, paneID: runtime.target.paneId,
                      runtimeGeneration: runtime.runtimeGeneration)
        let arguments = [helper.path, "terminal-attach", root.path, machineID.uuidString,
                         runtime.hostGeneration.uuidString, runtime.target.sessionId.uuidString,
                         runtime.target.paneId.uuidString, runtime.runtimeGeneration.uuidString]
        // Pinned Ghostty's macOS embedding already wraps this with exec -l.
        // A second exec token would be treated as the executable name.
        return Self(key: key, directory: root.path, command: arguments.map(quote).joined(separator: " "))
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum LaunchError: LocalizedError {
    case ghosttyInitialization, missingDirectory, surfaceCreation, missingHelper
    var errorDescription: String? {
        switch self {
        case .ghosttyInitialization: return "The native terminal renderer could not initialize. Managed work was left untouched."
        case .missingDirectory: return "The terminal attachment directory is unavailable. Managed work was left untouched."
        case .surfaceCreation: return "The terminal surface could not attach. Managed work was left untouched."
        case .missingHelper: return "The bundled terminal attachment helper is unavailable. No alternative launcher was used."
        }
    }
}
