import AVFoundation
import AxoClient
import AxoMobileModel
import AxoProtocol
import SwiftUI

struct LinkedDevicesView: View {
  let account: AccountSession
  let hosts: HostsModel
  let onboarding: Bool
  @State private var checkedOnboarding = false
  @State private var model: DeviceLinkingModel
  @State private var scanning = false
  @State private var cameraFailure = false
  @State private var unlinking: LinkedClient?
  @State private var scanAfterCodeDismiss = false

  init(account: AccountSession, hosts: HostsModel, onboarding: Bool = false) {
    self.account = account; self.hosts = hosts; self.onboarding = onboarding
    #if DEBUG && targetEnvironment(simulator)
      if PreviewFixture.requested {
        let signer = SoftwareDeviceSigner()
        let suite = "preview.deviceLinking"
        let storage = UserDefaults(suiteName: suite)!
        storage.removePersistentDomain(forName: suite)
        _model = State(initialValue: DeviceLinkingModel(client: PreviewDeviceLinkingClient(), tokens: account.tokens,
          name: "Preview iPad", defaults: storage, signer: { signer }))
        return
      }
    #endif
    _model = State(initialValue: DeviceLinkingModel(
      client: AccountClient(endpoint: AppEnvironment.shared.endpoint, tokens: account.tokens),
      tokens: account.tokens, name: UIDevice.current.name))
  }

  var body: some View {
    List {
      Section {
        Button {
          model.cancel()
          Task { await openScanner() }
        } label: { Label("Link another Axo", systemImage: "qrcode.viewfinder") }
          .disabled(model.phase == .linking)
          .accessibilityIdentifier("link-device")
        Button { Task { await model.showCode() } } label: {
          Label("Show linking code", systemImage: "qrcode")
        }.disabled(model.phase == .linking).accessibilityIdentifier("show-link-code")
      } footer: {
        Text("Show a linking code on the other Axo, then scan it here. This phone keeps its existing identity.")
      }
      if model.linkedHosts.isEmpty {
        Section {
          Text("No other Axos linked yet").foregroundStyle(.secondary)
          Text(hosts.hosts.isEmpty
            ? "This phone is ready to be your linking hub. Open Axo on the computer you want to link, sign in, then choose Show linking code."
            : "To link with an existing Axo, open its Linked Axos settings and choose Show linking code.")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Section("Computers") {
          ForEach(model.linkedHosts) { host in
            Label {
              VStack(alignment: .leading, spacing: 4) {
                Text(hosts.hosts.first(where: { $0.hostId == host.hostId })?.label ?? "Axo")
                Text(host.canLinkDevices ? "This phone can approve requests and link devices" : "Can approve requests")
                  .font(.caption).foregroundStyle(.secondary)
              }
            } icon: { Image(systemName: "desktopcomputer") }
          }
        }
      }
      if !model.linkedClients.isEmpty {
        Section("Other Axos") {
          ForEach(model.linkedClients) { client in
            HStack {
              Label(client.name, systemImage: "ipad.and.iphone")
              Spacer()
              Button("Unlink", role: .destructive) { unlinking = client }.disabled(model.phase == .linking)
            }
          }
        }
      }
      switch model.phase {
      case .linking: Section { ProgressView("Linking device…") }
      case .linked: Section { Label("Axo linked", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
      case .failed(let message): Section { Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
      case .waiting: Section { Text("Waiting for approval on your existing phone").foregroundStyle(.secondary) }
      case .confirming(let name):
        Section("Link \(name)?") {
          Text("This device will be able to approve requests and enter sign-in details on the computers linked to this phone. It will not be able to link more Axos.")
            .fixedSize(horizontal: false, vertical: true)
          HStack {
            Spacer()
            Button("Don’t allow") { Task { await model.decideScannedClient(allow: false) } }
            Button("Allow") { Task { await model.decideScannedClient(allow: true) } }.buttonStyle(.borderedProminent)
          }
        }
      case .idle: EmptyView()
      }
    }
    .navigationTitle("Linked Axos").navigationBarTitleDisplayMode(.inline)
    .task(id: account.credentialRevision) { await model.load(); await beginOnboardingIfReady() }
    .onChange(of: hosts.phase) { _, _ in Task { await beginOnboardingIfReady() } }
    .sheet(item: Binding(get: { model.clientCode }, set: { if $0 == nil, model.clientCode != nil { Task { await model.cancelWaiting() } } }), onDismiss: {
      if scanAfterCodeDismiss { scanAfterCodeDismiss = false; Task { await openScanner() } }
    }) { code in
      ClientLinkCodeView(code: code, model: model, useExistingHost: {
        scanAfterCodeDismiss = true
        Task { await model.cancelWaiting() }
      })
    }
    .sheet(isPresented: $scanning) {
      NavigationStack {
        DeviceQRScanner(scanned: { text in
          scanning = false
          Task { await model.scan(text) }
        }, failed: { scanning = false; cameraFailure = true })
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("Link another Axo").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) { Button("Cancel") { scanning = false } }
        }
        .safeAreaInset(edge: .bottom) {
          Text("Scan the linking code shown by the other Axo. Never share the code or send it to an agent.")
            .font(.callout).multilineTextAlignment(.center).padding().background(.regularMaterial)
        }
      }
    }
    .confirmationDialog("Unlink this device?", isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }), titleVisibility: .visible) {
      if let client = unlinking {
        Button("Unlink \(client.name)", role: .destructive) { Task { await model.unlink(client) }; unlinking = nil }
      }
      Button("Cancel", role: .cancel) { unlinking = nil }
    } message: { Text("It will no longer be able to approve requests on the computers linked through this phone. Its sign-in and conversations are not deleted.") }
    .alert("Camera unavailable", isPresented: $cameraFailure) {
      Button("OK", role: .cancel) {}
    } message: { Text("Allow camera access for Axo in Settings, or try on a device that supports QR scanning.") }
  }

  private func openScanner() async {
    let allowed: Bool
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: allowed = true
    case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
    default: allowed = false
    }
    if allowed { scanning = true } else { cameraFailure = true }
  }

  private func beginOnboardingIfReady() async {
    guard onboarding, !checkedOnboarding, hosts.phase == .loaded, model.phase == .idle else { return }
    checkedOnboarding = true
    if model.linkedHosts.isEmpty, !hosts.hosts.isEmpty { await model.showCode() }
  }
}
