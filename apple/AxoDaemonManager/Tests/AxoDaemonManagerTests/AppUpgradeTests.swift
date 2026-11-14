import Foundation
import XCTest

@testable import AxoDaemonManager

final class AppUpgradeTests: XCTestCase {
  private func release(build: Int, axodBuild: Int = 24, version: String = "0.3",
    target: String = PublishedBuild.targetTriplet) -> PublishedBuild {
    let commit = String(repeating: "a", count: 40)
    return try! PublishedBuild(build: build, axodBuild: axodBuild, commit: commit, version: version,
      artifacts: [target: "axo-\(version)-\(commit.prefix(12))-\(target).zip"])
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
    let data = Data(#"{"version":"0.71","build":342,"axodBuild":94,"commit":"0123456789abcdef0123456789abcdef01234567","artifacts":{"aarch64-apple-darwin":"axo-0.71-0123456789ab-aarch64-apple-darwin.zip"}}"#.utf8)
    let parsed = try JSONDecoder().decode(PublishedBuild.self, from: data)
    XCTAssertEqual(parsed.build, 342)
    XCTAssertEqual(try parsed.archiveURL(origin: URL(string: "https://axo.leostera.dev")!, target: "aarch64-apple-darwin").absoluteString,
      "https://axo.leostera.dev/cdn/axo-0.71-0123456789ab-aarch64-apple-darwin.zip")
    XCTAssertThrowsError(try parsed.archiveURL(origin: URL(string: "https://axo.leostera.dev")!, target: "x86_64-apple-darwin"))
  }

  func testURLsPinOneSnapshotAndUniversalFallback() throws {
    let origin = URL(string: "https://axo.leostera.dev")!
    XCTAssertEqual(PublishedBuild.manifestURL(origin: origin).absoluteString, "https://axo.leostera.dev/cdn/latest.json")
    let selected = release(build: 261)
    let later = release(build: 262, version: "0.4")
    XCTAssertNotEqual(try selected.archiveURL(origin: origin), try later.archiveURL(origin: origin))
    XCTAssertTrue(try selected.archiveURL(origin: origin).lastPathComponent.hasPrefix("axo-0.3-"))
    let intel = release(build: 261, target: "x86_64-apple-darwin")
    XCTAssertTrue(try intel.archiveURL(origin: origin, target: "x86_64-apple-darwin").lastPathComponent.hasSuffix("x86_64-apple-darwin.zip"))
    let universal = release(build: 261, target: "universal-apple-darwin")
    XCTAssertTrue(try universal.archiveURL(origin: origin, target: "x86_64-apple-darwin").lastPathComponent.hasSuffix("universal-apple-darwin.zip"))
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
