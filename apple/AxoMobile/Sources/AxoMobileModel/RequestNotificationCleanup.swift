import Foundation

public enum RequestNotificationCleanup {
  /// A socket snapshot can lag the push. Absence is not permission to erase a just-arrived alert.
  public static func shouldRemove(
    receivedAt: Date, belongsToCurrentAccount: Bool, isPending: Bool, now: Date = .now
  ) -> Bool {
    if !belongsToCurrentAccount { return true }
    if isPending { return false }
    return now.timeIntervalSince(receivedAt) >= 10
  }
}
