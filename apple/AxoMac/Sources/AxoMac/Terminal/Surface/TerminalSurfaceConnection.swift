import Foundation

/// Whether a pane's Ghostty surface is attached to its Axod shell.
enum TerminalSurfaceConnection: Equatable {
  case starting
  case connected
  /// The terminal transport is being retried; this says nothing about Pi's health.
  case reconnecting
  /// An exited terminal retains its final screen until the catalog removes/replaces it.
  case ended
  /// The surface could not attach; `message` is worded for the user.
  case failed(String)

  var failureMessage: String? {
    if case .failed(let message) = self { message } else { nil }
  }
}
