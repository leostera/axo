import AxoRPC
import SwiftUI

struct GhosttyTerminalView: NSViewRepresentable {
  let runtime: GhosttyRuntime
  let shell: TerminalShell
  let size: CGSize
  let isFocused: Bool
  let onFocus: () -> Void
  let onStatusChange: (TerminalSurfaceConnection) -> Void
  let onSplit: (TerminalSplitDirection) -> Void
  let onClose: () -> Void

  func makeNSView(context: Context) -> GhosttySurfaceHostNSView {
    let presentation = makeSurfacePresentation()
    presentation.host.attachSurface(presentation.view)
    presentation.view.reportStatus()
    updateFocus(of: presentation.view)
    return presentation.host
  }

  func updateNSView(_ host: GhosttySurfaceHostNSView, context: Context) {
    let presentation = makeSurfacePresentation()
    host.attachSurface(presentation.view)
    // GeometryReader supplies a creation seed, not the final AppKit viewport.
    // Reparenting after a close may settle the native bounds after this update.
    host.needsLayout = true
    updateFocus(of: presentation.view)
  }

  @MainActor
  private func makeSurfacePresentation() -> (
    host: GhosttySurfaceHostNSView,
    view: GhosttySurfaceNSView
  ) {
    runtime.surfaces.presentation(
      for: shell,
      initialSize: size,
      onFocus: {
        runtime.setFocusedShellID(shell.id)
        onFocus()
      },
      onStatusChange: onStatusChange,
      onSplit: onSplit,
      onClose: onClose
    )
  }

  @MainActor
  private func updateFocus(of view: GhosttySurfaceNSView) {
    guard isFocused else {
      view.cancelFocusRequest()
      return
    }
    // Actual responder acquisition reports focus outside the representable update.
    view.requestFocus()
  }

}
