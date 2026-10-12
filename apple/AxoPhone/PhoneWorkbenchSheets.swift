import AxoCore
import SwiftUI

struct CreateWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let canCreate: Bool
    let create: (WorkbenchName) -> Void

    private var parsedName: WorkbenchName? { try? WorkbenchName(name) }

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
                        Label("New work isn’t queued while you’re offline.", systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { if let parsedName { create(parsedName) } }
                        .disabled(!canCreate || parsedName == nil)
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
    let create: (WorkspaceID, WorkbenchName) -> Void

    private var parsedName: WorkbenchName? { try? WorkbenchName(name) }

    init(workspaces: [CatalogWorkspace], canCreate: Bool, create: @escaping (WorkspaceID, WorkbenchName) -> Void) {
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
                        Label("New work isn’t queued while you’re offline.", systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        if let workspaceID, let parsedName { create(workspaceID, parsedName) }
                    }
                    .disabled(!canCreate || parsedName == nil || workspaceID == nil)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
