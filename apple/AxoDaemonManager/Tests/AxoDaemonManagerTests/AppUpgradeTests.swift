import Foundation
import XCTest

@testable import AxoDaemonManager

final class AppUpgradeTests: XCTestCase {
  private func release(build: Int, axodBuild: Int = 24, version: String = "0.3",
    target: String = PublishedBuild.targetTriplet) -> PublishedBuild {
    let commit = String(repeating: "a", count: 40)
    return try! PublishedBuild(build: build, axodBuild: axodBuild, commit: commit, version: version,
      artifacts: [target: "axo-\(version)-\(commit.prefix(12))-\(target).zip"],
      integrity: [target: try! ArchiveIntegrity(sha256: String(repeating: "c", count: 64), size: 1024)])
  }
  private func choose(
    running: Int = 260, installed: Int? = 260, published: Int? = nil, canVerify: Bool = true
  ) -> AppUpgrade? {
    AppUpgrade.choose(
      running: running, installed: installed, installedAxod: 23,
      published: published.map { release(build: $0) },
      canVerifyDownloads: canVerify)
  }

  func testNothingWhenEverythingIsThisBuild() {
    XCTAssertNil(choose(published: 260))
    XCTAssertNil(choose(published: nil))
  }

  func testANewerBuildOverThisBundleIsARestart() {
    XCTAssertEqual(choose(installed: 261), .installed(build: 261, axodBuild: 23))
  }

  func testALocalBuildWinsOverAPublishedOne() {
    XCTAssertEqual(choose(installed: 261, published: 270), .installed(build: 261, axodBuild: 23))
  }

  func testANewerPublishedBuildIsADownload() {
    XCTAssertEqual(choose(published: 261), .published(release(build: 261)))
  }

  func testAnOlderPublishedBuildIsNotOffered() {
    XCTAssertNil(choose(published: 259))
    XCTAssertNil(choose(running: 255, installed: 262, published: 261).flatMap {
      if case .published = $0 { $0 } else { nil }
    })
  }

  func testAnOlderBuildOverThisBundleIsNotAnUpgrade() {
    XCTAssertNil(choose(installed: 259))
  }

  func testAnAdHocAxoIsNotOfferedDownloads() {
    XCTAssertNil(choose(published: 261, canVerify: false))
    XCTAssertEqual(choose(installed: 261, canVerify: false), .installed(build: 261, axodBuild: 23))
  }

  func testTheManifestParsesAsPublishWritesIt() throws {
    let data = Data(#"{"version":"0.71","build":342,"axodBuild":94,"commit":"0123456789abcdef0123456789abcdef01234567","artifacts":{"aarch64-apple-darwin":"axo-0.71-0123456789ab-aarch64-apple-darwin.zip"},"integrity":{"aarch64-apple-darwin":{"sha256":"\#(String(repeating: "d", count: 64))","size":104857600}}}"#.utf8)
    let parsed = try JSONDecoder().decode(PublishedBuild.self, from: data)
    XCTAssertEqual(parsed.build, 342)
    let archive = try parsed.archive(origin: URL(string: "https://axo.leostera.dev")!, target: "aarch64-apple-darwin")
    XCTAssertEqual(archive.url.absoluteString, "https://axo.leostera.dev/cdn/axo-0.71-0123456789ab-aarch64-apple-darwin.zip")
    XCTAssertEqual(archive.integrity, try ArchiveIntegrity(sha256: String(repeating: "d", count: 64), size: 104857600))
    XCTAssertThrowsError(try parsed.archive(origin: URL(string: "https://axo.leostera.dev")!, target: "x86_64-apple-darwin"))
  }

  func testAReleaseThatDoesNotNameItsArchivesBytesIsNeverDownloaded() throws {
    let older = Data(#"{"version":"0.71","build":342,"axodBuild":94,"commit":"0123456789abcdef0123456789abcdef01234567","artifacts":{"aarch64-apple-darwin":"axo-0.71-0123456789ab-aarch64-apple-darwin.zip"}}"#.utf8)
    let parsed = try JSONDecoder().decode(PublishedBuild.self, from: older)
    XCTAssertThrowsError(try parsed.archive(origin: URL(string: "https://axo.leostera.dev")!, target: "aarch64-apple-darwin"))
    let commit = String(repeating: "a", count: 40)
    let file = "axo-0.3-aaaaaaaaaaaa-aarch64-apple-darwin.zip"
    let entry = try ArchiveIntegrity(sha256: String(repeating: "c", count: 64), size: 1)
    XCTAssertThrowsError(try PublishedBuild(build: 261, axodBuild: 24, commit: commit, version: "0.3",
      artifacts: ["aarch64-apple-darwin": file], integrity: ["x86_64-apple-darwin": entry]))
    for (sha256, size) in [(String(repeating: "C", count: 64), Int64(1)), ("short", 1), (String(repeating: "c", count: 64), 0)] {
      XCTAssertThrowsError(try ArchiveIntegrity(sha256: sha256, size: size))
    }
  }

  func testAnArchiveIsCheckedAgainstItsSizeAndSHA256BeforeAnythingReadsIt() throws {
    let archive = FileManager.default.temporaryDirectory.appendingPathComponent("axo-integrity-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: archive) }
    try Data("abc".utf8).write(to: archive)
    let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    XCTAssertNoThrow(try AppUpgradeInstaller.checkIntegrity(of: archive, is: ArchiveIntegrity(sha256: abc, size: 3)))
    XCTAssertThrowsError(try AppUpgradeInstaller.checkIntegrity(of: archive, is: ArchiveIntegrity(sha256: abc, size: 4)))
    XCTAssertThrowsError(
      try AppUpgradeInstaller.checkIntegrity(of: archive, is: ArchiveIntegrity(sha256: String(repeating: "0", count: 64), size: 3)))
  }

  func testURLsPinOneSnapshotAndUniversalFallback() throws {
    let origin = URL(string: "https://axo.leostera.dev")!
    XCTAssertEqual(PublishedBuild.manifestURL(origin: origin).absoluteString, "https://axo.leostera.dev/cdn/latest.json")
    let selected = release(build: 261)
    let later = release(build: 262, version: "0.4")
    XCTAssertNotEqual(try selected.archive(origin: origin).url, try later.archive(origin: origin).url)
    XCTAssertTrue(try selected.archive(origin: origin).url.lastPathComponent.hasPrefix("axo-0.3-"))
    let intel = release(build: 261, target: "x86_64-apple-darwin")
    XCTAssertTrue(try intel.archive(origin: origin, target: "x86_64-apple-darwin").url.lastPathComponent.hasSuffix("x86_64-apple-darwin.zip"))
    let universal = release(build: 261, target: "universal-apple-darwin")
    XCTAssertTrue(try universal.archive(origin: origin, target: "x86_64-apple-darwin").url.lastPathComponent.hasSuffix("universal-apple-darwin.zip"))
  }

  func testMalformedReleaseIdentityAndPathsAreRejected() throws {
    let commit = String(repeating: "a", count: 40)
    for file in ["../escape.zip", "https://evil.test/app.zip", "axo-0.4-aaaaaaaaaaaa-aarch64-apple-darwin.zip",
      "axo-0.3-aaaaaaaaaaaa-x86_64-apple-darwin.zip"] {
      XCTAssertThrowsError(try PublishedBuild(build: 261, axodBuild: 24, commit: commit, version: "0.3", artifacts: ["aarch64-apple-darwin":file]))
    }
    XCTAssertThrowsError(try PublishedBuild(build: 0, axodBuild: 24, commit: commit, version: "0.3", artifacts: [:]))
    XCTAssertThrowsError(try JSONDecoder().decode(PublishedBuild.self, from: Data(#"{"build":261,"axodBuild":24}"#.utf8)))
  }

  func testSwapInKeepsThePreviousBundle() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-upgrade-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let bundle = folder.appendingPathComponent("Axo.app")
    let download = folder.appendingPathComponent("download/Axo.app")
    try write(build: "260", to: bundle)
    try write(build: "261", to: download)

    try AppUpgradeInstaller.swapIn(download, over: bundle)

    XCTAssertEqual(AppUpgradeInstaller.bundleBuild(of: bundle), 261)
    XCTAssertEqual(
      AppUpgradeInstaller.bundleBuild(of: folder.appendingPathComponent(".Axo.app.previous")), 260)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: folder.appendingPathComponent(".Axo.app.staging").path))
  }

  @MainActor
  func testRevokedInstallationCannotReplaceThePrivateBundle() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("axo-update-gate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let bundle = folder.appendingPathComponent("Axo.app")
    let download = folder.appendingPathComponent("download/Axo.app")
    try write(build: "260", to: bundle)
    try write(build: "261", to: download)
    let staged = try AppUpgradeInstaller.stage(download, beside: bundle)
    XCTAssertThrowsError(try AppUpgradeInstaller.commitStaged(staged, over: bundle,
      authorizeInstallation: { throw CancellationError() }))
    XCTAssertEqual(AppUpgradeInstaller.bundleBuild(of: bundle), 260)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".Axo.app.previous").path))
    var authorized = 0
    try AppUpgradeInstaller.commitStaged(staged, over: bundle, authorizeInstallation: { authorized += 1 })
    XCTAssertEqual(authorized, 1)
    XCTAssertEqual(AppUpgradeInstaller.bundleBuild(of: bundle), 261)
    XCTAssertEqual(AppUpgradeInstaller.bundleBuild(of: staged), 260, "The commit retains the previous bundle before housekeeping")
    AppUpgradeInstaller.preservePrevious(staged, beside: bundle)
    XCTAssertEqual(AppUpgradeInstaller.bundleBuild(of: folder.appendingPathComponent(".Axo.app.previous")), 260)
  }

  @MainActor
  func testCancelledTaskCannotEnterTheAtomicReplacement() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("axo-update-cancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let bundle = folder.appendingPathComponent("Axo.app")
    let download = folder.appendingPathComponent("download/Axo.app")
    try write(build: "260", to: bundle)
    try write(build: "261", to: download)
    let staged = try AppUpgradeInstaller.stage(download, beside: bundle)
    let task = Task { @MainActor in
      try AppUpgradeInstaller.commitStaged(staged, over: bundle,
        authorizeInstallation: { XCTFail("Cancellation must be checked before authorization") })
    }
    task.cancel()
    do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
    XCTAssertEqual(AppUpgradeInstaller.bundleBuild(of: bundle), 260)
  }

  func testBundleMetadataMustMatchTheCapturedReleaseBeforeSwap() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("axo-release-\(UUID().uuidString)/Axo.app")
    defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
    try write(build: "261", to: app)
    let info = app.appendingPathComponent("Contents/Info.plist")
    let values = ["CFBundleVersion": "261", "CFBundleShortVersionString": "0.3",
      "AXODBuildNumber": "24", "AXOGitCommit": String(repeating: "a", count: 7)]
    try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: info)
    XCTAssertNoThrow(try AppUpgradeInstaller.verifyReleaseMetadata(app, published: release(build: 261)))
    XCTAssertThrowsError(try AppUpgradeInstaller.verifyReleaseMetadata(app, published: release(build: 262)))
    XCTAssertThrowsError(try AppUpgradeInstaller.verifyReleaseMetadata(app, published: release(build: 261, version: "0.4")))
    XCTAssertThrowsError(try AppUpgradeInstaller.verifyReleaseMetadata(app, published: release(build: 261, axodBuild: 25)))
    var wrongCommit = values
    wrongCommit["AXOGitCommit"] = "bbbbbbb"
    try PropertyListSerialization.data(fromPropertyList: wrongCommit, format: .xml, options: 0).write(to: info)
    XCTAssertThrowsError(try AppUpgradeInstaller.verifyReleaseMetadata(app, published: release(build: 261)))
  }

  func testAnUnsignedDownloadIsRefused() throws {
    let app = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-unsigned-\(UUID().uuidString)/Axo.app")
    defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
    try write(build: "261", to: app)
    XCTAssertThrowsError(
      try AppUpgradeInstaller.verify(app, bundleIdentifier: "dev.leostera.axo", team: "RGH6S9S55G"))
  }

  private func write(build: String, to bundle: URL) throws {
    let contents = bundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleVersion": build], format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
  }

  func testAnInstalledBuildIsNamedByItsBundlesVersion() throws {
    let bundle = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-upgrade-\(UUID().uuidString)/Axo.app")
    defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleVersion": "271", "CFBundleShortVersionString": "0.4"],
      format: .xml, options: 0
    ).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    let upgrade = AppUpgrade.choose(
      running: 270, installed: AppUpgradeInstaller.bundleBuild(of: bundle), installedAxod: nil,
      installedVersion: AppUpgradeInstaller.bundleVersion(of: bundle), published: nil,
      canVerifyDownloads: true)
    XCTAssertEqual(upgrade?.title, "Axo v0.4")
  }

  func testTheMenuNamesAnUpgradeByItsVersion() {
    XCTAssertEqual(AppUpgrade.published(release(build: 270, version: "0.3")).title, "Axo v0.3")
    XCTAssertEqual(AppUpgrade.installed(build: 271, axodBuild: nil, version: "0.4").title, "Axo v0.4")
    XCTAssertEqual(AppUpgrade.installed(build: 271, axodBuild: nil).title, "Build 271")
  }
}
