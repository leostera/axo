import AxoProtocol
import Foundation

/// Closed presentation intent. This renderer cannot launch Pi or an ordinary shell.
struct TerminalLaunch {
    enum Namespace: Hashable {
        case centralStore(UUID)
#if AXO_NATIVE_FIXTURE || AXO_NATIVE_TERMINAL_HARNESS
        case nativeHarness
#endif
    }
    struct Key: Hashable {
        let namespace: Namespace
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

    static func attachment(namespace: Namespace, root: URL, machineID: UUID, runtime: TerminalRuntime, helper: URL) throws -> Self {
        guard root.isFileURL, helper.isFileURL, root.path.hasPrefix("/"), helper.path.hasPrefix("/"),
              !root.path.contains("\u{0}"), !helper.path.contains("\u{0}"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw LaunchError.missingHelper
        }
        let key = Key(namespace: namespace, machineID: machineID, hostGeneration: runtime.hostGeneration,
                      sessionID: runtime.target.sessionId, paneID: runtime.target.paneId,
                      runtimeGeneration: runtime.runtimeGeneration)
        let arguments = [helper.path, "terminal-attach", root.path, machineID.uuidString,
                         runtime.hostGeneration.uuidString, runtime.target.sessionId.uuidString,
                         runtime.target.paneId.uuidString, runtime.runtimeGeneration.uuidString]
        // Pinned Ghostty's macOS embedding already wraps this with exec -l.
        // A second exec token would be treated as the executable name.
        let command = arguments.map(quote).joined(separator: " ")
#if AXO_NATIVE_FIXTURE
        // The disposable fixture retains only the frontend's body-free stderr.
        // Managed PTY bytes still use /dev/tty, never this diagnostic file.
        let diagnostic = root.appendingPathComponent("frontend-\(runtime.runtimeGeneration.uuidString).stderr")
        let descriptor = Darwin.open(diagnostic.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LaunchError.surfaceCreation }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600 else {
            throw LaunchError.surfaceCreation
        }
        return Self(key: key, directory: root.path, command: command + " 2>" + quote(diagnostic.path))
#else
        return Self(key: key, directory: root.path, command: command)
#endif
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
