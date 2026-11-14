import AxoDaemonManager
import SwiftUI

/// Values come from the same immutable snapshot the installer downloads and verifies.
struct AppUpgradeDownloadProgress: View {
  let release: PublishedBuild

  var title: String { "Downloading Axo \(release.version)" }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)
      Text("Build \(release.build) · \(release.commit.prefix(7))")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
      ProgressView().controlSize(.small)
      Text("The signed app will be verified before Axo restarts.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(20)
    .frame(width: 340, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }
}
