import AuthenticationServices
import AxoClient
import AxoProtocol
import SwiftUI

/// Settings › Devices (RFD0077): the phones and browsers that answer for this Mac, those waiting
/// to, and this Mac's key for them to compare.
struct DevicesSettingsView: View {
  @State private var model: DevicesModel
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @State private var signingIn = false
  @State private var signInFailure: String?

  init(client: AxodDevicesClient?) {
    _model = State(initialValue: DevicesModel(client: client))
  }

  var body: some View {
    Form {
      Section("Linked Axos") {
        if model.needsSignIn {
          Button(signingIn ? "Signing in…" : "Sign in with Cloudflare") { Task { await signIn() } }
            .disabled(signingIn)
          Text("Sign in to connect this Axo, then scan its linking code with your phone. No pairing code to copy.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if model.linkCompleted { Label("Axo linked", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        if let signInFailure { Text(signInFailure).font(.caption).foregroundStyle(.secondary) }
        Button("Show linking code") { Task { await model.createLinkCode() } }
          .disabled(model.creatingLinkCode || model.needsSignIn || signingIn).accessibilityIdentifier("linkPhone")
        Text("Scan a QR code with your phone. No fingerprint comparison needed.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("This Mac’s key") {
        Text(model.devices?.inputKey ?? "—")
          .font(.title3.monospaced().weight(.semibold))
          .textSelection(.enabled)
          .accessibilityIdentifier("macInputKeyFingerprint")
        Text("Before a phone or a browser first sends a password or a code to this Mac, it shows a key. Confirm there only if it shows these same characters.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section("Waiting") {
        if let waiting = model.devices?.waiting, !waiting.isEmpty {
          ForEach(waiting) { device in
            DeviceRow(device: device, busy: model.busy.contains(device.key)) {
              Button("Not mine") { Task { await model.decide(device.key, allow: false) } }
              Button("Allow") { Task { await model.decide(device.key, allow: true) } }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("deviceAllow")
            }
          }
          Text("Allow a device only if it shows these same characters. It can then say yes to agents and computer use here.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text("A phone or a browser that answers a question here for the first time waits here.")
            .foregroundStyle(.secondary)
        }
      }

      Section("Allowed") {
        if let allowed = model.devices?.allowed, !allowed.isEmpty {
          ForEach(allowed) { device in
            DeviceRow(device: device, busy: model.busy.contains(device.key)) {
              Button("Remove") { Task { await model.revoke(device.key) } }
            }
          }
        } else {
          Text("No device answers for this Mac yet.").foregroundStyle(.secondary)
        }
      }

      if let failure = model.failure {
        Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
    }
    .formStyle(.grouped)
    .sheet(item: Binding(get: { model.linkCode }, set: { if $0 == nil { Task { await model.cancelLinkCode() } } })) { code in
      DeviceLinkCodeView(code: code, close: { Task { await model.cancelLinkCode() } })
    }
    // A device that answers asks while this shows; the list is axod's, so read it again.
    .task {
      while !Task.isCancelled {
        await model.refresh()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }
  private func signIn() async {
    guard !signingIn else { return }
    signingIn = true
    signInFailure = nil
    defer { signingIn = false }
    let flow = NativeSignIn()
    let attempt = flow.begin()
    do {
      let callback = try await webAuthenticationSession.authenticate(using: attempt.url, callbackURLScheme: NativeSignIn.callbackScheme)
      let session = try await flow.complete(attempt, callback: callback)
      try await model.linkToAccount(using: session.token)
    } catch ASWebAuthenticationSessionError.canceledLogin {
      // Closing system authentication is not a failed pairing.
    } catch { signInFailure = "This Mac could not finish connecting. No existing device keys were changed." }
  }
}

private struct DeviceRow<Actions: View>: View {
  let device: AnsweringDevice
  let busy: Bool
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(device.name)
        Text(device.fingerprint)
          .font(.body.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      if busy { ProgressView().controlSize(.small) }
      actions().disabled(busy)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("deviceRow")
  }
}
