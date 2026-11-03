import Darwin
import Foundation
import Security

/// The build `//:publish` serves at `/cdn/Axo.app.zip`, as `/cdn/Axo.app.json` describes it.
public struct PublishedBuild: Decodable, Equatable, Sendable {
  public var build: Int
  public var axodBuild: Int?
  public var commit: String?
  /// The semantic version (major.minor), which every publish raises.
  public var version: String?

  public init(build: Int, axodBuild: Int? = nil, commit: String? = nil, version: String? = nil) {
    self.build = build
    self.axodBuild = axodBuild
    self.commit = commit
    self.version = version
  }

  public static func manifestURL(origin: URL) -> URL {
    origin.appendingPathComponent("cdn/Axo.app.json")
  }

  public static func archiveURL(origin: URL) -> URL {
    origin.appendingPathComponent("cdn/Axo.app.zip")
  }
}

/// A newer Axo this one can become, from the menu's "Upgrade to Build N".
public enum AppUpgrade: Equatable, Sendable {
  /// Already on disk over the running bundle (a `bazel build` at dist/Axo.app): just restart.
  case installed(build: Int, axodBuild: Int?)
  /// Published at axo.leostera.dev: download, check, swap in over this bundle, restart.
  case published(PublishedBuild)

  public var build: Int {
    switch self {
    case .installed(let build, _): build
    case .published(let published): published.build
    }
  }

  /// The semantic version, when the published manifest says it.
  public var version: String? {
    switch self {
    case .installed: nil
    case .published(let published): published.version
    }
  }

  /// How the menu names it: "Axo 0.3 (Build 270)", or "Build 270" when its version is unknown.
  public var title: String {
    version.map { "Axo \($0) (Build \(build))" } ?? "Build \(build)"
  }

  public var axodBuild: Int? {
    switch self {
    case .installed(_, let axodBuild): axodBuild
    case .published(let published): published.axodBuild
    }
  }

  /// A newer build over this bundle wins: it is what launchd would start next anyway. A published
  /// one is offered only when it is newer than both, and only to an Axo signed by a team, the
  /// one a download must be signed by too.
  public static func choose(
    running: Int, installed: Int?, installedAxod: Int?, published: PublishedBuild?,
    canVerifyDownloads: Bool
  ) -> AppUpgrade? {
    if let installed, installed > running {
      return .installed(build: installed, axodBuild: installedAxod)
    }
    if canVerifyDownloads, let published, published.build > max(running, installed ?? running) {
      return .published(published)
    }
    return nil
  }
}

public enum AppUpgradeError: Error, LocalizedError, Equatable {
  case unsigned
  case download(String)
  case badArchive(String)
  case signature(String)
  case notNewer(found: Int?, running: Int)
  case install(String)

  public var errorDescription: String? {
    switch self {
    case .unsigned:
      "This Axo is not signed by a team, so it cannot check a download is Axo's."
    case .download(let reason): "The download failed: \(reason)"
    case .badArchive(let reason): "The download is not an Axo.app: \(reason)"
    case .signature(let reason): "The download is not signed as Axo: \(reason)"
    case .notNewer(let found, let running):
      "The download is build \(found.map(String.init) ?? "unknown"), not newer than build \(running)."
    case .install(let reason): "Axo could not be put in place: \(reason)"
    }
  }
}

/// Downloads the published Axo.app, checks it is this app signed by this app's team, and swaps it
/// in over the running bundle, keeping the previous one beside it as .Axo.app.previous, as
/// `install_app` does for dist/Axo.app. The caller restarts into it.
public enum AppUpgradeInstaller {
  /// The team the running Axo is signed by; `nil` when it is ad hoc.
  public static func runningTeam() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      return nil
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let information = information as? [String: Any]
    else { return nil }
    return information[kSecCodeInfoTeamIdentifier as String] as? String
  }

  public static func fetchPublished(origin: URL, session: URLSession = .shared) async throws
    -> PublishedBuild
  {
    var request = URLRequest(url: PublishedBuild.manifestURL(origin: origin))
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 15
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw AppUpgradeError.download(
        "\(request.url?.absoluteString ?? "manifest") answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    }
    return try JSONDecoder().decode(PublishedBuild.self, from: data)
  }

  /// Puts the published build at `bundle` and returns its build number. Throws, leaving `bundle`
  /// as it was, unless the download is this app (`bundleIdentifier`), signed by `team` and newer
  /// than `running`.
  public static func install(
    origin: URL, over bundle: URL, bundleIdentifier: String, team: String, running: Int,
    session: URLSession = .shared
  ) async throws -> Int {
    let work = try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true)
    defer { try? FileManager.default.removeItem(at: work) }

    let archive = work.appendingPathComponent("Axo.app.zip")
    do {
      let (downloaded, response) = try await session.download(
        from: PublishedBuild.archiveURL(origin: origin))
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw AppUpgradeError.download("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
      }
      try FileManager.default.moveItem(at: downloaded, to: archive)
    } catch let error as AppUpgradeError {
      throw error
    } catch {
      throw AppUpgradeError.download(error.localizedDescription)
    }

    let unpacked = work.appendingPathComponent("unpacked")
    try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]) {
      AppUpgradeError.badArchive("it does not unzip")
    }
    let app = unpacked.appendingPathComponent("Axo.app")
    guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path)
    else { throw AppUpgradeError.badArchive("it has no Axo.app in it") }
    // Nothing downloaded this way is quarantined, but a copy that is would be translocated and
    // could not register its LaunchAgents.
    _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path]) { .install("") }

    try verify(app, bundleIdentifier: bundleIdentifier, team: team)
    let found = bundleBuild(of: app)
    guard let found, found > running else {
      throw AppUpgradeError.notNewer(found: found, running: running)
    }
    try swapIn(app, over: bundle)
    return found
  }

  /// The whole bundle, nested code (axod, frameworks) included, is intact and signed as
  /// `bundleIdentifier` by `team` under an Apple-issued certificate.
  static func verify(_ app: URL, bundleIdentifier: String, team: String) throws {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
      throw AppUpgradeError.signature("it has no signature")
    }
    var requirement: SecRequirement?
    let text =
      "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { throw AppUpgradeError.signature("Axo could not state what to check") }
    let flags = SecCSFlags(
      rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
    var failure: Unmanaged<CFError>?
    let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &failure)
    guard status == errSecSuccess else {
      let reason = failure.map { CFErrorCopyDescription($0.takeRetainedValue()) as String }
      throw AppUpgradeError.signature(reason ?? "status \(status)")
    }
  }

  /// Copies `app` beside `bundle` and swaps the two atomically, so a running Axo or Finder never
  /// sees a half-copied bundle; the previous one ends up at .Axo.app.previous.
  static func swapIn(_ app: URL, over bundle: URL) throws {
    let folder = bundle.deletingLastPathComponent()
    let staged = folder.appendingPathComponent(".Axo.app.staging")
    let previous = folder.appendingPathComponent(".Axo.app.previous")
    try? FileManager.default.removeItem(at: staged)
    try run("/usr/bin/ditto", [app.path, staged.path]) {
      AppUpgradeError.install("could not copy it beside \(bundle.path)")
    }
    guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, bundle.path, UInt32(RENAME_SWAP)) == 0 else {
      let reason = String(cString: strerror(errno))
      try? FileManager.default.removeItem(at: staged)
      throw AppUpgradeError.install("could not swap it in: \(reason)")
    }
    // After the swap, `staged` holds the previous bundle.
    try? FileManager.default.removeItem(at: previous)
    try? FileManager.default.moveItem(at: staged, to: previous)
  }

  /// `CFBundleVersion` of the bundle on disk, as a number.
  public static func bundleBuild(of bundle: URL, key: String = "CFBundleVersion") -> Int? {
    let plist = bundle.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return nil }
    return (info[key] as? String).flatMap(Int.init) ?? info[key] as? Int
  }

  private static func run(
    _ tool: String, _ arguments: [String], failure: () -> AppUpgradeError
  ) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw failure()
    }
    guard process.terminationStatus == 0 else { throw failure() }
  }
}
