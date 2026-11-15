import AppKit

/// The shell installer records this same preference after attempting setup, including opt-out
/// or cancelled authorization, so opening the installed app never asks for it a second time.
@MainActor
enum CLICommandSetup {
  private static var scheduled = false

  static func schedule() {
    guard !scheduled, !UserDefaults.standard.bool(forKey: AxoPreferenceKey.cliCommandSetupOffered) else { return }
    scheduled = true
    Task {
      // Let launch/permission UI settle. Never stack this offer over another app modal.
      try? await Task.sleep(for: .seconds(3))
      for _ in 0..<240 {
        if NSApp.isActive && NSApp.modalWindow == nil {
          await offer(installation: .shared, defaults: .standard, present: present, showFailure: showFailure)
          return
        }
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  static func offer(installation: CLICommandInstallation, defaults: UserDefaults,
    present: () -> Bool, showFailure: (String) -> Void) async
  {
    guard !defaults.bool(forKey: AxoPreferenceKey.cliCommandSetupOffered),
      !installation.isInstalling else { return }
    installation.refresh()
    // A translocated/read-only/damaged copy may be moved or reinstalled later. Don't consume
    // its offer until the app can provide the command. Existing/conflicting commands stay quiet.
    if case .unavailable = installation.status { return }
    defaults.set(true, forKey: AxoPreferenceKey.cliCommandSetupOffered)
    guard installation.status == .missing, present() else { return }
    await installation.install()
    if let failure = installation.failure { showFailure(failure) }
  }

  private static func showFailure(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "The axo command wasn’t installed"
    alert.informativeText = message + "\n\nYou can try again in Axo Settings → General → Command Line."
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  private static func present() -> Bool {
    let alert = NSAlert()
    alert.messageText = "Use Axo from Terminal"
    alert.informativeText = "Install the axo command in /usr/local/bin? App updates will also update the command. macOS may ask for administrator approval. Shell profiles are not changed."
    alert.addButton(withTitle: "Install Command")
    alert.addButton(withTitle: "Not Now")
    return alert.runModal() == .alertFirstButtonReturn
  }
}
