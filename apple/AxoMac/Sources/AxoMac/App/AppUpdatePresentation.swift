import AppKit
import AxoDaemonManager
import Observation
import SwiftUI

@MainActor
@Observable
final class AppUpdatePresentation {
  enum State: Equatable {
    case checking
    case available(AppUpgrade)
    case current
    case failed(String)
    case unverifiable
  }
  enum Notes: Equatable {
    case loading
    case loaded(String)
    case unavailable
  }
  var state: State = .checking
  var notes: Notes = .loading
  let runningVersion: String
  let runningAxod: Int?

  init(runningVersion: String, runningAxod: Int?) {
    self.runningVersion = runningVersion
    self.runningAxod = runningAxod
  }

  var title: String {
    switch state {
    case .checking: "Checking for updates…"
    case .available(let update): update.version.map { "Axo \($0) is available" } ?? "A new Axo build is available"
    case .current: "Axo is up to date"
    case .failed: "Couldn’t check for updates"
    case .unverifiable: "This copy can’t update itself"
    }
  }

  var subtitle: String {
    switch state {
    case .checking: "Looking for a newer signed release."
    case .available: "You have Axo \(runningVersion)."
    case .current: "You’re running the latest available release, Axo \(runningVersion)."
    case .failed: "Check your connection and try again."
    case .unverifiable: "This build has no signing team, so downloaded updates can’t be verified."
    }
  }

  var restartWarning: String? {
    guard case .available(let update) = state, let next = update.axodBuild,
      let runningAxod, next != runningAxod else { return nil }
    return "This update also restarts axod. Terminals restart and Pi sessions resume."
  }
}

struct AppUpdateOfferView: View {
  var presentation: AppUpdatePresentation
  var appIcon: NSImage? = nil
  let install: () -> Void
  let skip: () -> Void
  let remind: () -> Void
  let checkAgain: () -> Void
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 16) {
        Image(nsImage: appIcon ?? NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 64, height: 64)
        VStack(alignment: .leading, spacing: 6) {
          Text(presentation.title).font(.system(size: 17, weight: .semibold))
          Text(presentation.subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          switch presentation.state {
          case .checking:
            ProgressView().controlSize(.small)
            Text("Checking axo.leostera.dev…").foregroundStyle(.secondary)
          case .available(let update):
            if case .installed = update {
              Text("This newer build is already installed. Restart Axo to use it.")
            } else {
              switch presentation.notes {
              case .loading: Text("Loading release notes…").foregroundStyle(.secondary)
              case .loaded(let markdown):
                Text("What’s new").font(.title2.bold())
                AppUpdateReleaseNotesView(markdown: markdown)
              case .unavailable:
                Text("Release notes couldn’t be loaded. The update will still be signature-verified before installation.")
                  .foregroundStyle(.secondary)
              }
            }
          case .current: Text("No update is needed.")
          case .failed(let detail): Text(detail).textSelection(.enabled)
          case .unverifiable: Text("Install a signed Axo release to enable verified updates. A newer build already installed on disk can still be offered.")
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
      if let warning = presentation.restartWarning {
        Label(warning, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.secondary)
      }
      HStack(spacing: 10) {
        if case .available(let update) = presentation.state {
          Button("Skip This Version", action: skip)
          Spacer()
          Button("Remind Me Later", action: remind).keyboardShortcut(.cancelAction)
          Button(isInstalled(update) ? "Restart Axo" : "Install Update", action: install)
            .keyboardShortcut(.defaultAction)
        } else {
          Spacer()
          if case .failed = presentation.state { Button("Try Again", action: checkAgain) }
          Button("Close", action: close).keyboardShortcut(.cancelAction)
        }
      }
      .controlSize(.large)
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(\.openURL, OpenURLAction { url in
      // Release notes are display-only, never an app command/deep-link surface.
      url.scheme?.lowercased() == "https" ? .systemAction : .discarded
    })
  }

  private func isInstalled(_ update: AppUpgrade) -> Bool {
    if case .installed = update { return true }
    return false
  }
}

@MainActor
final class AppUpdateWindowController: NSWindowController, NSWindowDelegate {
  private let onClose: () -> Void

  init(content: AppUpdateOfferView, onClose: @escaping () -> Void) {
    self.onClose = onClose
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "Axo Update"
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: content)
    super.init(window: window)
    window.delegate = self
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

private struct AppUpdateReleaseNotesView: View {
  let markdown: String
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
        if line.hasPrefix("### ") {
          Text(String(line.dropFirst(4))).font(.headline).padding(.top, 4)
        } else if line.hasPrefix("## ") {
          Text(String(line.dropFirst(3))).font(.title2.bold())
        } else if line.hasPrefix("- ") {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            inline(String(line.dropFirst(2)))
          }
        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
          inline(line)
        }
      }
    }
    .textSelection(.enabled)
  }
  private func inline(_ text: String) -> Text {
    Text((try? AttributedString(markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
  }
}
