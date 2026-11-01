import Foundation
import XCTest

@testable import AxoDaemonManager

final class AppUpgradeTests: XCTestCase {
  private func choose(
    running: Int = 260, installed: Int? = 260, published: Int? = nil, canVerify: Bool = true
  ) -> AppUpgrade? {
    AppUpgrade.choose(
      running: running, installed: installed, installedAxod: 23,
      published: published.map { PublishedBuild(build: $0, axodBuild: 24) },
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
    XCTAssertEqual(choose(published: 261), .published(PublishedBuild(build: 261, axodBuild: 24)))
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
    let data = Data(#"{"build":261,"axodBuild":24,"commit":"5555c501"}"#.utf8)
    XCTAssertEqual(
      try JSONDecoder().decode(PublishedBuild.self, from: data),
      PublishedBuild(build: 261, axodBuild: 24, commit: "5555c501"))
  }

  func testURLsLiveUnderTheOrigin() {
    let origin = URL(string: "https://axo.leostera.dev")!
    XCTAssertEqual(
      PublishedBuild.manifestURL(origin: origin).absoluteString,
      "https://axo.leostera.dev/cdn/Axo.app.json")
    XCTAssertEqual(
      PublishedBuild.archiveURL(origin: origin).absoluteString,
      "https://axo.leostera.dev/cdn/Axo.app.zip")
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
}
