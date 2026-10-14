import ServiceManagement

enum RegistrationDecision: Equatable {
  case alreadyEnabled
  case registerOnce
  case approvalRequired
  case userDisabled
  case missingService
  case unknown

  static func resolve(
    serviceStatus: SMAppService.Status,
    registrationIntentRecorded: Bool
  ) -> RegistrationDecision {
    switch serviceStatus {
    case .enabled:
      .alreadyEnabled
    case .requiresApproval:
      .approvalRequired
    case .notFound:
      .missingService
    case .notRegistered:
      registrationIntentRecorded ? .userDisabled : .registerOnce
    @unknown default:
      .unknown
    }
  }
}
