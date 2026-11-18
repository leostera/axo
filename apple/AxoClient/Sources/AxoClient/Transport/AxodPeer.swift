import Darwin
import Foundation

#if os(macOS)
  import Security
#endif

/// Who must be listening on axod's sockets (RFD0069). Any program running as the person can
/// unlink `axod.sock` and listen in its place, an agent's scripts included, so Axo.app checks the
/// listener's code signature before it sends anything: the same audit-token check axod makes of
/// Axo.app, the other way round.
///
/// The requirement is derived from this app's own designated requirement, with axod's signing
/// identifier in place of its own: same certificate, the program called `axod`. An ad hoc or
/// unsigned build's requirement is a cdhash, which names no program, so it cannot name axod;
/// such a build connects unverified and never sends typed values (`isVerified`).
public struct AxodPeer: Sendable, Equatable {
  /// The code requirement the listener must satisfy; nil when this process cannot name axod.
  public let requirement: String?

  public init(requirement: String?) {
    self.requirement = requirement
  }

  /// axod as this process names it.
  public static let axod = AxodPeer(requirement: ownDesignatedRequirement().flatMap(axodRequirement(fromOwn:)))

  /// Whether a listener is checked at all. Only a checked listener receives typed values.
  public var isVerified: Bool { requirement != nil }

  /// axod's signing identifier (`bazel/apple/sign_mac_app.sh`).
  static let axodIdentifier = "axod"

  /// `identifier "dev.leostera.axo" and <certificate>` becomes `identifier "axod" and <certificate>`.
  /// Nil for a requirement that names no identifier, such as an ad hoc build's cdhash.
  public static func axodRequirement(fromOwn own: String) -> String? {
    guard own.hasPrefix("identifier "),
      let and = own.range(of: " and ")
    else { return nil }
    let certificate = own[and.upperBound...]
    guard !certificate.isEmpty else { return nil }
    return "identifier \"\(axodIdentifier)\" and \(certificate)"
  }

  /// Fails unless the program on the other end of the connected socket `descriptor` satisfies
  /// the requirement, checked by its audit token, so a reused pid cannot pass for it.
  func check(_ descriptor: Int32) throws {
    guard let requirement else { return }
    #if os(macOS)
      var token = audit_token_t()
      var length = socklen_t(MemoryLayout<audit_token_t>.size)
      guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
        Int(length) == MemoryLayout<audit_token_t>.size
      else { throw AxoClientError.untrustedPeer("its identity could not be read") }
      let tokenData = withUnsafeBytes(of: &token) { Data($0) }
      var code: SecCode?
      var compiled: SecRequirement?
      guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
        let compiled
      else { throw AxoClientError.untrustedPeer("the requirement for axod is not valid") }
      guard
        SecCodeCopyGuestWithAttributes(
          nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
        let code,
        SecCodeCheckValidity(code, [], compiled) == errSecSuccess
      else { throw AxoClientError.untrustedPeer("the program on axod's socket is not axod") }
    #else
      throw AxoClientError.untrustedPeer("there is no axod here")
    #endif
  }

  /// This process's designated requirement, as text.
  static func ownDesignatedRequirement() -> String? {
    #if os(macOS)
      var code: SecCode?
      guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
      var staticCode: SecStaticCode?
      guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
      var requirement: SecRequirement?
      guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
        let requirement
      else { return nil }
      var text: CFString?
      guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
      return text as String
    #else
      return nil
    #endif
  }
}
