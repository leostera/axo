import SwiftUI

struct AxodSetupView: View {
    @Bindable var coordinator: AxodWorkbenchCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("Welcome to Axo", systemImage: "hammer")
                    .font(.largeTitle.bold())
                Text("Axo lives in your menu bar. Open its workbench whenever you need it; closing the window leaves Axo available there.")
                Text("The separate Axod background service owns Pi and shell sessions. Quitting Axo does not stop that service or its work.")
                    .foregroundStyle(.secondary)
                Divider()
                stageContent
                if let failure = coordinator.setupPresentation.failure ?? coordinator.serviceSetupFailure {
                    Text(failure).foregroundStyle(.red).textSelection(.enabled)
                }
                if let message = coordinator.chatDrafts.quitMessage {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .padding(40)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .accessibilityIdentifier("Axo.Setup")
    }

    @ViewBuilder private var stageContent: some View {
        switch coordinator.setupStage {
        case .installation:
            Text("1. Install Axo").font(.title2.bold())
            Text("Quit Axo, move Axo.app into Applications (or your user’s Applications folder) in Finder, then open it from there. Setup will continue from that stable location.")
            Text("This step does not overwrite an installed app, enable a service, or change your session data.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Show Axo in Finder", action: coordinator.revealInstallationSource)
                    .accessibilityIdentifier("Axo.Setup.ShowApp")
                Button("Open Applications", action: coordinator.openApplicationsFolder)
                    .accessibilityIdentifier("Axo.Setup.Applications")
            }
        case .enableService:
            Text("2. Enable the background service").font(.title2.bold())
            Text("Allow macOS to run Axod for your user, independently of this window. This does not turn on opening Axo at login.")
            Button("Enable Background Service", action: coordinator.enableBackgroundService)
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.serviceLifecycle.operation != .idle)
                .accessibilityIdentifier("Axo.Setup.EnableService")
        case .approval:
            Text("2. Approve the background service").font(.title2.bold())
            Text(coordinator.daemonServiceMessage)
            serviceActions
        case .checking:
            Text("3. Check the background service").font(.title2.bold())
            ProgressView("Waiting for a responding Axod and its session catalog…")
                .accessibilityIdentifier("Axo.Setup.Checking")
            Text("Registration alone is not readiness. No session or service is restarted by this check.")
                .foregroundStyle(.secondary)
        case .unavailable:
            Text("The background service is unavailable").font(.title2.bold())
            Text(coordinator.message).textSelection(.enabled)
            Text(coordinator.daemonServiceMessage).foregroundStyle(.secondary)
            Text("Your records are preserved. A disabled, missing, or broken service must be resolved before setup can finish; this is not an empty session catalog.")
                .foregroundStyle(.secondary)
            serviceActions
            Button("Background Service Details…", action: coordinator.showServiceSettingsWindow)
        case .ready:
            Text("4. Axod is responding").font(.title2.bold())
            Text("The local connection and session catalog are available. Opening the workbench restores existing work; a first session is created only for an authoritatively empty profile.")
            Toggle("Keep Axo in the menu bar at login", isOn: $coordinator.setupLoginStartup)
                .accessibilityIdentifier("Axo.Setup.LoginStartup")
                .disabled(coordinator.setupPresentation.isFinishing)
            Text("This starts the menu-bar frontend at login. It is separate from enabling the Axod background service.")
                .foregroundStyle(.secondary)
            Button("Open Axo") { Task { await coordinator.finishSetup() } }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.setupPresentation.isFinishing || coordinator.serviceLifecycle.operation != .idle)
                .accessibilityIdentifier("Axo.Setup.Finish")
        }
    }

    private var serviceActions: some View {
        HStack {
            Button("Open Login Items & Extensions", action: coordinator.openLoginItemsSettings)
                .accessibilityIdentifier("Axo.Setup.ApprovalSettings")
            Button("Check Service") { coordinator.connect() }
                .accessibilityIdentifier("Axo.Setup.CheckService")
        }
    }
}
