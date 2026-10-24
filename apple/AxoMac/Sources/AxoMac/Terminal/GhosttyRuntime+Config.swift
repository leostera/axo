import AppKit
import GhosttyKit

/// Pure configuration helpers: they return values and never mutate runtime state.
extension GhosttyRuntime {
  struct ScrollbarAppearance: Equatable {
    var showsScrollbar = true
    var hasDarkBackground = true
  }

  static func scrollbarAppearance(from config: ghostty_config_t) -> ScrollbarAppearance {
    var appearance = ScrollbarAppearance()
    var scrollbarValue: UnsafePointer<CChar>?
    let scrollbarKey = "scrollbar"
    if ghostty_config_get(config, &scrollbarValue, scrollbarKey, UInt(scrollbarKey.utf8.count)),
      let scrollbarValue
    {
      appearance.showsScrollbar = TerminalScrollbarConfig.showsScrollbar(
        configValue: String(cString: scrollbarValue))
    }
    var background = ghostty_config_color_s()
    let backgroundKey = "background"
    if ghostty_config_get(config, &background, backgroundKey, UInt(backgroundKey.utf8.count)) {
      appearance.hasDarkBackground = TerminalScrollbarConfig.isDarkBackground(
        red: background.r, green: background.g, blue: background.b)
    }
    return appearance
  }

  /// Points libghostty at installed Ghostty.app resources, else Axo's bundled copy, unless the
  /// environment already chose a directory.
  static func configureGhosttyResources() {
    if let configuredDirectory = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"],
      !configuredDirectory.isEmpty
    {
      return
    }
    let installedAppURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "com.mitchellh.ghostty"
    )
    let bundledResourcesURL = Bundle.main.resourceURL?.appendingPathComponent(
      "ghostty-resources", isDirectory: true
    )
    guard
      let resourceDirectory = GhosttyResourceLocator.resolve(
        installedGhosttyAppURL: installedAppURL,
        bundledResourcesURL: bundledResourcesURL
      )
    else {
      return
    }
    setenv("GHOSTTY_RESOURCES_DIR", resourceDirectory.path, 1)
  }

  /// Axo's defaults, loaded before user config so explicit Ghostty settings win.
  /// Returns a user-facing error when the defaults could not be applied.
  static func loadAxoConfigDefaults(into config: ghostty_config_t) -> String? {
    let configURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-ghostty-default-\(UUID().uuidString).ghostty")
    do {
      try "copy-on-select = clipboard\n".write(to: configURL, atomically: true, encoding: .utf8)
    } catch {
      return "Axo could not enable copy-on-select: \(error.localizedDescription)"
    }
    defer { try? FileManager.default.removeItem(at: configURL) }
    configURL.path.withCString { ghostty_config_load_file(config, $0) }
    return nil
  }
}
