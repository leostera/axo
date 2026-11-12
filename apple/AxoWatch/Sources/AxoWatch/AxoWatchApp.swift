import AxoClient
import AxoCompanion
import AxoWatchModel
import SwiftUI

@main
struct AxoWatchApp: App {
  var body: some Scene { WindowGroup { WatchHome() } }
}

private struct WatchHome: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var companion = WatchCompanionSignIn()
  @State private var chat: WatchChatModel?

  // Never put a bearer token in a SwiftUI task identity or diagnostic string.
  private var signInRevision: String {
    guard let snapshot = companion.model.login.snapshot else { return "none" }
    return "\(snapshot.authority):\(snapshot.revision)"
  }

  var body: some View {
    let companion = self.companion
    NavigationStack {
      Group {
        if let chat, chat.account.state == .signedIn {
          WatchChatView(model: chat, transcribeAudio: { url in try await companion.transcribeAudio(url) })
        } else {
          ScrollView {
            VStack(spacing: 12) {
              WatchBrandHeader()
              status
              Button("Refresh", systemImage: "arrow.clockwise") {
                companion.sync()
                Task { await companion.model.refresh() }
              }
            }
            .multilineTextAlignment(.center).padding(.horizontal)
          }
        }
      }
      .navigationTitle("Axo")
    }
    .onChange(of: chat?.account.state) { _, state in
      if state == .signedOut { companion.model.authorizationRefused() }
    }
    .task(id: signInRevision) {
      chat?.stop()
      chat = nil
      guard let session = companion.model.login.session, let token = SessionToken(session.token) else { return }
      let runtime = WatchChatModel(token: token)
      chat = runtime
    }
    .task(id: scenePhase) {
      let active = scenePhase == .active
      companion.setActive(active)
      if !active { chat?.suspend(); return }
      while !Task.isCancelled {
        await companion.model.refresh()
        do { try await Task.sleep(for: .seconds(30)) } catch { break }
        companion.sync()
      }
    }
  }

  @ViewBuilder private var status: some View {
    switch companion.model.status {
    case .waitingForPhone:
      Text("Axo on your wrist").font(.headline)
      Text("Open Axo on your iPhone. Your Watch uses the same sign-in automatically.")
        .font(.caption).foregroundStyle(.secondary)
    case .signedOut:
      Text("Sign in on iPhone").font(.headline)
      Text("Your Watch will sign in too. No codes or extra setup.")
        .font(.caption).foregroundStyle(.secondary)
    case .checking:
      ProgressView("Checking account…")
    case .verified(let account):
      Text("Account connected").font(.headline)
      Text(account.displayName).font(.caption)
      ProgressView("Opening sessions…")
    case .offline(let message):
      Text("Not connected").font(.headline)
      Text(message).font(.caption).foregroundStyle(.secondary)
    case .inactive:
      Text("Axo").font(.headline)
    }
  }
}
