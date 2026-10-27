import AxoClient
import AxoPhoneModel
import SwiftUI

/// Linking a Mac: a code to type into Axo on the Mac (or a link to open there), shown until the
/// Mac takes it. The sheet's task asks for the code; closing the sheet stops waiting.
struct PairMacSheet: View {
  @State private var pairing: MacPairing
  @Environment(\.dismiss) private var dismiss

  init(issuer: any HostPairingIssuing, hosts: HostsModel) {
    _pairing = State(initialValue: MacPairing(issuer: issuer, hosts: hosts))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 20) {
        content
      }
      .padding(.horizontal, 28)
      .padding(.top, 8)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .navigationTitle("Pair a Mac")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(isLinked ? "Done" : "Cancel") { dismiss() }
        }
      }
    }
    // Restarted by "New code" through `attempt`.
    .task(id: attempt) { await pairing.run() }
    .presentationDetents([.large])
  }

  @State private var attempt = 0

  private var isLinked: Bool {
    if case .linked = pairing.state { true } else { false }
  }

  @ViewBuilder private var content: some View {
    switch pairing.state {
    case .creating:
      LoadingMascotView(label: "Getting a code")
        .frame(width: 96, height: 96)
        .padding(.top, 40)
      Text("Getting a code…").foregroundStyle(.secondary)
    case .waiting(let code):
      CodeView(pairing: code)
    case .linked(let label):
      OwnMascotView()
        .frame(width: 150)
        .padding(.top, 40)
      Text("\(label) is paired").font(.title2.weight(.semibold))
        .accessibilityIdentifier("pairing-linked")
      Text("Its chats are in the menu now.").foregroundStyle(.secondary)
    case .expired:
      Text("The code expired").font(.title3.weight(.semibold)).padding(.top, 40)
      Text("Codes last ten minutes. Get a new one and enter it on your Mac.")
        .foregroundStyle(.secondary).multilineTextAlignment(.center)
      newCodeButton
    case .failed(let message):
      Text("No code").font(.title3.weight(.semibold)).padding(.top, 40)
      Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
      newCodeButton
    }
  }

  private var newCodeButton: some View {
    Button("Get a new code") { attempt += 1 }
      .buttonStyle(.borderedProminent)
  }
}

/// The code, big enough to read across a desk, with how to use it and how long it lasts.
private struct CodeView: View {
  let pairing: HostPairing

  var body: some View {
    Text("On your Mac, open Axo → Settings → Remote Access, and enter this code under Link this Mac.")
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(.top, 12)
    Text(pairing.code.value)
      .font(.system(size: 44, weight: .semibold, design: .monospaced))
      .kerning(2)
      .textSelection(.enabled)
      .padding(.vertical, 18)
      .frame(maxWidth: .infinity)
      .background(ChatColors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .accessibilityLabel(pairing.code.value.map(String.init).joined(separator: " "))
      .accessibilityIdentifier("pairing-code")
    TimelineView(.periodic(from: .now, by: 1)) { context in
      Text("Expires in \(remaining(at: context.date))")
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    HStack(spacing: 12) {
      Button {
        UIPasteboard.general.string = pairing.code.value
      } label: {
        Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
      }
      // Opened on the Mac (AirDrop, Messages, Notes…), the link fills the code in.
      ShareLink(item: pairing.link, message: Text("Pair this Mac with Axo: \(pairing.code.value)")) {
        Label("Send to Mac", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
    HStack(spacing: 10) {
      ProgressView()
      Text("Waiting for your Mac…").foregroundStyle(.secondary)
    }
    .padding(.top, 8)
  }

  private func remaining(at date: Date) -> String {
    let seconds = max(Int(pairing.expiresAt.timeIntervalSince(date)), 0)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
