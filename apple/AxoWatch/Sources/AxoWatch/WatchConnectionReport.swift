import AxoPhoneModel
import Foundation

/// Bounded, non-sensitive device health report for verifying real-watch connectivity without
/// collecting a transcript, an account ID, a credential, or arbitrary error text.
struct WatchConnectionReport: Encodable {
  let build: String
  let transport = "https"
  let state: String
  let updatedAt: Date
  let lastConnectedAt: Date?

  static func write(link: HostWorkbenchModel.Link, lastConnectedAt: Date?) {
    let state: String
    switch link {
    case .idle: state = "idle"
    case .connected: state = "connected"
    case .reconnecting: state = "reconnecting"
    case .suspended: state = "suspended"
    }
    let report = Self(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
      state: state, updatedAt: Date(), lastConnectedAt: lastConnectedAt)
    do {
      let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(report).write(to: directory.appendingPathComponent("watch-connection.json"), options: .atomic)
    } catch {
      // Diagnostics must never affect sign-in, message delivery, or foreground UI.
    }
  }
}
