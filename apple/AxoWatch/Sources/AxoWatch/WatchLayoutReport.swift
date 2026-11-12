import Foundation

/// Geometry only: no session names, identifiers, message text, audio, or arbitrary errors.
/// A runtime marker also distinguishes this layout from an older process after installation.
enum WatchLayoutReport {
  static func write(recording: Bool, busy: Bool, conversationHeight: CGFloat, footerHeight: CGFloat) {
    let report: [String: Any] = [
      "layout": "fixed-footer-v2",
      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
      "recording": recording, "busy": busy,
      "conversationHeight": Double(conversationHeight), "footerHeight": Double(footerHeight),
      "updatedAt": ISO8601DateFormatter().string(from: Date()),
    ]
    do {
      let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        .write(to: directory.appendingPathComponent("watch-layout.json"), options: .atomic)
    } catch { /* Diagnostics never interrupt a conversation or recording. */ }
  }
}
