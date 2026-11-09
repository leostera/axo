import AxoProtocol
import Foundation

/// A pane close (⌘W) waiting for the user: the pane is busy, or Axod couldn't say.
struct ShellCloseConfirmation: Equatable, Identifiable {
  enum Reason: Equatable {
    case runningProcess(String?)
    case piWorking
    case unknown

    /// Why closing a pane needs confirmation; `nil` means close it at once. When Axod can't say
    /// whether the pane is busy (`busy == nil`), ask rather than guess.
    init?(closing role: PaneRole, busy: TerminalShellBusy?) {
      switch (busy, role) {
      case (nil, _): self = .unknown
      case (let busy?, _) where !busy.busy: return nil
      case (_, .pi): self = .piWorking
      case (let busy?, _): self = .runningProcess(busy.foregroundProcess)
      }
    }
  }

  let shellID: ShellID
  let reason: Reason

  var id: ShellID { shellID }
}
