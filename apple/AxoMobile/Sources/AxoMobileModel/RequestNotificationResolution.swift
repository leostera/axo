import Foundation

/// A terminal push has display authority only, scoped to the entire originating route.
public struct RequestNotificationResolution: Sendable {
  public let route: RequestNotificationRoute

  public init?(userInfo: [AnyHashable: Any]) {
    guard let marker = userInfo["axoResolution"] as? [String: Any],
      Set(marker.keys) == ["version"], marker["version"] as? Int == 1,
      let route = RequestNotificationRoute(userInfo: userInfo) else { return nil }
    self.route = route
  }

  public func matches(_ userInfo: [AnyHashable: Any]) -> Bool {
    userInfo["axoNotice"] == nil && RequestNotificationRoute(userInfo: userInfo) == route
  }
}
