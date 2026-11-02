import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// One added MCP server: what the person called it, how scripts reach it, and its state.
struct ServerRow: View {
  let model: AppsModel
  let server: ServerConnection
  @Environment(\.openURL) private var openURL

  var body: some View {
    HStack(spacing: 10) {
      AppLogo(source: KnownServer.of(url: server.url).map { .known($0) } ?? .server(server.icon), size: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(server.displayName).lineLimit(1)
        Text(["codemode.\(server.name)", Self.state(of: server, short: false)].filter { !$0.isEmpty }.joined(separator: " · "))
          .font(.caption).foregroundStyle(server.state == .ready ? Color.secondary : Color.orange).lineLimit(2)
      }
      Spacer(minLength: 4)
      if server.state == .needsSignIn {
        // Signing in to a server happens on the web, where the provider comes back to.
        Button("Sign in") { openURL(model.webPage(for: nil)) }
          .buttonStyle(.bordered).controlSize(.small)
      } else if server.state == .ready {
        Circle().fill(Color.green).frame(width: 7, height: 7).accessibilityLabel("Connected")
      }
    }
    .accessibilityIdentifier("server-row")
  }

  /// What a server's row says of its state.
  static func state(of server: ServerConnection, short: Bool = true) -> String {
    switch server.state {
    case .ready: short ? AppsCatalog.count(server.tools, "tool") : server.lastError ?? ""
    case .needsSignIn: "Needs sign-in"
    case .error: short ? "Unreachable" : server.lastError ?? "Unreachable"
    }
  }
}

/// Removing a server, swiped or held, after asking.
private struct RemovableServer: ViewModifier {
  let model: AppsModel
  let server: ServerConnection
  @State private var confirming = false

  func body(content: Content) -> some View {
    content
      .swipeActions { Button("Remove", role: .destructive) { confirming = true } }
      .contextMenu { Button("Remove", systemImage: "trash", role: .destructive) { confirming = true } }
      .confirmationDialog("Remove \(server.displayName)?", isPresented: $confirming, titleVisibility: .visible) {
        Button("Remove", role: .destructive) { Task { await model.remove(server) } }
      } message: {
        Text("Your Sessions can no longer use it.")
      }
  }
}

/// A server Axo knows: what it is, each of it the person added under a name of theirs, and adding another.
struct KnownServerPageView: View {
  let model: AppsModel
  let known: KnownServer
  @Environment(\.openURL) private var openURL
  @State private var adding: String?

  private var added: [ServerConnection] { model.servers.filter { KnownServer.of(url: $0.url)?.id == known.id } }

  var body: some View {
    List {
      Section {
        VStack(spacing: 8) {
          AppLogo(source: .known(known), size: 64)
          Text(known.title).font(.title2.weight(.semibold))
          Text([known.provider, "MCP server", AppsCatalog.categoryTitle(known.category)].joined(separator: " · "))
            .font(.subheadline).foregroundStyle(.secondary)
          Text(known.description).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
          Text(AppsView.host(known.url)).font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
      }
      .listRowBackground(Color.clear)

      Section {
        ForEach(added) { server in
          ServerRow(model: model, server: server).modifier(RemovableServer(model: model, server: server))
        }
        if let name = adding {
          TextField("Name, e.g. \(known.title): work", text: Binding(get: { name }, set: { adding = $0 }))
            .autocorrectionDisabled()
            .accessibilityIdentifier("server-name")
          Button(known.signIn == .none ? "Add" : "Add and sign in") { add() }
            .disabled(model.isBusy || name.trimmingCharacters(in: .whitespaces).isEmpty)
          Button("Cancel", role: .cancel) { adding = nil }
        } else {
          Button { adding = added.isEmpty ? known.title : "" } label: {
            Label(known.signIn == .none ? "Add" : "Add account", systemImage: "plus")
          }
          .disabled(model.isBusy)
        }
      } header: {
        Text("Accounts")
      } footer: {
        Text(
          (known.signIn == .none ? "Needs no sign-in." : "Add it once for each account you have with it, each under its own name. Signing in happens on the web.")
            + " Sessions reach each one by its name, as codemode.\(added.first?.name ?? "name").*")
      }

      Section("Recent activity") {
        if added.isEmpty {
          Text("Nothing yet.").foregroundStyle(.secondary)
        }
        ForEach(added) { server in CallsList(model: model, service: server.name, limit: added.count > 1 ? 5 : 20) }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(ChatColors.background)
    .navigationTitle(known.title)
    .navigationBarTitleDisplayMode(.inline)
    .appsNotice(model)
  }

  private func add() {
    guard let name = adding else { return }
    Task {
      switch await model.addServer(name: name, url: known.url) {
      case .added: adding = nil
      case .needsSignIn:
        adding = nil
        openURL(model.webPage(for: nil))
      case .failed: break
      }
    }
  }
}

/// Every MCP server the person added, and adding any other by its URL.
struct ServersPageView: View {
  let model: AppsModel
  @Environment(\.openURL) private var openURL
  @State private var name = ""
  @State private var url = ""

  var body: some View {
    List {
      Section {
        if model.servers.isEmpty {
          Text("No servers yet.").foregroundStyle(.secondary)
        }
        ForEach(model.servers) { server in
          ServerRow(model: model, server: server).modifier(RemovableServer(model: model, server: server))
        }
      } footer: {
        Text("Add any MCP server, and your Sessions can use its tools.")
      }

      Section("Add server") {
        TextField("Name, e.g. emdash: leostera.com", text: $name)
          .autocorrectionDisabled()
          .accessibilityIdentifier("server-name")
        TextField("https://mcp.example.com/mcp", text: $url)
          .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
          .accessibilityIdentifier("server-url")
        Button("Add") { add() }
          .disabled(model.isBusy || name.trimmingCharacters(in: .whitespaces).isEmpty || !url.lowercased().hasPrefix("https://"))
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(ChatColors.background)
    .navigationTitle("MCP servers")
    .navigationBarTitleDisplayMode(.inline)
    .appsNotice(model)
  }

  private func add() {
    Task {
      switch await model.addServer(name: name, url: url) {
      case .added:
        name = ""
        url = ""
      case .needsSignIn:
        name = ""
        url = ""
        openURL(model.webPage(for: nil))
      case .failed: break
      }
    }
  }
}

/// What Sessions used in the last 30 days, and whether the log is as it was written.
struct ActivityView: View {
  let model: AppsModel

  var body: some View {
    List {
      Section { IntegrityRow(model: model) }
      Section { CallsList(model: model, service: nil, limit: 50) } footer: {
        Text("What your Sessions used in the last 30 days.")
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(ChatColors.background)
    .navigationTitle("Activity")
    .navigationBarTitleDisplayMode(.inline)
  }
}
