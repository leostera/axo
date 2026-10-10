import AppKit
import AxoCore
import SwiftUI

struct AxodAboutView: View {
    @Bindable var coordinator: AxodWorkbenchCoordinator
    private let metadata = AxoBuildMetadata(info: Bundle.main.infoDictionary ?? [:])

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().scaledToFit().frame(width: 88, height: 88)
            VStack(spacing: 7) {
                Text("Axo").font(.system(size: 28, weight: .bold))
                Text("Agentic harness for terminal romantics")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Version"); Text("\(metadata.version) (axod v\(metadata.daemonVersion))") }
                GridRow { Text("Build"); Text(metadata.build) }
                GridRow {
                    Text("Commit")
                    if let url = metadata.commitURL {
                        Link(String(metadata.commit.prefix(8)), destination: url)
                    } else {
                        Text(metadata.commit)
                    }
                }
            }
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(coordinator.onlineMessage)
            }
            .font(.caption).foregroundStyle(.secondary)
            .help(coordinator.hostStatus.map { "Running axod: \($0.daemonVersion)" } ?? "Running daemon version unavailable")
        }
        .padding(28)
        .frame(width: 400)
    }

    private var statusColor: Color {
        switch coordinator.connectionState {
        case .starting: .yellow
        case .connected: coordinator.hostStatus?.cloud.isOnline == true ? .green : .blue
        case .disconnected, .failed: .red
        }
    }
}
