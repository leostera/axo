import AppKit
import AxoRPC
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

  /// The window padding `config` resolved to, in points: Axo's default unless the user's Ghostty
  /// config overrides it. Axod sizes panes no surface shows yet with it.
  static func windowPadding(from config: ghostty_config_t) -> ClientViewport.Padding {
    func padding(_ key: String) -> ghostty_config_padding_s? {
      var value = ghostty_config_padding_s()
      return ghostty_config_get(config, &value, key, UInt(key.utf8.count)) ? value : nil
    }
    var resolved = axoWindowPadding
    if let x = padding("window-padding-x") {
      resolved.left = x.top_left
      resolved.right = x.bottom_right
    }
    if let y = padding("window-padding-y") {
      resolved.top = y.top_left
      resolved.bottom = y.bottom_right
    }
    return resolved
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

  /// The window padding Axo configures, in points. `window-padding-y` gives the surface
  /// breathing room above and below; libghostty paints it in the terminal background, as
  /// Ghostty.app does. `-x` is Ghostty's own default, stated so Axod can size panes with it.
  /// A user's Ghostty config may override it; `windowPadding(from:)` reads what applies.
  static let axoWindowPadding = ClientViewport.Padding(top: 10, bottom: 10, left: 2, right: 2)

  /// Axo's Ghostty settings, loaded before user config so explicit Ghostty settings win.
  static let axoConfigDefaults = """
    copy-on-select = clipboard
    window-padding-x = \(axoWindowPadding.left),\(axoWindowPadding.right)
    window-padding-y = \(axoWindowPadding.top),\(axoWindowPadding.bottom)
    """

  /// Returns a user-facing error when the defaults could not be applied.
  static func loadAxoConfigDefaults(into config: ghostty_config_t) -> String? {
    let configURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-ghostty-default-\(UUID().uuidString).ghostty")
    do {
      try (axoConfigDefaults + "\n").write(to: configURL, atomically: true, encoding: .utf8)
    } catch {
      return "Axo could not apply its terminal defaults: \(error.localizedDescription)"
    }
    defer { try? FileManager.default.removeItem(at: configURL) }
    configURL.path.withCString { ghostty_config_load_file(config, $0) }
    return nil
  }
}
