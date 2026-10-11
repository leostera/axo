import Foundation

/// Immediate cold-start fallback. The daemon's owner lock, not this child handle,
/// decides ownership. App termination never terminates this process or its PTYs.
@MainActor final class AxodBundledDaemon {
    private var child: Process?
    func startIfOwnerAbsent(in directory: AxodStateDirectory) throws {
        if child?.isRunning == true { return }
        guard let absence = try AxodOwnerAbsenceLease.acquire(in: directory.root) else { return }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/axod")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            absence.release()
            throw LaunchError.missingHelper
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["serve-user"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = NSHomeDirectory()
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // The helper must acquire the same lock itself. A simultaneous launch
        // or LaunchAgent wins/loses there without duplicating daemon work.
        absence.release()
        try process.run()
        child = process
    }
}
