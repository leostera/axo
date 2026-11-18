import AxoProtocol
import SwiftUI

/// Settings › Devices (RFD0069): the phones and browsers that answer for this Mac, those waiting
/// to, and this Mac's key for them to compare.
struct DevicesSettingsView: View {
  @State private var model: DevicesModel

  init(client: AxodDevicesClient?) {
    _model = State(initialValue: DevicesModel(client: client))
  }

  var body: some View {
    Form {
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
    // A device that answers asks while this shows; the list is axod's, so read it again.
    .task {
      while !Task.isCancelled {
        await model.refresh()
        try? await Task.sleep(for: .seconds(2))
      }
    }
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
