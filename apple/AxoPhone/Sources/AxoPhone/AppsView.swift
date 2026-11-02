import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// Settings › Apps (RFD0016): every app Axo provides and every MCP server, connected ones first,
/// then by category, and what Sessions used lately. Each opens a page of its own.
struct AppsView: View {
  let model: AppsModel
  @State private var query = ""
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    List {
      switch model.phase {
      case .idle, .loading:
        Section { LoadingRow(label: "Loading apps") }
      case .failed(let message):
        Section {
          Text(message).foregroundStyle(.secondary)
          Button("Try again") { Task { await model.refresh() } }
        }
      case .loaded:
        tiles
        if query.isEmpty { activity }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(ChatColors.background)
    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search apps")
    .navigationTitle("Apps")
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(for: AppsRoute.self) { route in
      switch route {
      case .app(let name): AppPageView(model: model, name: name)
      case .server(let id): KnownServerPageView(model: model, known: KnownServer.all.first { $0.id == id }!)
      case .servers: ServersPageView(model: model)
      case .activity: ActivityView(model: model)
      }
    }
    .refreshable { await Task { await model.refresh() }.value }
    .task { await model.refresh() }
    // Back from a sign-in on the web: what it added shows.
    .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refresh() } } }
    .appsNotice(model)
    .accessibilityIdentifier("apps")
  }

  // MARK: - Tiles

  private struct Tile: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let detail: String
    let category: String
    let connected: Bool
    let logo: AppLogo.Source
    let route: AppsRoute
  }

  private var allTiles: [Tile] {
    let apps = model.apps.map { app in
      Tile(
        id: app.name, title: app.title, subtitle: app.description, detail: AppsCatalog.detail(of: app),
        category: app.category, connected: app.isConnected, logo: .app(app.name), route: .app(app.name))
    }
    let known = KnownServer.all.map { known in
      let added = model.servers.filter { KnownServer.of(url: $0.url)?.id == known.id }
      return Tile(
        id: "mcp:\(known.id)", title: known.title, subtitle: known.description,
        detail: added.isEmpty ? "Add" : AppsCatalog.count(added.count, "account"), category: known.category,
        connected: added.contains { $0.state == .ready }, logo: .known(known), route: .server(known.id))
    }
    let byURL = model.servers.filter { KnownServer.of(url: $0.url) == nil }.map { server in
      Tile(
        id: server.name, title: server.displayName, subtitle: Self.host(server.url), detail: ServerRow.state(of: server),
        category: "mcp", connected: server.state == .ready, logo: .server(server.icon), route: .servers)
    }
    return apps + known + byURL
  }

  private var shownTiles: [Tile] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return allTiles }
    return allTiles.filter { "\($0.title) \($0.subtitle)".lowercased().contains(needle) }
  }

  @ViewBuilder private var tiles: some View {
    let shown = shownTiles
    let connected = shown.filter(\.connected)
    if !connected.isEmpty {
      Section("Connected") { ForEach(connected) { tileRow($0) } }
    }
    let rest = shown.filter { !$0.connected }
    let categories = rest.map(\.category).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    ForEach(categories, id: \.self) { category in
      Section(AppsCatalog.categoryTitle(category)) {
        ForEach(rest.filter { $0.category == category }) { tileRow($0) }
      }
    }
    if query.isEmpty {
      Section {
        NavigationLink(value: AppsRoute.servers) {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("MCP servers")
              Text("Add any server with a URL").font(.caption).foregroundStyle(.secondary)
            }
          } icon: {
            AppLogo(source: .server(nil), size: 30)
          }
        }
      }
    } else if shown.isEmpty {
      Section { Text("No app matches “\(query)”.").foregroundStyle(.secondary) }
    }
  }

  private func tileRow(_ tile: Tile) -> some View {
    NavigationLink(value: tile.route) {
      HStack(spacing: 12) {
        AppLogo(source: tile.logo, size: 30)
        VStack(alignment: .leading, spacing: 2) {
          Text(tile.title).lineLimit(1)
          HStack(spacing: 5) {
            if tile.connected { Circle().fill(Color.green).frame(width: 6, height: 6) }
            Text(tile.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(tile.title)
    .accessibilityValue(tile.connected ? "Connected, \(tile.detail)" : tile.detail)
    .accessibilityAddTraits(.isButton)
  }

  // MARK: - Activity

  @ViewBuilder private var activity: some View {
    Section {
      IntegrityRow(model: model)
      CallsList(model: model, service: nil, limit: 5)
      NavigationLink("See all activity", value: AppsRoute.activity)
    } header: {
      Text("Recent activity")
    }
  }

  static func host(_ url: String) -> String { URL(string: url)?.host() ?? url }
}

/// A page under Settings › Apps.
enum AppsRoute: Hashable {
  case app(String)
  case server(String)
  case servers
  case activity
}

/// A maker's logo on a rounded tile, or a plug for a server without one.
struct AppLogo: View {
  enum Source: Equatable {
    case app(String)
    case known(KnownServer)
    /// An MCP server added by URL: the icon its site declares, if any.
    case server(String?)
  }

  let source: Source
  var size: CGFloat = 30

  /// Logos drawn as a full tile of their own, not a mark on white.
  private static let full: Set<String> = ["hetzner", "wise", "kraken", "unifi", "stripe"]

  private var logoName: String? {
    switch source {
    case .app(let name): name.hasPrefix("apps.") ? String(name.dropFirst(5)) : name
    case .known(let known): known.logo
    case .server: nil
    }
  }

  var body: some View {
    let corner = size * 0.24
    Group {
      if let name = logoName, let image = UIImage(named: "logo-\(name)") {
        let full = Self.full.contains(name)
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .padding(full ? 0 : size * 0.16)
          .frame(width: size, height: size)
          .background(Color.white)
      } else if case .server(let icon?) = source, let url = URL(string: icon) {
        AsyncImage(url: url) { image in
          image.resizable().scaledToFit().padding(size * 0.14)
        } placeholder: {
          plug
        }
        .frame(width: size, height: size)
        .background(Color.white)
      } else {
        plug.frame(width: size, height: size).background(ChatColors.inset)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    .accessibilityHidden(true)
  }

  private var plug: some View {
    Image(systemName: "powerplug").font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(.secondary)
  }
}

/// Whether the call log is as it was written.
struct IntegrityRow: View {
  let model: AppsModel
  @State private var check: CallLogIntegrity?

  var body: some View {
    Group {
      if let check {
        Label {
          Text(
            check.verified
              ? "Log intact · \(AppsCatalog.count(check.events, "entry", "entries"))"
              : "Log was changed: \(check.reason ?? "unknown")")
            .font(.footnote)
        } icon: {
          Image(systemName: check.verified ? "checkmark.seal" : "exclamationmark.triangle")
            .foregroundStyle(check.verified ? .green : .orange)
        }
        .accessibilityIdentifier("log-integrity")
      }
    }
    .task { check = try? await model.integrity() }
  }
}

/// Recent calls, of every app and server or of one.
struct CallsList: View {
  let model: AppsModel
  let service: String?
  var limit = 50
  @State private var records: [CallRecord]?
  @State private var failed = false

  var body: some View {
    Group {
      if let records {
        if records.isEmpty {
          Text("Nothing yet.").foregroundStyle(.secondary)
        }
        ForEach(records) { record in CallRow(record: record, ofOne: service != nil, titles: titles) }
      } else {
        Text(failed ? "Activity is unavailable." : "Loading…").foregroundStyle(.secondary)
      }
    }
    .task(id: model.apps.map(\.accounts)) {
      do {
        records = try await model.calls(of: service, limit: limit)
      } catch is CancellationError {
      } catch {
        failed = true
      }
    }
  }

  private var titles: [String: String] {
    Dictionary(model.apps.map { ($0.name, $0.title) }, uniquingKeysWith: { first, _ in first })
  }
}

private struct CallRow: View {
  let record: CallRecord
  let ofOne: Bool
  let titles: [String: String]

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: icon).foregroundStyle(color).font(.footnote.weight(.semibold))
      VStack(alignment: .leading, spacing: 2) {
        Text(AppsCatalog.callTitle(record, ofOne: ofOne, titles: titles)).font(.callout).lineLimit(1)
        let summary = AppsCatalog.summary(record)
        if !summary.isEmpty {
          Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer(minLength: 4)
      if let date = record.date {
        Text(date, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var icon: String {
    switch record.outcome {
    case .ok: "checkmark"
    case .error: "xmark"
    case .unknown: "questionmark"
    }
  }

  private var color: Color {
    switch record.outcome {
    case .ok: .green
    case .error: .red
    case .unknown: .secondary
    }
  }
}

/// A row while something loads.
struct LoadingRow: View {
  let label: String
  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
      Text(label).foregroundStyle(.secondary)
    }
  }
}

extension View {
  /// The model's notice, as a banner at the bottom that goes by itself.
  func appsNotice(_ model: AppsModel) -> some View {
    overlay(alignment: .bottom) {
      if let notice = model.notice {
        Text(notice.text)
          .font(.callout)
          .foregroundStyle(notice.kind == .problem ? Color.orange : Color.primary)
          .padding(.horizontal, 16).padding(.vertical, 10)
          .background(.regularMaterial, in: Capsule())
          .padding(.horizontal, 20).padding(.bottom, 12)
          .onTapGesture { model.dismissNotice() }
          .task(id: notice) {
            try? await Task.sleep(for: .seconds(4))
            if model.notice == notice { model.dismissNotice() }
          }
          .accessibilityIdentifier("apps-notice")
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.snappy, value: model.notice)
  }
}
