import Foundation

public enum PermissionAccess: String, Decodable, Sendable {
  case granted, notGranted, notAsked, notRunning, unknown, unsupported
  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = Self(rawValue: value) ?? .unknown
  }
}

/// An observation from the actual daemon, never persisted or used to authorize a tool.
public struct DaemonPermissions: Decodable, Equatable, Sendable {
  public let processId: UInt32
  public let supported: Bool
  public let accessibility: PermissionAccess
  public let inputControl: PermissionAccess
  public let screenRecording: PermissionAccess
  public let developerTools: PermissionAccess
  public let fullDiskAccess: PermissionAccess
  public let automationFinder: PermissionAccess
  public let automationSystemEvents: PermissionAccess
  public let locked: Bool

  public init(processId: UInt32, supported: Bool = true, accessibility: PermissionAccess,
    inputControl: PermissionAccess, screenRecording: PermissionAccess, developerTools: PermissionAccess,
    fullDiskAccess: PermissionAccess, automationFinder: PermissionAccess, automationSystemEvents: PermissionAccess,
    locked: Bool = false)
  {
    self.processId = processId; self.supported = supported; self.accessibility = accessibility
    self.inputControl = inputControl; self.screenRecording = screenRecording; self.developerTools = developerTools
    self.fullDiskAccess = fullDiskAccess; self.automationFinder = automationFinder
    self.automationSystemEvents = automationSystemEvents; self.locked = locked
  }
}

public enum AutomationPermissionTarget: String, Codable, Sendable { case finder, systemEvents }
public struct RequestAutomationPermission: Encodable, Sendable {
  public let target: AutomationPermissionTarget
  public init(target: AutomationPermissionTarget) { self.target = target }
}
