import AppKit
import AxoDaemonManager
import SwiftUI

/// Axo spinning over a progress bar, on a transparent window, whenever Axod isn't up: at launch,
/// while it restarts, and after it goes away. Once Axod runs and the Session catalog is live it
/// reveals the terminal window and fades away; if Axod needs the person, it says so here.
struct LaunchSplashView: View {
  static let windowID = "splash"
  static let size = CGSize(width: 280, height: 340)
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

  private var attention: LaunchSplashGate.Attention? {
    LaunchSplashGate.attention(for: daemon.status)
  }

  private var shouldReveal: Bool {
    LaunchSplashGate.shouldReveal(ready: ready, elapsed: shownFor)
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
        .accessibilityLabel("Axo is starting")
      if let attention {
        SplashAttentionView(attention: attention) { resolve(attention) }
      }
      Spacer(minLength: 0)
    }
    .padding(.top, 20)
    .frame(width: Self.size.width, height: Self.size.height)
    .modifier(ClearWindowBackground())
    .animation(.easeOut(duration: 0.25), value: attention)
    .background(WindowReader { window = $0 })
    // The gate's clock: wakes once at the minimum; readiness is observed.
    .task {
      try? await Task.sleep(for: LaunchSplashGate.minimumShown)
      shownFor = LaunchSplashGate.minimumShown
    }
    .onChange(of: shouldReveal, initial: true) { _, reveal in
      if reveal, enabled { revealTerminal() }
    }
    .onAppear {
      if !enabled { dismissWindow(id: Self.windowID) }
    }
  }

  private func resolve(_ attention: LaunchSplashGate.Attention) {
    switch attention {
    case .approveInLoginItems: daemon.openLoginItemsSettings()
    case .turnOn: daemon.enableDaemon()
    case .retry: daemon.startIfNeeded()
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

/// Why Axod isn't starting, and the button that fixes it, on a small card under the bar.
private struct SplashAttentionView: View {
  var attention: LaunchSplashGate.Attention
  var resolve: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Text(attention.message)
        .font(.callout)
        .multilineTextAlignment(.center)
        .lineLimit(4)
        .fixedSize(horizontal: false, vertical: true)
      Button(attention.actionTitle, action: resolve)
        .controlSize(.regular)
    }
    .padding(12)
    .frame(width: 250)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .transition(.opacity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("launch-splash-attention")
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
