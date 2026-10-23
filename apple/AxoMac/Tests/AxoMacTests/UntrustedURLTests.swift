// Ported from Ghostty 81598385d608dda4946093d6d6a234d204a2f225 UntrustedURLTests
// (MIT, see Ghostty LICENSE), converted from Swift Testing to XCTest.
import Foundation
import XCTest

@testable import AxoMac

final class UntrustedURLTests: XCTestCase {
  func testAllowsSafeSchemes() {
    for value in ["http://example.com", "https://example.com/path", "mailto:user@example.com"] {
      guard case .allow(let url) = UntrustedURL(value).decision else {
        XCTFail("expected an allowed URL for \(value)")
        continue
      }
      XCTAssertEqual(url.absoluteString, value)
    }
  }

  func testRejectsWebURLsWithoutHosts() {
    for value in ["https:relative", "http:///missing-host"] {
      XCTAssertEqual(UntrustedURL(value).decision, .deny(.invalidWebURL), value)
    }
  }

  func testRejectsSchemeLessTargets() {
    for value in ["/tmp/file.txt", "../file.txt", "payload.command"] {
      XCTAssertEqual(UntrustedURL(value).decision, .deny(.malformedURL), value)
    }
  }

  func testConfirmsCustomSchemes() {
    for value in ["vscode://file/tmp/example.swift", "ssh://example.com"] {
      guard case .confirm(let url) = UntrustedURL(value).decision else {
        XCTFail("expected a confirmation decision for \(value)")
        continue
      }
      XCTAssertEqual(url.absoluteString, value)
    }
  }

  func testRejectsInvisibleAndLineBreakingCharacters() {
    for scalar in ["\u{0085}", "\u{2028}", "\u{2029}", "\u{202E}", "\u{2066}"] {
      let value = "https://example.com/before\(scalar)after"
      XCTAssertEqual(UntrustedURL(value).decision, .deny(.unsafeCharacters))
    }
  }

  func testAllowsNonExecutableLocalFiles() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "document.txt")
    try "safe".write(to: file, atomically: true, encoding: .utf8)

    guard case .allow(let result) = UntrustedURL(file.absoluteString).decision else {
      return XCTFail("expected a safe local file")
    }
    XCTAssertEqual(result, file.standardizedFileURL.resolvingSymlinksInPath())
  }

  func testRejectsDangerousLocalFileExtensions() throws {
    for filename in ["payload.command", "payload.tool", "payload.app", "payload.workflow"] {
      let directory = try makeTemporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let file = directory.appending(path: filename)
      try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
      XCTAssertEqual(UntrustedURL(file.absoluteString).decision, .deny(.unsafeFile), filename)
    }
  }

  func testRejectsScriptContentTypes() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "payload.sh")
    try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
    XCTAssertEqual(UntrustedURL(file.absoluteString).decision, .deny(.unsafeFile))
  }

  func testRejectsExecutableFilesRegardlessOfExtension() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "payload.txt")
    try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    XCTAssertEqual(UntrustedURL(file.absoluteString).decision, .deny(.unsafeFile))
  }

  func testResolvesSymlinksBeforeClassifyingFiles() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let payload = directory.appending(path: "payload.command")
    let link = directory.appending(path: "document.txt")
    try "#!/bin/sh\n".write(to: payload, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: payload)
    XCTAssertEqual(UntrustedURL(link.absoluteString).decision, .deny(.unsafeFile))
  }

  func testPreviewShowsTheEffectiveStandardizedPath() {
    for separator in ["\u{0085}", "\u{2028}", "\u{2029}"] {
      let value = "/tmp/preview\(separator)////../payload.command////"
      XCTAssertEqual(UntrustedURL(value).displayString, "/tmp/payload.command")
    }
  }

  func testPreviewEscapesBidirectionalControls() {
    let value = "https://example.com/a\u{202E}b"
    XCTAssertEqual(UntrustedURL(value).displayString, "https://example.com/a\\u{202E}b")
  }

  func testLinkOpenPolicyRoutesUntrustedKindsThroughSafetyChecks() {
    XCTAssertEqual(TerminalLinkPolicy.route(kind: .osc8, value: "/tmp/x.command"), .untrusted("/tmp/x.command"))
    XCTAssertEqual(
      TerminalLinkPolicy.route(kind: .unknown, value: "https://example.com"),
      .untrusted("https://example.com"))
    XCTAssertEqual(
      TerminalLinkPolicy.route(kind: .unknown, value: "/tmp/plain path"),
      .untrusted("file:///tmp/plain%20path"))
    XCTAssertEqual(
      TerminalLinkPolicy.route(kind: .unknown, value: "/tmp/a\u{202E}b"),
      .untrusted("/tmp/a\u{202E}b"))
    XCTAssertEqual(
      TerminalLinkPolicy.route(kind: .text, value: "https://example.com"),
      .trusted(URL(string: "https://example.com")!))
  }

  private func makeTemporaryDirectory() throws -> URL {
    let result = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
    return result
  }
}
