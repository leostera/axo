import Darwin
import Foundation
import Security

/// One captured latest.json snapshot. Artifact names bind version, commit and target.
public struct PublishedBuild: Decodable, Equatable, Sendable {
  public let build: Int
  public let axodBuild: Int
  public let commit: String
  public let version: String
  public let artifacts: [String: String]

  public init(build: Int, axodBuild: Int, commit: String, version: String, artifacts: [String: String]) throws {
    func matches(_ value: String, _ pattern: String) -> Bool {
      value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }
    guard build > 0, axodBuild > 0,
      matches(version, #"^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$"#),
      matches(commit, "^[a-f0-9]{40}$"), !artifacts.isEmpty, artifacts.count <= 32
    else { throw AppUpgradeError.download("invalid latest.json release identity") }
    let prefix = "axo-\(version)-\(commit.prefix(12))-"
    for (target, file) in artifacts {
      guard matches(target, "^[a-z0-9_]+(-[a-z0-9]+){2,4}$"),
        file == "\(prefix)\(target).zip" || (!target.hasSuffix("apple-darwin") && file == "\(prefix)\(target).tar.gz")
      else { throw AppUpgradeError.download("artifact does not match its release/target") }
    }
    self.build = build
    self.axodBuild = axodBuild
    self.commit = commit
    self.version = version
    self.artifacts = artifacts
  }
  private enum CodingKeys: String, CodingKey { case build, axodBuild, commit, version, artifacts }
  public init(from decoder: Decoder) throws {
    let value = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(build: value.decode(Int.self, forKey: .build),
      axodBuild: value.decode(Int.self, forKey: .axodBuild),
      commit: value.decode(String.self, forKey: .commit),
      version: value.decode(String.self, forKey: .version),
      artifacts: value.decode([String: String].self, forKey: .artifacts))
  }
  public static var targetTriplet: String {
    #if arch(arm64)
    "aarch64-apple-darwin"
    #elseif arch(x86_64)
    "x86_64-apple-darwin"
    #else
    #error("Unsupported Mac update architecture")
    #endif
  }
  public static func manifestURL(origin: URL) -> URL {
    origin.appendingPathComponent("cdn/latest.json")
  }
  public func archiveURL(origin: URL, target: String = Self.targetTriplet) throws -> URL {
    guard let file = artifacts[target] ?? artifacts["universal-apple-darwin"] else {
      throw AppUpgradeError.download("this release has no artifact for \(target)")
    }
    return origin.appendingPathComponent("cdn").appendingPathComponent(file)
  }
}

/// A newer Axo this one can become, from the menu's "Upgrade to Axo v0.3".
public enum AppUpgrade: Equatable, Sendable {
  /// Already on disk over the running bundle (a `bazel build` at dist/Axo.app): just restart.
  case installed(build: Int, axodBuild: Int?, version: String? = nil)
  /// Published at axo.leostera.dev: download, check, swap in over this bundle, restart.
  case published(PublishedBuild)

  public var build: Int {
    switch self {
    case .installed(let build, _, _): build
    case .published(let published): published.build
    }
  }

  /// The semantic version: the installed bundle's, or what the published manifest says.
  public var version: String? {
    switch self {
    case .installed(_, _, let version): version
    case .published(let published): published.version
    }
  }

  /// How the menu names it: "Axo v0.3", or "Build 270" when its version is unknown.
  public var title: String {
    version.map { "Axo v\($0)" } ?? "Build \(build)"
  }

  public var axodBuild: Int? {
    switch self {
    case .installed(_, let axodBuild, _): axodBuild
    case .published(let published): published.axodBuild
    }
  }

  /// A newer build over this bundle wins: it is what launchd would start next anyway. A published
  /// one is offered only when it is newer than both, and only to an Axo signed by a team, the
  /// one a download must be signed by too.
  public static func choose(
    running: Int, installed: Int?, installedAxod: Int?, installedVersion: String? = nil,
    published: PublishedBuild?, canVerifyDownloads: Bool
  ) -> AppUpgrade? {
    if let installed, installed > running {
      return .installed(build: installed, axodBuild: installedAxod, version: installedVersion)
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
    guard data.count <= 65536 else { throw AppUpgradeError.download("latest.json exceeds 64 KiB") }
    let published = try JSONDecoder().decode(PublishedBuild.self, from: data)
    _ = try published.archiveURL(origin: origin) // Do not offer an unsupported target.
    return published
  }

  /// Puts the published build at `bundle` and returns its build number. Throws, leaving `bundle`
  /// as it was, unless the download is this app (`bundleIdentifier`), signed by `team` and newer
  /// than `running`.
  public static func install(
    origin: URL, published: PublishedBuild, over bundle: URL, bundleIdentifier: String, team: String, running: Int,
    session: URLSession = .shared
  ) async throws -> Int {
    let archiveURL = try published.archiveURL(origin: origin)
    let work = try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true)
    defer { try? FileManager.default.removeItem(at: work) }

    let archive = work.appendingPathComponent("Axo.app.zip")
    do {
      let (downloaded, response) = try await session.download(
        from: archiveURL)
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
    try verifyReleaseMetadata(app, published: published)
    try swapIn(app, over: bundle)
    return found
  }

  static func verifyReleaseMetadata(_ app: URL, published: PublishedBuild) throws {
    guard bundleBuild(of: app) == published.build, bundleVersion(of: app) == published.version,
      bundleBuild(of: app, key: "AXODBuildNumber") == published.axodBuild,
      let embedded = bundleInfo(of: app)?["AXOGitCommit"] as? String,
      embedded.count >= 7, published.commit.hasPrefix(embedded)
    else { throw AppUpgradeError.badArchive("bundle metadata does not match the selected release") }
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
    let value = bundleInfo(of: bundle)?[key]
    return (value as? String).flatMap(Int.init) ?? value as? Int
  }

  /// The semantic version of the bundle on disk (`CFBundleShortVersionString`).
  public static func bundleVersion(of bundle: URL) -> String? {
    bundleInfo(of: bundle)?["CFBundleShortVersionString"] as? String
  }

  private static func bundleInfo(of bundle: URL) -> [String: Any]? {
    let plist = bundle.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist) else { return nil }
    return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
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
