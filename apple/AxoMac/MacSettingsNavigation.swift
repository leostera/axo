import SwiftUI

enum MacSettingsPage: String, CaseIterable, Identifiable {
    case general, keyboardShortcuts, voice
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "General"
        case .keyboardShortcuts: "Keybindings"
        case .voice: "Voice & Transcript"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .keyboardShortcuts: "keyboard"
        case .voice: "waveform"
        }
    }
}

/// Selection and width belong to Settings, independently of the workbench sidebar.
struct MacSettingsNavigation: View {
    @Binding var selected: MacSettingsPage?
    @Binding var collapsed: Bool

    var body: some View {
        VStack(spacing: 0) {
            if collapsed {
                VStack(spacing: 8) {
                    ForEach(MacSettingsPage.allCases) { page in
                        Button { selected = page } label: {
                            Image(systemName: page.symbol)
                                .frame(width: 36, height: 36)
                                .background(selected == page ? Color.accentColor.opacity(0.15) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .help(page.title)
                        .accessibilityLabel(page.title)
                        .accessibilityIdentifier("Axo.Settings.\(page.rawValue)")
                        .accessibilityAddTraits(selected == page ? .isSelected : [])
                    }
                }
                .padding(.top, 12)
                Spacer(minLength: 12)
            } else {
                List(MacSettingsPage.allCases, selection: $selected) { page in
                    Label(page.title, systemImage: page.symbol).tag(page)
                }
                .listStyle(.sidebar)
            }
            Button { collapsed.toggle() } label: {
                Image(systemName: collapsed ? "sidebar.left" : "sidebar.leading")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand Settings Sidebar" : "Collapse Settings Sidebar")
            .accessibilityLabel(collapsed ? "Expand Settings Sidebar" : "Collapse Settings Sidebar")
            .accessibilityIdentifier("Axo.Settings.ToggleSidebar")
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
