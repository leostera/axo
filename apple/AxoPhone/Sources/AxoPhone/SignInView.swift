import AuthenticationServices
import AxoClient
import AxoPhoneModel
import SwiftUI

/// Sign in with Cloudflare in the system's web-auth sheet. The app only ever sees a one-time code
/// on its own link, which it trades (with a secret it never sent anywhere) for its session.
struct SignInView: View {
  let endpoint: RelayEndpoint
  let account: AccountSession
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @State private var working = false
  @State private var message: String?
  @State private var screen: CGSize = .zero
  @StateObject private var mascot = Mascot()

  /// Long enough for the hands to come down before the app takes over.
  private static let uncoverPause: Duration = .milliseconds(650)

  var body: some View {
    VStack(spacing: 20) {
      Spacer()
      AxoMascotView(mascot: mascot)
        .frame(height: 96)
      Text("Axo").font(.largeTitle.bold())
      Text("Reach your Macs from anywhere.")
        .foregroundStyle(.secondary)
      Spacer()
      if let message = message ?? account.signInFailure {
        Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
      }
      Button {
        Task { await signIn() }
      } label: {
        HStack {
          if working { ProgressView() }
          Text("Continue with Cloudflare").bold()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(working)
      Text("Axo only learns who you are. It never manages your Cloudflare account.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(24)
    .contentShape(Rectangle())
    // A finger held anywhere on the screen: Axo watches it.
    .simultaneousGesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .global)
        .onChanged { mascot.look(at: $0.location, screen: screen) }
        .onEnded { _ in mascot.stopLooking() }
    )
    .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
  }

  private func signIn() async {
    working = true
    message = nil
    defer { working = false }
    let flow = NativeSignIn(endpoint: endpoint)
    let attempt = flow.begin()
    // No peeking while you sign in.
    mascot.stopLooking()
    mascot.cover(true)
    defer { mascot.cover(false) }
    do {
      let callback = try await webAuthenticationSession.authenticate(
        using: attempt.url, callbackURLScheme: NativeSignIn.callbackScheme)
      let session = try await flow.complete(attempt, callback: callback)
      mascot.cover(false)
      try? await Task.sleep(for: Self.uncoverPause)
      account.signIn(with: session.token)
    } catch ASWebAuthenticationSessionError.canceledLogin {
      // The person closed the sheet; nothing to report.
    } catch {
      message = error.localizedDescription
    }
  }
}
