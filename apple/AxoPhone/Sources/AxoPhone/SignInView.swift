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

  /// Cloudflare's orange, for the button that signs in with it.
  private static let cloudflareOrange = Color(red: 0xF3 / 255, green: 0x80 / 255, blue: 0x20 / 255)

  /// Which build this is, for bug reports: "0.1.0 (12)". Build 0 is an unstamped development build.
  private static var buildLine: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "axo \(version) (\(build))"
  }

  /// Long enough for the hands to come down before the app takes over.
  private static let uncoverPause: Duration = .milliseconds(650)

  var body: some View {
    VStack(spacing: 20) {
      Spacer()
      AxoMascotView(mascot: mascot)
        .frame(height: 96)
      Text("axo")
        .font(.custom("Fredoka-Bold", size: 128, relativeTo: .largeTitle))
        .accessibilityLabel("Axo")
      // Yes, olotl. Axo is an axolotl.
      Text("your agentic experience olotl")
        .foregroundStyle(.secondary)
      Spacer()
      if let message = message ?? account.signInFailure {
        Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
      }
      Button {
        Task { await signIn() }
      } label: {
        HStack {
          if working { ProgressView().tint(Self.cloudflareOrange) }
          Text("Continue with Cloudflare").bold()
        }
        .foregroundStyle(Self.cloudflareOrange)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Capsule())
        .overlay { Capsule().stroke(Self.cloudflareOrange, lineWidth: 1.5) }
      }
      .buttonStyle(.plain)
      .opacity(working ? 0.6 : 1)
      .disabled(working)
      Text(Self.buildLine)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .accessibilityIdentifier("build-number")
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
