import AxoCore
import AxoProtocol
import SwiftUI

@MainActor
struct PrivateMachineBrowserView: View {
    @State private var model = PrivateMachineBrowserModel()
    @State private var isShowingLogin = false
    @State private var loginError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if !model.isSignedIn {
                Section("Cloudflare Access") {
                    if let accessMessage = model.accessMessage {
                        Label(accessMessage, systemImage: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Sign in to discover machines on your private Axo network.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Sign in with Cloudflare Access", systemImage: "person.crop.circle.badge.checkmark") {
                        isShowingLogin = true
                    }
                    .accessibilityIdentifier("control-plane-login")
                }
            } else {
                Section {
                    if model.machines.isEmpty {
                        ContentUnavailableView(
                            model.isDiscovering ? "Finding machines…" : "No machines found",
                            systemImage: "desktopcomputer",
                            description: Text("Only authenticated Axo daemons appear here. Discovery does not start work.")
                        )
                    } else {
                        ForEach(model.machines, id: \.machineId) { machine in
                            MachineDirectoryRow(
                                machine: machine,
                                isSelected: model.selectedMachineID == machine.machineId
                            ) {
                                Task { await model.selectMachine(machine.machineId) }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Machines")
                        Spacer()
                        if model.isDiscovering {
                            ProgressView().controlSize(.small)
                        }
                    }
                } footer: {
                    Text("These are daemon hosts, not Pi conversations or histories.")
                }

                if let machine = model.selectedMachine {
                    selectedMachineSection(machine)
                }

                if let notice = model.notice {
                    Section {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("control-plane-notice")
                    }
                }

                Section {
                    Button("Sign out of private machines", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task { await model.signOut() }
                    }
                    .accessibilityIdentifier("control-plane-signout")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Private machines")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.isSignedIn {
                    Button {
                        Task { await model.refreshMachines() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isDiscovering)
                    .accessibilityLabel("Refresh machines")
                    .accessibilityIdentifier("control-plane-refresh-machines")
                }
            }
        }
        .refreshable { await model.refreshMachines() }
        .task { await model.start() }
        .sheet(isPresented: $isShowingLogin) {
            NavigationStack {
                VStack(spacing: 16) {
                    Text("Sign in to Axo’s private machine directory.")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    ControlPlaneAccessLogin(
                        endpoint: .production,
                        onAuthenticated: { credential in
                            isShowingLogin = false
                            Task { await model.signIn(credential) }
                        },
                        onFailure: { loginError = $0 }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    if let loginError {
                        Text(loginError).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding()
                .navigationTitle("Cloudflare Access")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isShowingLogin = false }
                    }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func selectedMachineSection(_ machine: MachineSummary) -> some View {
        Section {
            if !machine.online {
                Label("Host offline · runtime and work metadata unavailable", systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("control-plane-offline-banner")
            } else if model.isRuntimeGenerationStale {
                Label("Stale host generation · refresh before using this runtime list", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("control-plane-stale-banner")
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(machine.label).font(.headline)
                    Text("Machine · \(shortID(machine.machineId))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let generation = machine.hostGeneration {
                        Text("Active generation · \(shortID(generation))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No active host generation")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(machine.online ? "Online" : "Offline")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(machine.online ? .green : .secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(machine.online ? "machine-online-status" : "machine-offline-status")

            if model.isLoadingRuntimes {
                ProgressView("Negotiating and loading runtimes…")
            } else if machine.online && !model.isConnected {
                Button("Connect and list runtimes", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                    Task { await model.reconnect() }
                }
                .accessibilityIdentifier("control-plane-reconnect")
            } else if model.isConnected {
                HStack {
                    Button("Refresh runtimes", systemImage: "arrow.clockwise") {
                        Task { await model.refreshRuntimes() }
                    }
                    .accessibilityIdentifier("control-plane-refresh-runtimes")
                    Spacer()
                    Button("Disconnect", systemImage: "xmark.circle") {
                        Task { await model.disconnect() }
                    }
                    .accessibilityIdentifier("control-plane-disconnect")
                }
            }
        } header: {
            Text("Runtime metadata")
        } footer: {
            Text("Runtime and pane identifiers are daemon metadata. This does not expose Pi conversations, transcripts, or terminal output.")
        }

        workRecordsSection(machine)

        if let result = model.selectedRuntimeResult {
            Section("Runtimes · source generation \(shortID(result.hostGeneration))") {
                if result.terminals.isEmpty {
                    Text("No runtime records")
                        .foregroundStyle(.secondary)
                }
                ForEach(result.terminals, id: \.runtime.runtimeGeneration) { terminal in
                    MachineRuntimeRow(
                        terminal: terminal,
                        sourceGeneration: result.hostGeneration,
                        currentGeneration: machine.hostGeneration,
                        hostOnline: machine.online
                    )
                }
                if model.selectedRuntimeCursor != nil && machine.online && model.isConnected {
                    Button("Load more runtimes") { Task { await model.loadMoreRuntimes() } }
                        .disabled(model.isLoadingRuntimes)
                        .accessibilityIdentifier("control-plane-load-more-runtimes")
                }
            }
        }
    }

    @ViewBuilder
    private func workRecordsSection(_ machine: MachineSummary) -> some View {
        Section {
            if !machine.online {
                Text("Runtime and work metadata are not shown while this machine is offline.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.isLoadingWork {
                ProgressView("Loading workspaces and sessions…")
            } else if let workNotice = model.workNotice {
                Label(workNotice, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if model.selectedWorkspaces.isEmpty {
                Text(model.isConnected ? "No workspaces on this machine." : "Connect to load work records.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(model.selectedWorkspaces) { workspace in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(workspace.name).font(.headline)
                        ForEach(model.selectedWorkSessions.filter { $0.workspaceId == workspace.workspaceId }) { session in
                            WorkRecordRow(session: session)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            HStack {
                Text("Workspaces and sessions")
                Spacer()
                if let revision = model.selectedWorkRevision {
                    Text("Revision \(revision.rawValue)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } footer: {
            Text("A work session is not a Pi chat. This browser does not start work or load transcripts.")
        }
    }

    private func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }
}

private struct WorkRecordRow: View {
    let session: WorkSessionRecord

    private var runtimeDescription: String {
        let process: String
        if let runtime = session.runtime {
            switch runtime.process {
            case .starting: process = "Starting process"
            case .running: process = "Process running"
            case .stopping: process = "Process stopping"
            case .exited(let status): process = "Historical process · exit status \(status)"
            case .failed: process = "Process failed"
            case .recoveryRequired: process = "Process recovery required"
            }
        } else {
            process = "No runtime observed"
        }
        return process
    }

    private var piAdmissionDescription: String {
        switch session.pi.admission {
        case .notAdmitted: "Pi not admitted"
        case .ready: "Pi ready"
        case .stopped: "Pi stopped"
        case .failed: "Pi failed"
        case .recoveryRequired: "Pi recovery required"
        }
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName).font(.subheadline)
                Text(runtimeDescription).font(.caption).foregroundStyle(.secondary)
                Text(piAdmissionDescription).font(.caption2).foregroundStyle(.tertiary)
            }
        } icon: {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MachineDirectoryRow: View {
    let machine: MachineSummary
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: machine.online ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                    .foregroundStyle(machine.online ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(machine.label).font(.body.weight(.medium))
                    Text(machine.online ? "Online · generation \(machine.hostGeneration.map(shortID) ?? "unknown")" : "Offline")
                        .font(.caption).foregroundStyle(machine.online ? .green : .secondary)
                }
                Spacer()
                if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("machine-\(machine.machineId.uuidString.lowercased())")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }
}

private struct MachineRuntimeRow: View {
    let terminal: TerminalSnapshot
    let sourceGeneration: UUID
    let currentGeneration: UUID?
    let hostOnline: Bool

    private var isHistorical: Bool {
        guard hostOnline, sourceGeneration == currentGeneration,
              terminal.runtime.hostGeneration == sourceGeneration else { return true }
        switch terminal.process {
        case .starting, .running, .stopping: return false
        case .exited, .failed, .recoveryRequired: return true
        }
    }

    private var processText: String {
        switch terminal.process {
        case .starting: "Starting"
        case .running(let pid): "Running · PID \(pid)"
        case .stopping(let pid): "Stopping · PID \(pid)"
        case .exited(let status): "Exited · status \(status)"
        case .failed: "Failed"
        case .recoveryRequired: "Recovery required"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(isHistorical ? "Historical runtime" : "Current runtime", systemImage: isHistorical ? "clock.arrow.circlepath" : "terminal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isHistorical ? .secondary : .primary)
                Spacer()
                Text(processText).font(.caption).foregroundStyle(.secondary)
            }
            Text("Session \(shortID(terminal.runtime.target.sessionId)) · pane \(shortID(terminal.runtime.target.paneId))")
                .font(.caption).foregroundStyle(.secondary)
            Text("Runtime generation \(shortID(terminal.runtime.runtimeGeneration)) · host \(shortID(terminal.runtime.hostGeneration))")
                .font(.caption2).foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                Text(terminal.attached ? "Attached" : "Detached")
                Text("Backlog · \(terminal.backlogBytes) bytes")
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(isHistorical ? "machine-runtime-historical" : "machine-runtime-current")
    }

    private func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }
}
