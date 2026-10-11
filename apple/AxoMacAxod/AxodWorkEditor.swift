import AxoProtocol
import SwiftUI
import UniformTypeIdentifiers

struct AxodWorkEditorContext: Identifiable {
    enum Kind { case workspace, session(workspaceID: UUID?) }
    let id = UUID()
    let kind: Kind
    let target: MachineTarget
    let revision: WorkRevision
    var title: String {
        switch kind { case .workspace: "New workspace"; case .session: "New session" }
    }
}

struct AxodWorkEditor: View {
    let context: AxodWorkEditorContext
    @Bindable var coordinator: AxodWorkbenchCoordinator
    @State private var name = ""
    @State private var directory: LocalDirectoryPath?
    @State private var choosingFolder = false
    @State private var folderError: String?

    init(context: AxodWorkEditorContext, coordinator: AxodWorkbenchCoordinator) {
        self.context = context
        self.coordinator = coordinator
        _name = State(initialValue: { if case .session = context.kind { return "New Session" }; return "" }())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(context.title).font(.headline)
            if case .workspace = context.kind, coordinator.createdSessionForEditor == nil {
                TextField("Workspace name", text: $name).textFieldStyle(.roundedBorder)
            }
            if case .session(let workspaceID) = context.kind {
                Text(workspaceID == nil ? "Starts in your home folder ($HOME)." : "Starts in this workspace’s folder.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if case .workspace = context.kind, coordinator.createdSessionForEditor == nil {
                Button(directory == nil ? "Choose Folder…" : "Change Folder…", systemImage: "folder") { choosingFolder = true }
                if let directory {
                    Text(directory.rawValue).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let folderError { Text(folderError).foregroundStyle(.red) }
            }
            Text(coordinator.workEditMessage).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if coordinator.createdSessionForEditor != nil {
                    Button("Open Session") { coordinator.workEditor = nil }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { coordinator.workEditor = nil }
                        .keyboardShortcut(.cancelAction)
                    if case .workspace = context.kind {
                        Button("Create & Start") { coordinator.createWork(context, name: name, directory: directory) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canCreate || coordinator.isEditingWork || coordinator.pendingWorkCommandID != nil)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .disabled(coordinator.isEditingWork)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                guard let selected = LocalDirectoryPath(selectedURL: url) else { folderError = "Choose a local folder."; return }
                directory = selected
                folderError = nil
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = url.lastPathComponent }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { folderError = "Could not select this folder. Try again." }
            }
        }
    }

    private var canCreate: Bool {
        guard coordinator.canEditWork,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch context.kind {
        case .workspace: return directory != nil
        case .session: return true
        }
    }
}
