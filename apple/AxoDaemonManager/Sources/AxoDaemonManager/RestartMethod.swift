import CryptoKit
import Foundation
import Security

/// What launchd was given when the LaunchAgent was registered: which app bundle (its
/// `BundleProgram` resolves inside it), the exact plist, and who signed the program it runs.
struct LaunchAgentDefinition: Codable, Equatable {
  var bundlePath: String
  var plistSHA256: String
  /// `<team>:<signing identifier>` of the `BundleProgram`. Background Task Management approves
  /// the agent for that identity, and launchd refuses a program signed as anything else (a
  /// Launch Constraint Violation) until the agent is registered again. `nil` in definitions
  /// recorded before it existed, which makes the next restart register again.
  var programSigningIdentity: String? = nil

  /// The definition this app would register, or `nil` when its plist cannot be read.
  /// `programPath` is the `BundleProgram`, relative to the bundle.
  static func current(
    bundle: Bundle, plistName: String, programPath: String? = nil
  ) -> LaunchAgentDefinition? {
    let plist = bundle.bundleURL
      .appendingPathComponent("Contents/Library/LaunchAgents")
      .appendingPathComponent(plistName)
    guard let data = try? Data(contentsOf: plist) else { return nil }
    return LaunchAgentDefinition(
      bundlePath: bundle.bundleURL.standardizedFileURL.path,
      plistSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      programSigningIdentity: programPath.flatMap {
        signingIdentity(of: bundle.bundleURL.appendingPathComponent($0))
      })
  }

  static func signingIdentity(of program: URL) -> String? {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(program as CFURL, [], &code) == errSecSuccess, let code
    else { return nil }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let information = information as? [String: Any],
      let identifier = information[kSecCodeInfoIdentifier as String] as? String
    else { return nil }
    let team = information[kSecCodeInfoTeamIdentifier as String] as? String ?? "-"
    return "\(team):\(identifier)"
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
