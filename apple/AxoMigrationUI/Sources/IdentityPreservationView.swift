import AxoMobileModel
import SwiftUI

/// Intentionally no account, companion, workbench or signer creation behind this destination.
public struct IdentityPreservationView: View {
  private let role: EnclavePreservationProbe.Role
  @State private var report: EnclaveProbeRuntime.Report?

  public init(role: EnclavePreservationProbe.Role) { self.role = role }

  public var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        Text("Identity preservation").font(.headline)
        Text(report?.message ?? "Checking the existing approval identity…")
          .accessibilityIdentifier("identity-preservation-status")
        Text("Sign-in migration is not complete. Keep the previous Axo app installed.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Check again") { check() }
          .accessibilityIdentifier("identity-preservation-retry")
      }
      .multilineTextAlignment(.center).padding()
    }
    .task { check() }
  }

  private func check() { report = EnclaveProbeRuntime.runIfRequested(role: role) }
}
