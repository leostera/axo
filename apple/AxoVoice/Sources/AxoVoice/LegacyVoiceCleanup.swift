import Foundation

public enum LegacyVoiceCleanup {
    /// The old Parakeet integration owned exactly this directory. Apple's shared
    /// language assets and all other application data must be left untouched.
    public static func removeParakeetCache(in applicationSupport: URL) throws {
        let legacy = applicationSupport.appendingPathComponent("AxoVoice/Models", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        try FileManager.default.removeItem(at: legacy)
    }
}
