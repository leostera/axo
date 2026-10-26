import AxoClient
import AxoPhoneModel
import AxoProtocol
import SwiftUI

struct HostsView: View {
  let environment: AppEnvironment
  @State private var model: HostsModel

  init(environment: AppEnvironment) {
    self.environment = environment
    let client = AccountClient(endpoint: environment.endpoint, tokens: environment.account.tokens)
    _model = State(initialValue: HostsModel(listing: client, account: environment.account))
  }

  var body: some View {
    NavigationStack {
      List {
        if case .failed(let message) = model.phase {
          Text(message).foregroundStyle(.red)
        }
        ForEach(model.hosts, id: \.hostId) { host in
          NavigationLink(value: host.hostId) {
            HostRow(host: host)
          }
        }
        if model.phase == .loaded, model.hosts.isEmpty {
          ContentUnavailableView(
            "No Macs yet", systemImage: "laptopcomputer",
            description: Text("On a Mac, open Axo → Settings → Remote Access and link it with a pairing code."))
        }
      }
      .navigationTitle("Your Macs")
      .navigationDestination(for: UUID.self) { id in
        if let host = model.hosts.first(where: { $0.hostId == id }) {
          HostWorkbenchView(host: host, environment: environment)
        }
      }
      .toolbar {
        Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
          environment.account.signOut()
        }
      }
      .refreshable { await model.refresh() }
      .overlay { if model.phase == .loading, model.hosts.isEmpty { ProgressView() } }
    }
    .task { await model.refresh() }
  }
}

private struct HostRow: View {
  let host: RemoteHost

  var body: some View {
    HStack {
      Image(systemName: "laptopcomputer")
      VStack(alignment: .leading) {
        Text(host.label)
        Text(host.status == .online ? "Online" : "Offline")
          .font(.caption)
          .foregroundStyle(host.status == .online ? .green : .secondary)
      }
      Spacer()
      Text("\(host.sessions.count)").foregroundStyle(.secondary)
    }
  }
}
