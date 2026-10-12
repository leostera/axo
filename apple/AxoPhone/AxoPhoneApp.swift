import AxoCore
import AxoVoice
import SwiftUI

@main
struct AxoPhoneApp: App {
    #if DEBUG && targetEnvironment(simulator)
    @State private var controlPlaneFixture: PrivateMachineBrowserModel?
    private let usesControlPlaneFixture: Bool
    #endif
    init() {
        #if DEBUG && targetEnvironment(simulator)
        usesControlPlaneFixture = PhoneControlPlaneE2E.requested
        _controlPlaneFixture = State(initialValue: usesControlPlaneFixture ? try? PhoneControlPlaneE2E.model() : nil)
        if usesControlPlaneFixture { return }
        #endif
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: "relayEndpoint")
        let restored = RelayEndpoint.restoredOrigin(stored)
        if stored != restored { defaults.set(restored, forKey: "relayEndpoint") }
        defaults.removeObject(forKey: "voiceModelDownloadApproved")
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if usesControlPlaneFixture {
                if let controlPlaneFixture {
                    NavigationStack { PrivateMachineBrowserView(model: controlPlaneFixture) }
                } else {
                    Text("Private control-plane fixture refused.")
                        .accessibilityIdentifier("control-plane-fixture-refused")
                }
            } else {
                workbench
            }
            #else
            workbench
            #endif
        }
    }

    private var workbench: some View {
        PhoneWorkbenchView()
                .task {
                    await Task.detached(priority: .utility) {
                        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
                        try? LegacyVoiceCleanup.removeParakeetCache(in: support)
                    }.value
                }
    }
}
