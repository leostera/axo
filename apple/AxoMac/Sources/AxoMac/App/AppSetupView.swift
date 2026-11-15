import AppKit
import SwiftUI

/// A quieter success tone, with a darker variant for legibility on light backgrounds.
private enum SetupColors {
  static let success = Color(nsColor: NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
      return NSColor(srgbRed: 0.36, green: 0.65, blue: 0.46, alpha: 1)
    }
    return NSColor(srgbRed: 0.22, green: 0.49, blue: 0.32, alpha: 1)
  })
}

struct AppSetupView: View {
  var model: AppSetupModel
  var appIcon: NSImage? = nil
  var onStepChange: ((AppSetupModel.Step) -> Void)? = nil
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 10) {
        ForEach(AppSetupModel.Step.allCases, id: \.rawValue) { step in
          Text(stepTitle(step))
            .fontWeight(step == model.step ? .semibold : .regular)
            .foregroundStyle(step == model.step ? Color.primary : Color.secondary)
          if step != .ready { Text("›").foregroundStyle(.tertiary) }
        }
        Spacer()
      }.font(.callout)
      if model.step != .permissions { Spacer(minLength: 8) }
      switch model.step {
      case .welcome:
        HStack(spacing: 28) {
          Group {
            if let appIcon {
              Image(nsImage: appIcon).resizable().scaledToFit().frame(width: 128, height: 128)
            } else {
              AboutMascotView(pointer: nil, paneSize: .zero)
            }
          }.frame(width: 180, height: 140)
          heading("Welcome to Axo", "A home for your agents. Keep conversations and terminals together,\nthen pick them up from your other devices.")
        }
        VStack(alignment: .leading, spacing: 16) {
          welcomeRow("Work in Sessions", "Each Session keeps its conversation and terminals together.")
          welcomeRow("Keep work on this Mac", "Close a window without stopping your work. Sleeping this Mac still pauses it.")
          welcomeRow("Choose what Axo can access", "Enable the features you want. You stay in control of permissions.")
        }.padding(24).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
      case .permissions:
        heading("Let Axo work on this Mac", "Enable what you need. Rows update when macOS confirms access.")
        SetupPermissionsPane(model: model)
      case .tryIt:
        heading("Your Axo connections", "Local Sessions work without an account. Link this Mac to pick them up from your other devices.")
        VStack(alignment: .leading, spacing: 22) {
          HStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(.title2)
            VStack(alignment: .leading, spacing: 5) {
              Text("On this Mac").font(.headline)
              if let connection = model.connection {
                Label(connection.health.ready ? "axod is running · build \(connection.health.buildNumber)"
                  : "axod is restoring Sessions · build \(connection.health.buildNumber)",
                  systemImage: connection.health.ready ? "checkmark.circle" : "clock")
                  .foregroundStyle(connection.health.ready ? SetupColors.success : Color.secondary)
              } else {
                Text(model.connectionFailure ?? "Checking the local service…").foregroundStyle(.secondary)
              }
            }
            Spacer()
            if model.isCheckingConnection { ProgressView().controlSize(.small) }
          }
          Divider()
          HStack(spacing: 12) {
            Image(systemName: "network").font(.title2)
            VStack(alignment: .leading, spacing: 5) {
              Text("Across your devices").font(.headline)
              Text(model.connection?.account.title ?? (model.connectionFailure == nil
                ? "Checking account status…" : "Account status is unavailable while axod is unreachable")).foregroundStyle(.secondary)
              Text("Optional. Your local Sessions don’t depend on this.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.connection?.account == .unlinked ? "Link to an Account…" : "Account Settings…") {
              model.openPairing()
            }
          }
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .task { await model.observeConnection() }
        .onDisappear { model.leaveConnectionStep() }
      case .ready:
        Image(systemName: model.connection?.health.ready == true ? "checkmark.circle" : "sparkles")
          .font(.system(size: 56, weight: .light)).foregroundStyle(.tint)
        heading(model.connection?.health.ready == true ? "Your Axo connection is ready" : "Ready to explore Axo",
          "\(model.readyCount) of \(SetupItem.allCases.count) setup checks confirmed.\nYou can review the rest in Settings → Setup & Permissions.")
        Text("Open a Session, choose a folder, and tell your agent what you want to do.")
          .foregroundStyle(.secondary)
        if model.snapshot?.computerUseReady == true {
          Label("Computer-use permissions are ready on this unlocked Mac.", systemImage: "checkmark.shield")
            .foregroundStyle(SetupColors.success)
        }
      }
      if model.step != .permissions { Spacer(minLength: 8) }
      HStack(spacing: 12) {
        if model.step != .welcome {
          Button("Back") { model.back() }.keyboardShortcut(.leftArrow, modifiers: [.command])
        }
        Spacer()
        Button(primaryTitle) { model.next() }
          .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
      }
    }
    .padding(32)
    .frame(maxWidth: 850, maxHeight: .infinity)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .onChange(of: model.step) { _, step in onStepChange?(step) }
  }
  private var primaryTitle: String {
    switch model.step {
    case .welcome: "Get Started"
    case .permissions: model.readyCount == SetupItem.allCases.count ? "Continue" : "Continue for Now"
    case .tryIt: "Continue"
    case .ready: "Open Axo"
    }
  }
  private func heading(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.title.bold())
      Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.leading)
    }.fixedSize(horizontal: false, vertical: true)
  }
  private func welcomeRow(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).fontWeight(.medium)
      Text(subtitle).font(.callout).foregroundStyle(.secondary)
    }
  }
  private func stepTitle(_ step: AppSetupModel.Step) -> String {
    switch step {
    case .welcome: "Welcome"
    case .permissions: "Setup"
    case .tryIt: "Connections"
    case .ready: "Ready"
    }
  }
}

struct SetupPermissionsPane: View {
  var model: AppSetupModel
  @State private var confirmingRestart = false
  @State private var contentHeight: CGFloat = 0
  @State private var viewportHeight: CGFloat = 0
  private var unchecked: [SetupItem] {
    SetupItem.allCases.filter { !model.status($0).isReady && model.status($0) != .checking }
  }
  var body: some View {
    ScrollViewReader { scroll in
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("\(model.readyCount) of \(SetupItem.allCases.count) confirmed").font(.callout).foregroundStyle(.secondary)
          if model.isChecking { ProgressView().controlSize(.small) }
          Spacer()
          Button("Check Again") { Task { await model.refresh(force: true) } }.disabled(model.isChecking)
        }
        if let first = unchecked.first {
          Button {
            withAnimation { scroll.scrollTo(first.id, anchor: .center) }
          } label: {
            HStack {
              Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
              Text(unchecked.count == 1 ? "\(first.title) · \(model.status(first).title)" : "\(unchecked.count) checks to review")
              Spacer()
              Text("Review").foregroundStyle(.tint)
              Image(systemName: "chevron.down").foregroundStyle(.secondary)
            }.font(.callout).padding(10)
              .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
          }.buttonStyle(.plain).accessibilityIdentifier("setup-review-unchecked")
        }
        ScrollView {
          VStack(spacing: 0) {
            ForEach(SetupItem.allCases) { item in
              row(item).id(item.id)
              if item != SetupItem.allCases.last { Divider().padding(.leading, 64) }
            }
          }
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .scrollIndicators(.visible)
        .scrollIndicatorsFlash(trigger: contentHeight > viewportHeight + 1)
        .background(.quaternary.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
        if contentHeight > viewportHeight + 1 {
          Label("Scroll to see all \(SetupItem.allCases.count) checks", systemImage: "arrow.down")
            .font(.caption).foregroundStyle(.secondary)
        }
        Text("Permissions are checked for axod; notifications belong to Axo.app. Optional access does not block Sessions.")
          .font(.caption).foregroundStyle(.secondary)
        if model.snapshot?.permissions?.locked == true {
          Label("Computer use is paused while this Mac is locked.", systemImage: "lock").font(.callout).foregroundStyle(.secondary)
        }
        if let detail = model.snapshot?.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        if let failure = model.failure { Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        HStack {
          Text("Already enabled but still blocked? macOS may need axod to restart.")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Restart axod…", role: .destructive) { confirmingRestart = true }
            .controlSize(.small).disabled(model.snapshot?.health == nil || model.fixing != nil)
        }
        .confirmationDialog("Restart axod?", isPresented: $confirmingRestart, titleVisibility: .visible) {
          Button("Restart axod", role: .destructive) { model.restartDaemon() }
        } message: {
          Text("This restarts every terminal and Pi process. Pi conversation histories are preserved.")
        }
      }
    .task { await model.refresh() }
    }
  }
  private func row(_ item: SetupItem) -> some View {
    let status = model.status(item)
    return HStack(spacing: 14) {
      Image(systemName: item.icon).font(.system(size: 17)).frame(width: 34, height: 34)
        .foregroundStyle(status.isReady ? SetupColors.success : Color.secondary)
        .background((status.isReady ? SetupColors.success : Color.secondary).opacity(0.08), in: Circle())
      VStack(alignment: .leading, spacing: 4) {
        Text(item.title).fontWeight(.medium)
        Text(item.purpose).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity, alignment: .leading)
      if status.isReady {
        Label(item == .commandLine || item == .background ? "Ready" : "Allowed", systemImage: "checkmark")
          .foregroundStyle(SetupColors.success).frame(width: 132, alignment: .trailing)
      } else {
        VStack(alignment: .trailing, spacing: 4) {
          if model.fixing == item { ProgressView().controlSize(.small) }
          else {
            Button(actionTitle(item)) { Task { await model.fix(item) } }
              .disabled(status == .checking || model.fixing != nil)
              .accessibilityIdentifier("setup-fix-\(item.rawValue)")
          }
          Text(model.fixing == item ? "Waiting for macOS…" : status.title).font(.caption).foregroundStyle(.secondary)
        }.frame(width: 132, alignment: .trailing)
      }
    }.padding(.horizontal, 16).padding(.vertical, 12)
  }
  private func actionTitle(_ item: SetupItem) -> String {
    switch item {
    case .commandLine: "Install Command…"
    case .finder, .systemEvents: model.status(item) == .needsSetup ? "Allow Access…" : "Check Access…"
    case .notifications: "Allow Notifications…"
    default: "Open Settings"
    }
  }
}

@MainActor
final class AppSetupWindowController: NSWindowController, NSWindowDelegate {
  private let onClose: () -> Void
  init(model: AppSetupModel, appIcon: NSImage? = nil, onClose: @escaping () -> Void) {
    self.onClose = onClose
    let size = Self.preferredSize(for: model.step)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "Axo Setup"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    let hosting = NSHostingController(rootView: AppSetupView(model: model, appIcon: appIcon,
      onStepChange: { [weak window] step in
        guard let window else { return }
        Self.resize(window, for: step)
      }))
    // SwiftUI's unconstrained ideal height includes every permission row. Let the window,
    // not that ideal size, constrain the scroll view and keep the footer on screen.
    hosting.sizingOptions = []
    window.contentViewController = hosting
    window.setContentSize(size)
    window.contentMinSize = NSSize(width: 740, height: 560)
    window.contentMaxSize = NSSize(width: 1100, height: 1200)
    super.init(window: window)
    window.delegate = self
  }
  static func preferredSize(for step: AppSetupModel.Step) -> NSSize {
    NSSize(width: 820, height: step == .permissions ? 1000 : 560)
  }
  private static func resize(_ window: NSWindow, for step: AppSetupModel.Step) {
    window.setContentSize(preferredSize(for: step))
    AppWindowPlacement.centerOnPrimaryScreen(window)
  }
  required init?(coder: NSCoder) { nil }
  func present() {
    guard let window else { return }
    AppWindowPlacement.applyAppAppearance(window)
    AppWindowPlacement.centerOnPrimaryScreen(window)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }
  func windowWillClose(_ notification: Notification) { onClose() }
}
