import Foundation

/// Immediate cold-start fallback. The daemon's owner lock, not this child handle,
/// decides ownership. App termination never terminates this process or its PTYs.
@MainActor final class AxodBundledDaemon {
    private var child: Process?
#if DEBUG
    var selfTest: AxodAppSelfTest?
    func stopSelfTestChild() async {
        guard selfTest != nil, let child, child.isRunning else { return }
        child.terminate()
        while child.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
    }
#endif
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
#if DEBUG
        if let selfTest {
            // Exercise serve-user, including account-shell selection and its
            // normal HOME/Application Support configuration, not a different server.
            environment["HOME"] = selfTest.home.path
            environment["ZDOTDIR"] = selfTest.home.path
            // Deliberately misleading launcher environment: serve-user must use
            // the user's account shell, and export that captured identity to PTYs.
            environment["SHELL"] = "/bin/sh"
            environment["PI_CODING_AGENT_DIR"] = selfTest.root.appendingPathComponent("agent").path
            environment["PI_AXO_INTERACTIVE_FIXTURE_CONFIG"] = selfTest.root.appendingPathComponent("provider.json").path
        }
#endif
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
