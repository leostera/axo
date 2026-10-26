import AppKit
import AxoDaemonManager
import SwiftUI

/// The small window Axo spins in while Axod starts and the Session catalog loads. When
/// `LaunchSplashGate` says so, it opens the terminal window and fades itself away.
struct LaunchSplashView: View {
  static let windowID = "splash"
  static let size = CGSize(width: 220, height: 220)
  private static let fadeOut: TimeInterval = 0.35

  var daemon: DaemonController
  var sessions: TerminalSessionsModel
  /// Whether Axod is reachable (the launch environment's view of it).
  var daemonIsRunning: () -> Bool
  /// False for launch modes without a splash; if SwiftUI opens the window anyway, it closes.
  var enabled = true

  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var puppet = AxoMascot.installedAnimation?.makePuppet(artboard: AxoMascot.Contract.loaderArtboard)
  @State private var window: NSWindow?
  @State private var shownFor: Duration = .zero
  @State private var revealed = false

  private var ready: Bool {
    daemonIsRunning() && sessions.catalogConnection == .live
  }

  private var needsAttention: Bool {
    switch daemon.status {
    case .requiresApproval, .disabled, .failed: true
    case .starting, .running, .updating: false
    }
  }

  private var shouldReveal: Bool {
    LaunchSplashGate.shouldReveal(ready: ready, needsAttention: needsAttention, elapsed: shownFor)
  }

  var body: some View {
    ZStack {
      if let puppet {
        puppet.view
          .padding(18)
          .onAppear { puppet.setLoading(true) }
      } else {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .scaledToFit()
          .padding(40)
      }
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .accessibilityElement()
    .accessibilityLabel("Axo is starting")
    .background(WindowReader { window = $0 })
    // The gate's clock: wakes at the minimum and at the limit; readiness is observed.
    .task {
      try? await Task.sleep(for: LaunchSplashGate.minimumShown)
      shownFor = LaunchSplashGate.minimumShown
      try? await Task.sleep(for: LaunchSplashGate.patience - LaunchSplashGate.minimumShown)
      shownFor = LaunchSplashGate.patience
    }
    .onChange(of: shouldReveal, initial: true) { _, reveal in
      if reveal, enabled { revealTerminal() }
    }
    .onAppear {
      if !enabled { dismissWindow(id: Self.windowID) }
    }
  }

  private func revealTerminal() {
    guard !revealed else { return }
    revealed = true
    puppet?.setLoading(false)
    openWindow(id: "terminal")
    guard let window else {
      dismissWindow(id: Self.windowID)
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeOut
      window.animator().alphaValue = 0
    } completionHandler: {
      Task { @MainActor in dismissWindow(id: Self.windowID) }
    }
  }
}

/// Hands over the hosting `NSWindow` once the view is in one, and makes it a plain floating tile:
/// no title bar buttons, not resizable, movable by its background, centred.
private struct WindowReader: NSViewRepresentable {
  var onWindow: (NSWindow) -> Void

  func makeNSView(context: Context) -> ReaderView {
    let view = ReaderView()
    view.onWindow = onWindow
    return view
  }

  func updateNSView(_ nsView: ReaderView, context: Context) {}

  final class ReaderView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      window.styleMask.remove([.resizable, .miniaturizable])
      for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        window.standardWindowButton(button)?.isHidden = true
      }
      window.isMovableByWindowBackground = true
      window.center()
      let onWindow = onWindow
      DispatchQueue.main.async { onWindow?(window) }
    }
  }
}
