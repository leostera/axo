import AxoMobileModel
import AxoProtocol
import AxoWatchModel
import SwiftUI

struct WatchSessionPicker: View {
  let model: WatchChatModel
  @Environment(\.dismiss) private var dismiss
  @State private var preferences: ChatListPreferences
  @State private var held: [ChatGroupSection]?

  init(model: WatchChatModel) {
    self.model = model
    let defaults = UserDefaults(suiteName: "axo.watch.sidebar.\(model.accountID.uuidString.lowercased())") ?? .standard
    _preferences = State(initialValue: ChatListPreferences(defaults: defaults))
  }

  private var groups: [ChatGroupSection] {
    let live = WatchSessionGroups.sections(hosts: model.workbench.hosts.hosts, sessionsOf: model.workbench.sessions(of:),
      seen: preferences.seen, settings: preferences.settings)
    return ChatGrouping.holding(held, live: live)
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(groups) { section in
          Section(section.group.title) {
            ForEach(section.chats, id: \.key) { entry in
              Button {
                if model.select(host: entry.host, session: entry.session) {
                  preferences.markSeen(entry.session)
                  dismiss()
                }
              } label: {
                VStack(alignment: .leading, spacing: 3) {
                  Text(entry.session.displayName).lineLimit(2)
                  Text(entry.host.label + (entry.host.status == .online ? "" : " · Offline"))
                    .font(.caption2).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
        if groups.isEmpty {
          switch model.workbench.hosts.phase {
          case .idle, .loading: ProgressView("Loading sessions…")
          case .failed(let message): Text(message).font(.caption).foregroundStyle(.orange)
          case .loaded: Text("No agent sessions yet. Start one on your Mac.").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Sessions")
      .onAppear { held = groups }
      .onChange(of: model.workbench.hosts.hosts) { held = groups }
    }
  }
}
