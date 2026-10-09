import AxoCore
import AxoVoice
import SwiftUI

@main
struct AxoPhoneApp: App {
    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: "relayEndpoint")
        let restored = RelayEndpoint.restoredOrigin(stored)
        if stored != restored { defaults.set(restored, forKey: "relayEndpoint") }
        defaults.removeObject(forKey: "voiceModelDownloadApproved")
    }

    var body: some Scene {
        WindowGroup {
            ConversationView()
                .task {
                    await Task.detached(priority: .utility) {
                        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
                        try? LegacyVoiceCleanup.removeParakeetCache(in: support)
                    }.value
                }
        }
    }
}
