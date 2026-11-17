/// Owns only this recording's auto-lock suppression and restores the prior setting once.
@MainActor
public final class RecordingWakeLock {
  private let read: () -> Bool
  private let write: (Bool) -> Void
  private var previous: Bool?

  public init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
    self.read = read
    self.write = write
  }
  public func acquire() {
    guard previous == nil else { return }
    previous = read()
    write(true)
  }
  public func release() {
    guard let previous else { return }
    self.previous = nil
    write(previous)
  }
}
