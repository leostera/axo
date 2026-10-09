import SwiftUI

struct MacPaletteCommand: Identifiable {
    let id: String
    let title: String
    let detail: String
    let shortcut: String?
    let perform: () -> Void
}

struct MacCommandPaletteView: View {
    let commands: [MacPaletteCommand]
    let close: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var matches: [MacPaletteCommand] {
        guard !query.isEmpty else { return commands }
        return commands.filter { Self.matches(query, in: $0.title + " " + $0.detail) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search commands, workspaces, sessions, and panes", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { matches.first?.perform() }
                Text("ESC").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(16)

            Divider()

            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { command in
                            Button(action: command.perform) {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(command.title).font(.body)
                                        Text(command.detail).font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 12)
                                    if let shortcut = command.shortcut {
                                        Text(shortcut)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: 620, height: 460)
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onExitCommand(perform: close)
    }

    private static func matches(_ query: String, in candidate: String) -> Bool {
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let value = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var next = needle.makeIterator()
        guard var character = next.next() else { return true }
        for candidateCharacter in value {
            if candidateCharacter == character {
                guard let following = next.next() else { return true }
                character = following
            }
        }
        return false
    }
}
