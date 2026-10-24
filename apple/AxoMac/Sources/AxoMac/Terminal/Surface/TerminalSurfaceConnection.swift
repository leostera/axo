import Foundation

/// Whether a pane's Ghostty surface is attached to its Axod shell.
enum TerminalSurfaceConnection: Equatable {
  case starting
  case connected
  /// The surface could not attach; `message` is worded for the user.
  case failed(String)

  var failureMessage: String? {
    if case .failed(let message) = self { message } else { nil }
  }
}
