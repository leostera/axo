import SwiftUI

struct AxodSettingsView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case startup
        case backgroundDaemon
        case localDaemon

        var id: Self { self }

        var title: String {
            switch self {
            case .startup: "Startup"
            case .backgroundDaemon: "Background Daemon"
            case .localDaemon: "Local Daemon"
            }
        }

        var symbol: String {
            switch self {
            case .startup: "arrow.clockwise.circle"
            case .backgroundDaemon: "gearshape.2"
            case .localDaemon: "desktopcomputer"
            }
        }
    }

    @Bindable var coordinator: AxodWorkbenchCoordinator
    @State private var selectedPage: Page? = .backgroundDaemon

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $selectedPage) { page in
                Label(page.title, systemImage: page.symbol)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .navigationTitle("Axo Settings")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            switch selectedPage {
            case .startup:
                startupPage
            case .backgroundDaemon:
                backgroundDaemonPage
            case .localDaemon:
                localDaemonPage
            case nil:
                ContentUnavailableView("Choose a Settings Section", systemImage: "gear")
            }
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 720, minHeight: 480)
    }

    private var startupPage: some View {
        Form {
            pageHeading("Startup", subtitle: "Choose whether Axo opens automatically when you log in.")
            Section("Axo") {
                Text(coordinator.startupMessage)
                    .textSelection(.enabled)
                if coordinator.needsLoginItemsReview {
                    Button("Review Login Items…") { coordinator.openLoginItemsSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var backgroundDaemonPage: some View {
        Form {
            pageHeading("Background Daemon", subtitle: "Axo runs its bundled axod helper as a per-user LaunchAgent.")
            Section("Versions") {
                LabeledContent("Bundled axod", value: Bundle.main.object(forInfoDictionaryKey: "AxoBundledAxodVersion") as? String ?? "Not packaged")
                LabeledContent("Running axod", value: coordinator.hostStatus?.daemonVersion ?? "Unavailable")
            }
            Section("Service status") {
                Text(coordinator.daemonServiceMessage)
                    .textSelection(.enabled)
                if coordinator.needsDaemonServiceReview || coordinator.needsLoginItemsReview {
                    Button("Review Login Items…") { coordinator.openLoginItemsSettings() }
                }
            }
            Section("State") {
                Text("Axo uses its private per-user Axod state directory. All launches share that daemon. It is not a system-wide LaunchDaemon.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var localDaemonPage: some View {
        Form {
            pageHeading("Local Daemon", subtitle: "Inspect work owned by Axod on this Mac.")
            Section("Connection") {
                Text(coordinator.onlineMessage)
                    .textSelection(.enabled)
                Text(coordinator.message).font(.caption).foregroundStyle(.secondary)
                if coordinator.connectionState != .connected {
                    Button("Connect") { coordinator.connect() }
                } else {
                    Button("Refresh") { coordinator.refresh() }
                }
            }
            Section("Capabilities") {
                Text("Managed Pi chat reads canonical history and sends addressed commands. Native terminal attachment is not available in this build yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pageHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}
