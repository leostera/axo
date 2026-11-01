import ServiceManagement

enum RegistrationDecision: Equatable {
  case alreadyEnabled
  case registerOnce
  case approvalRequired
  case userDisabled
  case missingService
  case unknown

  /// `definitionBundled`: the app holds its LaunchAgent plist. macOS reports `.notFound` for a
  /// LaunchAgent it has never registered on that Mac, so that status alone does not mean the plist
  /// is missing: registering is what makes macOS find it.
  static func resolve(
    serviceStatus: SMAppService.Status,
    registrationIntentRecorded: Bool,
    definitionBundled: Bool
  ) -> RegistrationDecision {
    switch serviceStatus {
    case .enabled:
      .alreadyEnabled
    case .requiresApproval:
      .approvalRequired
    case .notFound:
      definitionBundled ? .registerOnce : .missingService
    case .notRegistered:
      registrationIntentRecorded ? .userDisabled : .registerOnce
    @unknown default:
      .unknown
    }
  }
}
