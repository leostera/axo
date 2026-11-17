import AxoMobileModel
import SwiftUI

struct AppCatalogTile: Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let detail: String
  let category: String
  let provider: String
  let connected: Bool
  let logo: AppLogo.Source
  let route: AppsRoute
}

/// The web catalog's cards and filters, adapted to the current iPad detail width.
struct AppsGridView: View {
  let model: AppsModel
  let tiles: [AppCatalogTile]
  @Binding var query: String
  @State private var status: Status = .all
  @State private var category: String?
  @FocusState private var searching: Bool

  private enum Status: String, CaseIterable {
    case all, connected, notConnected
    var title: String {
      switch self {
      case .all: "All"
      case .connected: "Connected"
      case .notConnected: "Not connected"
      }
    }
    func includes(_ tile: AppCatalogTile) -> Bool {
      self == .all || tile.connected == (self == .connected)
    }
  }

  private var categories: [String] {
    tiles.map(\.category).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
  }

  private var shown: [AppCatalogTile] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = tiles.filter {
      status.includes($0) && (category == nil || category == $0.category)
        && (needle.isEmpty || "\($0.title) \($0.subtitle) \($0.provider)".localizedCaseInsensitiveContains(needle))
    }
    return filtered.filter(\.connected) + filtered.filter { !$0.connected }
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 16) {
        searchField
        if geometry.size.width >= 720 {
          HStack(alignment: .top, spacing: 20) {
            ScrollView { filterRail }.frame(width: 160)
            catalog
          }
        } else {
          compactFilters
          catalog
        }
      }
      .padding(20)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("apps-grid-page")
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Search apps", text: $query)
        .textFieldStyle(.plain).autocorrectionDisabled().textInputAutocapitalization(.never)
        .focused($searching).submitLabel(.search).onSubmit { searching = false }
        .accessibilityIdentifier("apps-grid-search")
      if !query.isEmpty {
        Button { query = "" } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44)
        }
          .buttonStyle(.plain).accessibilityLabel("Clear app search")
      }
    }
    .padding(.horizontal, 12).frame(height: 48)
    .background(ChatColors.surface, in: RoundedRectangle(cornerRadius: 12))
  }

  private var compactFilters: some View {
    VStack(spacing: 10) {
      Picker("Status", selection: $status) {
        ForEach(Status.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      HStack {
        Text("Category").foregroundStyle(.secondary)
        Spacer()
        Picker("Category", selection: $category) {
          Text("All categories").tag(String?.none)
          ForEach(categories, id: \.self) { Text(AppsCatalog.categoryTitle($0)).tag(Optional($0)) }
        }.pickerStyle(.menu)
      }
    }
  }

  private var filterRail: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Status").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
      ForEach(Status.allCases, id: \.self) { value in
        filterButton(value.title, count: tiles.filter { value.includes($0) }.count,
          selected: status == value, id: "apps-status-\(value.rawValue)") { status = value }
      }
      Text("Category").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.top, 20).padding(.bottom, 4)
      filterButton("All", count: tiles.count, selected: category == nil, id: "apps-category-all") { category = nil }
      ForEach(categories, id: \.self) { value in
        filterButton(AppsCatalog.categoryTitle(value), count: tiles.filter { $0.category == value }.count,
          selected: category == value, id: "apps-category-\(value)") { category = value }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("apps-filters")
  }

  private func filterButton(_ title: String, count: Int, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
    Button { searching = false; action() } label: {
      HStack {
        Text(title).lineLimit(1)
        Spacer(minLength: 4)
        Text(count.formatted()).foregroundStyle(.secondary)
      }
      .font(.callout).padding(.horizontal, 8).frame(minHeight: 36)
      .background(selected ? ChatColors.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title).accessibilityValue(count.formatted())
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier(id)
  }

  private var catalog: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        switch model.phase {
        case .idle, .loading: LoadingRow(label: "Loading apps")
        case .failed(let message):
          Text(message).foregroundStyle(.secondary)
          Button("Try again") { Task { await model.refresh() } }
        case .loaded:
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(shown) { tile in card(tile) }
            if status == .all, category == nil || category == "mcp", query.isEmpty {
              NavigationLink(value: AppsRoute.servers) {
                VStack(spacing: 8) {
                  AppLogo(source: .server(nil), size: 56)
                  Text("Add MCP server").font(.callout.weight(.semibold))
                  Text("Any server with a URL").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 148)
                .background(ChatColors.surface, in: RoundedRectangle(cornerRadius: 16))
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain).accessibilityLabel("Add MCP server")
            }
          }
          if shown.isEmpty {
            ContentUnavailableView("No apps match", systemImage: "magnifyingglass",
              description: Text("Try a different search or filter."))
              .accessibilityIdentifier("apps-grid-empty")
          }
          if query.isEmpty, status == .all, category == nil {
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Text("Recent activity").font(.headline)
                Spacer()
                NavigationLink("See all", value: AppsRoute.activity)
              }
              IntegrityRow(model: model)
              CallsList(model: model, service: nil, limit: 5)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("apps-grid")
  }

  private func card(_ tile: AppCatalogTile) -> some View {
    NavigationLink(value: tile.route) {
      VStack(spacing: 8) {
        AppLogo(source: tile.logo, size: 56)
        Text(tile.title).font(.callout.weight(.semibold)).lineLimit(1)
        HStack(spacing: 5) {
          if tile.connected { Circle().fill(.green).frame(width: 6, height: 6) }
          Text(tile.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 148)
      .background(ChatColors.surface, in: RoundedRectangle(cornerRadius: 16))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore).accessibilityLabel(tile.title)
    .accessibilityValue(tile.connected ? "Connected, \(tile.detail)" : tile.detail)
    .accessibilityAddTraits(.isButton)
  }
}
