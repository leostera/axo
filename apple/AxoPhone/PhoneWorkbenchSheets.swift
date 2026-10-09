import AxoCore
import SwiftUI

struct CreateWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let canCreate: Bool
    let create: (String) -> Void

    private var validName: Bool {
        (try? WorkspaceStore.validName(name)) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workspace") {
                    TextField("Workspace name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("new-workspace-name")
                }
                if !canCreate {
                    Section {
                        Label("Connect to an online Mac first. Nothing is queued while offline.", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create(name) }
                        .disabled(!canCreate || !validName)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

struct CreateSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var workspaceID: WorkspaceID?
    @State private var name = ""
    let workspaces: [CatalogWorkspace]
    let canCreate: Bool
    let create: (WorkspaceID, String) -> Void

    private var validName: Bool { (try? WorkspaceStore.validName(name)) != nil }

    init(workspaces: [CatalogWorkspace], canCreate: Bool, create: @escaping (WorkspaceID, String) -> Void) {
        self.workspaces = workspaces
        self.canCreate = canCreate
        self.create = create
        _workspaceID = State(initialValue: workspaces.first?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("New session") {
                    Picker("Workspace", selection: $workspaceID) {
                        ForEach(workspaces) { workspace in
                            Text(workspace.name).tag(Optional(workspace.id))
                        }
                    }
                    .accessibilityIdentifier("new-session-workspace")
                    TextField("Session name", text: $name)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityIdentifier("new-session-name")
                }
                if !canCreate {
                    Section {
                        Label("Connect to an online Mac first. Nothing is queued while offline.", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { if let workspaceID { create(workspaceID, name) } }
                        .disabled(!canCreate || !validName || workspaceID == nil)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
