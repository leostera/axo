import Foundation
import WidgetKit

/// Local discovery evidence, not a visual claim. No face IDs, account data, or error payloads.
enum WatchComplicationReport {
  @MainActor static func capture() async {
    var report: [String: Any] = [
      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
      "renderer": "native-mascot-path-v1",
      "updatedAt": ISO8601DateFormatter().string(from: Date()),
    ]
    do {
      let configured = try await WidgetCenter.shared.currentConfigurations()
        .filter { $0.kind == "dev.leostera.axo.mascot" }
      report["status"] = "available"
      report["configuredCount"] = configured.count
      report["families"] = Array(Set(configured.map { String(describing: $0.family) })).sorted()
    } catch { report["status"] = "unavailable" }
    do {
      let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        .write(to: directory.appendingPathComponent("watch-complication.json"), options: .atomic)
    } catch { /* Diagnostics never interfere with startup. */ }
  }
}
