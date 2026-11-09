import AppKit
import AxoSearch
import SwiftUI
import UniformTypeIdentifiers

/// Picks a folder, from those under the home directory or any other, and starts a Session in it
/// (RFD0038).
struct NewSessionInFolderSheet: View {
  var sessions: TerminalSessionsModel
  @Environment(\.dismiss) private var dismiss
  @State private var directoryQuery = ""
  @State private var directories: [URL] = []
  @State private var directoryIndex = SearchIndex<URL>([]) {
    SearchDocument(title: $0.lastPathComponent, subtitle: $0.path)
  }
  @State private var selectedDirectoryIndex = 0
  @State private var isChoosingDirectory = false
  @State private var isCreating = false
  @State private var directorySelectionError: String?
  @FocusState private var isDirectorySearchFocused: Bool

  private var directoryResults: [SearchResult<URL>] {
    directoryIndex.search(SearchQuery(directoryQuery)).prefix(8).map { $0 }
  }

  var body: some View {
    VStack(spacing: 0) {
      directoryStep

      if let error = sessions.sessionCreationError ?? directorySelectionError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .accessibilityIdentifier("new-session-in-folder-error")
      }
    }
    .frame(width: 560)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    .onExitCommand { dismiss() }
    .fileImporter(
      isPresented: $isChoosingDirectory,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let url = urls.first?.standardizedFileURL { chooseDirectory(url) }
        directorySelectionError = nil
      case .failure(let error):
        directorySelectionError = error.localizedDescription
      }
    }
    .task {
      sessions.dismissSessionCreationError()
      let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      let found = await Task.detached(priority: .utility) {
        Self.directories(under: home, limit: 10_000)
      }.value
      directories = found
      directoryIndex = SearchIndex(found) {
        SearchDocument(title: $0.lastPathComponent, subtitle: $0.path)
      }
    }
    .defaultFocus($isDirectorySearchFocused, true)
  }

  private var directoryStep: some View {
    VStack(spacing: 0) {
      ZStack {
        DirectorySelectionKeys(move: moveDirectorySelection)
        HStack(spacing: 10) {
          Image(systemName: "folder.badge.plus")
            .foregroundStyle(.secondary)
          TextField("New Session in… (search folders in your home directory)", text: $directoryQuery)
            .textFieldStyle(.plain)
            .font(.system(size: 18, weight: .light))
            .focused($isDirectorySearchFocused)
            .onSubmit(chooseSelectedDirectory)
            .onChange(of: directoryQuery) { _, _ in selectedDirectoryIndex = 0 }
            .accessibilityIdentifier("folder-search")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
      }
      Divider()

      if directories.isEmpty {
        ProgressView("Finding folders…")
          .frame(maxWidth: .infinity, minHeight: 112)
      } else if directoryResults.isEmpty {
        Text("No matching folders")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 112)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 2) {
              ForEach(Array(directoryResults.enumerated()), id: \.element.item.path) { index, result in
                DirectorySearchRow(result: result, isSelected: index == selectedDirectoryIndex) {
                  chooseDirectory(result.item)
                }
                .id(result.item.path)
              }
            }
            .padding(6)
          }
          .frame(maxHeight: 320)
          .onChange(of: selectedDirectoryIndex) { _, index in
            guard directoryResults.indices.contains(index) else { return }
            proxy.scrollTo(directoryResults[index].item.path)
          }
        }
      }

      Divider()
      HStack(spacing: 8) {
        Text("↑↓ Select   ↵ Start Session")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Choose Another Folder…") { isChoosingDirectory = true }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("choose-folder-button")
      }
      .padding(.horizontal, 12)
      .frame(height: 40)
    }
  }

  private func moveDirectorySelection(by offset: Int) {
    guard !directoryResults.isEmpty else { return }
    let count = directoryResults.count
    selectedDirectoryIndex = ((selectedDirectoryIndex + offset) % count + count) % count
  }

  private func chooseSelectedDirectory() {
    guard !directoryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      directoryResults.indices.contains(selectedDirectoryIndex)
    else { return }
    chooseDirectory(directoryResults[selectedDirectoryIndex].item)
  }

  private func chooseDirectory(_ url: URL) {
    guard !isCreating else { return }
    directorySelectionError = nil
    Task {
      isCreating = true
      defer { isCreating = false }
      await sessions.createSession(inFolder: url.standardizedFileURL.path)
      if sessions.sessionCreationError == nil { dismiss() }
    }
  }

  nonisolated private static func directories(under root: URL, limit: Int) -> [URL] {
    var results = [root]
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants],
      errorHandler: { _, _ in true }
    ) else { return results }

    while results.count < limit, let url = enumerator.nextObject() as? URL {
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        continue
      }
      if ["Library", ".Trash", ".cache", "node_modules", ".git"].contains(url.lastPathComponent) {
        enumerator.skipDescendants()
        continue
      }
      results.append(url.standardizedFileURL)
    }
    return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }
}

private struct DirectorySelectionKeys: View {
  var move: (Int) -> Void

  var body: some View {
    Group {
      key(.upArrow, by: -1)
      key(.downArrow, by: 1)
      key("p", modifiers: .control, by: -1)
      key("n", modifiers: .control, by: 1)
    }
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  private func key(
    _ key: KeyEquivalent, modifiers: EventModifiers = [], by offset: Int
  ) -> some View {
    Button { move(offset) } label: { Color.clear }
      .buttonStyle(.plain)
      .keyboardShortcut(key, modifiers: modifiers)
  }
}

private struct DirectorySearchRow: View {
  let result: SearchResult<URL>
  let isSelected: Bool
  var onChoose: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: onChoose) {
      HStack(spacing: 10) {
        Image(systemName: "folder")
          .foregroundStyle(.secondary)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(CommandPaletteHighlight.attributed(
            result.item.lastPathComponent, result.match.titleHighlights))
            .lineLimit(1)
          Text(CommandPaletteHighlight.attributed(result.item.path, result.match.subtitleHighlights))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer(minLength: 8)
        if isSelected {
          Image(systemName: "return")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 6).fill(
          isSelected
            ? Color.accentColor.opacity(0.22)
            : (isHovered ? Color.secondary.opacity(0.12) : Color.clear))
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityIdentifier("folder-\(result.item.lastPathComponent)")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
