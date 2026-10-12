import SwiftUI

struct AxodSetupView: View {
    @Bindable var coordinator: AxodWorkbenchCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("Welcome to Axo", systemImage: "hammer")
                    .font(.largeTitle.bold())
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(AxodSetupPolicy.steps(registration: coordinator.serviceLifecycle.registration)) { step in
                        AxodSetupStep(number: step.number, title: step.title, complete: step.complete)
                    }
                }
                stageContent
                if coordinator.setupPresentation.failure != nil {
                    Label("Setup couldn’t finish.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(coordinator.daemonServiceMessage)
                        Text(coordinator.message)
                        if let failure = coordinator.setupPresentation.failure ?? coordinator.serviceSetupFailure {
                            Text(failure)
                        }
                        Button("Background Service Settings…", action: coordinator.showServiceSettingsWindow)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 8)
                }
                .accessibilityIdentifier("Axo.Setup.Details")
            }
            .padding(32)
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 560, minHeight: 360)
        .accessibilityIdentifier("Axo.Setup")
    }

    @ViewBuilder private var stageContent: some View {
        switch coordinator.setupStage {
        case .enableService:
            if coordinator.serviceSetupFailure != nil {
                Label("Background service registration unavailable.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Button("Check Status") { coordinator.connect() }
                    .accessibilityIdentifier("Axo.Setup.CheckService")
            } else {
                // Previously completed/removed setup requires a new user action,
                // rather than an automatic registration on every app opening.
                Button("Enable Background Activity", action: coordinator.enableBackgroundService)
                    .buttonStyle(.borderedProminent)
                    .disabled(coordinator.serviceLifecycle.operation != .idle)
                    .accessibilityIdentifier("Axo.Setup.EnableService")
            }
        case .approval:
            Text("Allow Axo in Login Items & Extensions.")
                .foregroundStyle(.secondary)
            serviceActions
        case .checking:
            ProgressView("Checking background service…")
                .accessibilityIdentifier("Axo.Setup.Checking")
        case .unavailable:
            Label("Background service unavailable.", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
            serviceActions
        case .ready:
            Toggle("Open at login", isOn: $coordinator.setupLoginStartup)
                .accessibilityIdentifier("Axo.Setup.LoginStartup")
                .disabled(coordinator.setupPresentation.isFinishing)
            Button("Done") { Task { await coordinator.finishSetup() } }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.setupPresentation.isFinishing || coordinator.serviceLifecycle.operation != .idle)
                .accessibilityIdentifier("Axo.Setup.Finish")
        }
    }

    private var serviceActions: some View {
        HStack {
            Button("Open Settings", action: coordinator.openLoginItemsSettings)
                .accessibilityIdentifier("Axo.Setup.ApprovalSettings")
            Button("Check Service") { coordinator.connect() }
                .accessibilityIdentifier("Axo.Setup.CheckService")
        }
    }
}

private struct AxodSetupStep: View {
    let number: Int
    let title: String
    let complete: Bool

    var body: some View {
        Label(title, systemImage: complete ? "checkmark.circle.fill" : "\(number).circle")
            .foregroundStyle(complete ? .secondary : .primary)
            .accessibilityLabel("Step \(number): \(title)\(complete ? ", complete" : "")")
    }
}
