import Darwin
import OSLog

/// A terminal grid as the PTY sees it.
struct TerminalGridSize: Equatable, CustomStringConvertible {
  var columns: UInt16
  var rows: UInt16
  var widthPixels: UInt16
  var heightPixels: UInt16

  /// `nil` for an empty grid: a surface that has not been laid out yet has nothing to report.
  init?(columns: UInt32, rows: UInt32, widthPixels: UInt32, heightPixels: UInt32) {
    guard columns > 0, rows > 0 else { return nil }
    self.columns = UInt16(clamping: columns)
    self.rows = UInt16(clamping: rows)
    self.widthPixels = UInt16(clamping: widthPixels)
    self.heightPixels = UInt16(clamping: heightPixels)
  }

  init(_ size: winsize) {
    columns = size.ws_col
    rows = size.ws_row
    widthPixels = size.ws_xpixel
    heightPixels = size.ws_ypixel
  }

  var winsize: Darwin.winsize {
    Darwin.winsize(ws_row: rows, ws_col: columns, ws_xpixel: widthPixels, ws_ypixel: heightPixels)
  }

  var description: String { "\(columns)x\(rows)" }
}

/// Keeps a surface's PTY sized to its grid.
///
/// libghostty resizes the PTY only when its own grid changes, so a PTY resized behind its back
/// (a process relaunched by Axod at the default size, another client, a surface reattached at
/// an unchanged grid) would otherwise stay wrong until the window is resized. The surface
/// re-asserts its size whenever its grid is applied (attach and every layout change), it gains
/// focus, or its window becomes key. libghostty also skips the first resize of an adopted PTY,
/// so the host's assertion is what sizes the PTY after a transient first layout pass.
///
/// Owns a duplicate of the PTY master; libghostty keeps its own.
final class TerminalPTYSizeReporter {
  private let descriptor: Int32
  private let shellID: Int64

  /// `nil` if the descriptor cannot be duplicated (the surface still works; it just cannot
  /// correct a stale size).
  init?(ptyDescriptor: Int32, shellID: Int64) {
    let duplicate = fcntl(ptyDescriptor, F_DUPFD_CLOEXEC, 0)
    guard duplicate >= 0 else { return nil }
    descriptor = duplicate
    self.shellID = shellID
  }

  deinit { close(descriptor) }

  /// Sets the PTY to `grid` if it differs. Unchanged sizes are left alone so the foreground
  /// process is not sent a spurious SIGWINCH.
  @discardableResult
  func report(_ grid: TerminalGridSize) -> Bool {
    var current = winsize()
    guard ioctl(descriptor, TIOCGWINSZ, &current) == 0 else { return false }
    let previous = TerminalGridSize(current)
    guard previous != grid else { return false }
    var updated = grid.winsize
    guard ioctl(descriptor, TIOCSWINSZ, &updated) == 0 else {
      AxoTrace.surfaces.error(
        "event=surface.pty_size_failed shell_id=\(self.shellID) errno=\(errno)")
      return false
    }
    AxoTrace.surfaces.notice(
      "event=surface.pty_size_corrected shell_id=\(self.shellID) from=\(previous.description, privacy: .public) to=\(grid.description, privacy: .public)"
    )
    return true
  }
}
