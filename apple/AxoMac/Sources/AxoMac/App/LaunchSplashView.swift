import AppKit
import AxoDaemonManager
import SwiftUI

/// Axo spinning over a progress bar, on a transparent window, while Axod starts and the Session
/// catalog loads. When `LaunchSplashGate` says so, it opens the terminal window and fades away.
struct LaunchSplashView: View {
  static let windowID = "splash"
  static let size = CGSize(width: 200, height: 230)
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

  private var progress: Double {
    LaunchSplashGate.progress(daemonRunning: daemonIsRunning(), catalogLive: sessions.catalogConnection == .live)
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
    VStack(spacing: 14) {
      Group {
        if let puppet {
          puppet.view
            .onAppear { puppet.setLoading(true) }
        } else {
          Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .scaledToFit()
            .padding(20)
        }
      }
      .frame(width: 180, height: 180)
      SplashProgressBar(progress: progress)
        .frame(width: 120)
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .modifier(ClearWindowBackground())
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
    TerminalWindowOpener.reveal(openWindow)
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

/// On macOS 15 SwiftUI paints the window's background itself; clear it there too.
private struct ClearWindowBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.containerBackground(.clear, for: .window)
    } else {
      content
    }
  }
}

/// A thin rounded bar that eases forward as launch moves along.
private struct SplashProgressBar: View {
  var progress: Double

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(.primary.opacity(0.15))
        Capsule().fill(.primary.opacity(0.75))
          .frame(width: max(geometry.size.height, geometry.size.width * progress))
      }
    }
    .frame(height: 5)
    .animation(.easeOut(duration: 0.6), value: progress)
    .accessibilityElement()
    .accessibilityLabel("Starting Axo")
    .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
  }
}

/// Hands over the hosting `NSWindow` once the view is in one, and makes it see-through: no
/// background, shadow or title bar, not resizable, movable by Axo, centred.
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
      // Borderless: a hidden title bar still paints a strip; this keeps only the content.
      let content = window.contentLayoutRect.size
      window.styleMask = [.borderless, .fullSizeContentView]
      window.setContentSize(content)
      for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        window.standardWindowButton(button)?.isHidden = true
      }
      // SwiftUI may reuse the window it faded out last time.
      window.alphaValue = 1
      window.isOpaque = false
      window.backgroundColor = .clear
      window.hasShadow = false
      window.isMovableByWindowBackground = true
      window.center()
      let onWindow = onWindow
      DispatchQueue.main.async { onWindow?(window) }
    }
  }
}
