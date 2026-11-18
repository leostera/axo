import Foundation

/// UIKit's notification completion can perform scene restoration. Invoke it on the main actor,
/// not Swift's generic executor used by an Objective-C-to-async delegate bridge.
public enum NotificationCallback {
  public static func perform<Value: Sendable>(
    operation: @escaping @MainActor () async -> Value,
    completion: @escaping @MainActor (Value) -> Void
  ) {
    Task { @MainActor in
      let value = await operation()
      completion(value)
    }
  }
}
