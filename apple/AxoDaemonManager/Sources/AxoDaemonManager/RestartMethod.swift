import CryptoKit
import Foundation

/// What launchd was given when the LaunchAgent was registered: which app bundle (its
/// `BundleProgram` resolves inside it) and the exact plist.
struct LaunchAgentDefinition: Codable, Equatable {
  var bundlePath: String
  var plistSHA256: String

  /// The definition this app would register, or `nil` when its plist cannot be read.
  static func current(bundle: Bundle, plistName: String) -> LaunchAgentDefinition? {
    let plist = bundle.bundleURL
      .appendingPathComponent("Contents/Library/LaunchAgents")
      .appendingPathComponent(plistName)
    guard let data = try? Data(contentsOf: plist) else { return nil }
    return LaunchAgentDefinition(
      bundlePath: bundle.bundleURL.standardizedFileURL.path,
      plistSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
  }
}

/// How to replace the running axod with this app's build.
enum RestartMethod: Equatable {
  /// launchd already has this exact definition: restart the job in place
  /// (`launchctl kickstart -k`), which runs the new binary from the same bundle path.
  case kickstart
  /// The definition changed, is unknown, or this app cannot read its own: unregister and
  /// register, so launchd reloads the plist.
  case reregister

  static func decide(
    registered: LaunchAgentDefinition?, current: LaunchAgentDefinition?
  ) -> RestartMethod {
    guard let registered, let current, registered == current else { return .reregister }
    return .kickstart
  }
}
