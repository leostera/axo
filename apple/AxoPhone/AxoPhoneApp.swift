import AxoCore
import AxoVoice
import SwiftUI

@main
struct AxoPhoneApp: App {
    #if DEBUG && targetEnvironment(simulator)
    @State private var controlPlaneFixture: CentralPhoneWorkbenchModel?
    private let usesControlPlaneFixture: Bool
    #endif
    init() {
        #if DEBUG && targetEnvironment(simulator)
        usesControlPlaneFixture = PhoneControlPlaneE2E.requested
        _controlPlaneFixture = State(initialValue: usesControlPlaneFixture ? try? PhoneControlPlaneE2E.model() : nil)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if usesControlPlaneFixture {
                if let controlPlaneFixture {
                    PhoneWorkbenchView(model: controlPlaneFixture)
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
    }
}
