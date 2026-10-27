import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// Finds a Session by its name or its Workspace, across every Mac. Names only, not conversation text.
struct SessionSearchView: View {
  let hosts: [RemoteHost]
  /// A Mac's Sessions as they are now (the open Mac's are live).
  let sessionsOf: (RemoteHost) -> [RemoteSession]
  let choose: (RemoteHost, RemoteSession) -> Void
  @Environment(\.dismiss) private var dismiss
  @FocusState private var searchFocused: Bool
  @State private var query = ""

  private struct Match: Identifiable {
    let host: RemoteHost
    let session: RemoteSession
    var id: String { "\(host.hostId.uuidString)/\(session.sessionId)" }
  }

  private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var matches: [Match] {
    guard !trimmedQuery.isEmpty else { return [] }
    return hosts.flatMap { host in
      sessionsOf(host).filter {
        // Chats only: a bare terminal has nothing to read here.
        $0.hasAgent != false
          && ($0.displayName.localizedCaseInsensitiveContains(trimmedQuery)
          || ($0.workspaceName ?? "").localizedCaseInsensitiveContains(trimmedQuery))
      }.map { Match(host: host, session: $0) }
    }
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Workspace or chat name", text: $query)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .focused($searchFocused)
              .accessibilityIdentifier("search-field")
            if !query.isEmpty {
              Button { query = "" } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
              }
              .accessibilityLabel("Clear search")
            }
          }
        }
        if trimmedQuery.isEmpty {
          ContentUnavailableView(
            "Search chats", systemImage: "magnifyingglass",
            description: Text("Search by chat or workspace name."))
        } else if matches.isEmpty {
          ContentUnavailableView.search(text: query)
        } else {
          ForEach(matches) { match in
            Button {
              choose(match.host, match.session)
              dismiss()
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text(match.session.displayName).font(.body)
                Text([match.session.workspaceName, match.host.label].compactMap { $0 }.joined(separator: " · "))
                  .font(.caption).foregroundStyle(.secondary)
              }
              // The whole row, not only its words, takes the tap.
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search-result")
          }
        }
        Text("Search uses chat and workspace names only, not conversation text.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      .navigationTitle("Search")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { dismiss() } label: {
            Image(systemName: "xmark")
              .font(.system(size: 14, weight: .semibold))
              .frame(width: 36, height: 36)
              .background(.secondary.opacity(0.12), in: Circle())
          }
          .accessibilityLabel("Close search")
        }
      }
    }
    .presentationDetents([.large])
    .task { searchFocused = true }
  }
}
