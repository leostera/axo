import AxoProtocol
import SwiftUI

struct AxodWorkEditorContext: Identifiable {
    enum Kind { case workspace, session(workspaceID: UUID) }
    let id = UUID()
    let kind: Kind
    let target: MachineTarget
    let revision: WorkRevision
    let directories: [WorkspaceDirectorySummary]
    var title: String {
        switch kind { case .workspace: "New workspace"; case .session: "New session" }
    }
}

struct AxodWorkEditor: View {
    let context: AxodWorkEditorContext
    @Bindable var coordinator: AxodWorkbenchCoordinator
    @State private var name = ""
    @State private var directoryID: String

    init(context: AxodWorkEditorContext, coordinator: AxodWorkbenchCoordinator) {
        self.context = context
        self.coordinator = coordinator
        _directoryID = State(initialValue: context.directories.first?.directoryId ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(context.title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            if case .workspace = context.kind {
                if context.directories.isEmpty {
                    Text("No directories have been approved for this daemon. Configure its private profiles.json before creating a workspace; existing work will not be imported automatically.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Approved directory", selection: $directoryID) {
                        ForEach(context.directories, id: \.directoryId) { directory in
                            Text(directory.name).tag(directory.directoryId)
                        }
                    }
                }
            }
            Text(coordinator.workEditMessage).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { coordinator.workEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { coordinator.createWork(context, name: name, directoryID: directoryID) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || coordinator.isEditingWork || coordinator.pendingWorkCommandID != nil)
            }
        }
        .padding(24)
        .frame(width: 440)
        .disabled(coordinator.isEditingWork)
    }

    private var canCreate: Bool {
        guard coordinator.canEditWork,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch context.kind {
        case .workspace: return context.directories.contains { $0.directoryId == directoryID }
        case .session: return true
        }
    }
}
