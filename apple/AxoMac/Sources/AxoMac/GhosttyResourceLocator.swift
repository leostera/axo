import Foundation

/// Prefer the installed Ghostty resource bundle so its named themes can be resolved.
enum GhosttyResourceLocator {
  static func resolve(
    installedGhosttyAppURL: URL?,
    bundledResourcesURL: URL?
  ) -> URL? {
    if let installedGhosttyAppURL {
      let installedResources =
        installedGhosttyAppURL
        .appendingPathComponent("Contents/Resources/ghostty", isDirectory: true)
      let themesDirectory = installedResources.appendingPathComponent("themes", isDirectory: true)
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(
        atPath: themesDirectory.path,
        isDirectory: &isDirectory
      ), isDirectory.boolValue {
        return installedResources
      }
    }

    return bundledResourcesURL
  }
}
