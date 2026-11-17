import Foundation

/// Bounded, non-secret evidence for the explicitly signed preservation build. The ordinary
/// account/companion UI must not be constructed while requestsDestinationGate returns true.
public enum EnclaveProbeRuntime {
  public enum Mode: String, Codable { case source, destination }
  public enum Status: String, Codable {
    case prepared, verified, noExistingKey, unavailable, invalid, conflict, unsupported, expired
  }
  public struct Report: Codable {
    public let schema: Int
    public let runID: UUID
    public let role: EnclavePreservationProbe.Role
    public let bundleID: String
    public let status: Status

    public init(runID: UUID, role: EnclavePreservationProbe.Role, bundleID: String, status: Status) {
      schema = 1
      self.runID = runID
      self.role = role
      self.bundleID = bundleID
      self.status = status
    }

    public var message: String {
      switch status {
      case .prepared: "Existing approval identity prepared on this device."
      case .verified: "The existing approval identity works in this signed app."
      case .noExistingKey: "The previous app has no saved approval identity. No key was created."
      case .unavailable: "Unlock this device and try again. Preservation has not been proved."
      case .conflict: "This app already has a different identity. Nothing has been replaced."
      case .unsupported: "The saved software identity needs a separate migration decision."
      case .expired: "The preservation check expired. Open the previous app and prepare it again."
      case .invalid: "The preservation configuration could not be verified."
      }
    }
  }

  private static let modeKey = "AXOIdentityProbeMode"
  private static let groupKey = "AXOIdentityProbeAccessGroup"
  public static let reportFilename = "axo-identity-preservation.json"

  private static var configuredMode: String? {
    #if DEBUG && targetEnvironment(simulator)
      if let fixture = ProcessInfo.processInfo.environment["AXO_IDENTITY_PROBE_MODE"] { return fixture }
    #endif
    return Bundle.main.object(forInfoDictionaryKey: modeKey) as? String
  }

  public static var requested: Bool {
    configuredMode != nil || Bundle.main.object(forInfoDictionaryKey: modeKey) != nil
  }

  public static func requestsDestinationGate(
    role: EnclavePreservationProbe.Role, bundleID: String? = Bundle.main.bundleIdentifier,
    requested: Bool = EnclaveProbeRuntime.requested
  ) -> Bool {
    // Invalid/mistagged destination configuration stays gated too, never falls through to login.
    requested && bundleID != role.sourceBundleID
  }

  @discardableResult
  public static func runIfRequested(role: EnclavePreservationProbe.Role) -> Report? {
    guard requested else { return nil }
    let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
    let runID = ProcessInfo.processInfo.environment["AXO_IDENTITY_PROBE_RUN_ID"].flatMap(UUID.init(uuidString:)) ?? UUID()
    let status: Status
    do {
      guard let text = configuredMode,
        let mode = Mode(rawValue: text),
        bundleID == (mode == .source ? role.sourceBundleID : role.destinationBundleID),
        let group = Bundle.main.object(forInfoDictionaryKey: groupKey) as? String else {
        throw EnclavePreservationProbe.Failure.wrongIdentity
      }
      let store = try EnclaveProbeKeychain(accessGroup: group)
      let result: EnclavePreservationProbe.Outcome
      switch mode {
      case .source:
        result = try EnclavePreservationProbe.prepare(role: role, bundleID: bundleID, defaults: .standard,
          store: store, transferID: runID)
      case .destination:
        guard let sourceRun = ProcessInfo.processInfo.environment["AXO_IDENTITY_PROBE_SOURCE_RUN_ID"],
          let transferID = UUID(uuidString: sourceRun) else { throw EnclavePreservationProbe.Failure.wrongIdentity }
        result = try EnclavePreservationProbe.verify(role: role, bundleID: bundleID, defaults: .standard,
          store: store, expectedTransferID: transferID)
      }
      switch result {
      case .prepared: status = .prepared
      case .verified: status = .verified
      case .noExistingKey: status = .noExistingKey
      }
    } catch let failure as EnclavePreservationProbe.Failure {
      switch failure {
      case .wrongIdentity, .malformed: status = .invalid
      case .expired: status = .expired
      case .unsupportedSoftwareKey: status = .unsupported
      case .conflictingDestination: status = .conflict
      case .unavailable: status = .unavailable
      }
    } catch { status = .unavailable }
    let report = Report(runID: runID, role: role, bundleID: bundleID, status: status)
    // Only this fixed report crosses to the deployment harness. Never include exception text,
    // credentials, key bytes, public points, account identity, preferences or recording metadata.
    if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(reportFilename)
        try JSONEncoder().encode(report).write(to: url, options: .atomic)
        #if os(iOS) || os(watchOS)
          try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
      } catch { /* UI still reports the check; an absent report is never harness success. */ }
    }
    return report
  }
}
