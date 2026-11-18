import Foundation
import XCTest

@testable import AxoDaemonManager

/// The update archive is downloaded before anything can check it, so the download itself must be
/// bounded.
final class ArchiveDownloadTests: XCTestCase {
  private var work: URL!

  override func setUpWithError() throws {
    work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: work)
  }

  private func download(_ answer: ServedArchive.Answer, limit: Int64) async throws -> Data {
    ServedArchive.answer = answer
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ServedArchive.self]
    let archive = work.appendingPathComponent("Axo.app.zip")
    try await AppUpgradeInstaller.downloadArchive(
      URL(string: "https://axo.test/cdn/axo.zip")!, to: archive, maximumBytes: limit,
      configuration: configuration)
    return try Data(contentsOf: archive)
  }

  func testAnArchiveWithinTheLimitIsWrittenWhole() async throws {
    let body = Data((0..<300_000).map { UInt8($0 % 251) })
    let written = try await download(.init(status: 200, chunks: 5, body: body, declaresLength: true), limit: 300_000)
    XCTAssertEqual(written, body)
  }

  func testAnArchiveOverTheLimitIsRefusedWhileItStreams() async throws {
    // No Content-Length to go by: the count of bytes received has to stop it.
    let body = Data(count: 300_001)
    do {
      _ = try await download(.init(status: 200, chunks: 5, body: body, declaresLength: false), limit: 300_000)
      XCTFail("expected the download to be refused")
    } catch let error as AppUpgradeError {
      guard case .download(let reason) = error, reason.contains("larger") else { return XCTFail("\(error)") }
    }
  }

  func testADeclaredLengthOverTheLimitIsRefusedAtOnce() async throws {
    do {
      _ = try await download(.init(status: 200, chunks: 1, body: Data(count: 10), declaresLength: true), limit: 5)
      XCTFail("expected the download to be refused")
    } catch let error as AppUpgradeError {
      guard case .download(let reason) = error, reason.contains("larger") else { return XCTFail("\(error)") }
    }
  }

  func testAnAnswerOtherThan200IsRefused() async throws {
    do {
      _ = try await download(.init(status: 404, chunks: 1, body: Data("missing".utf8), declaresLength: true), limit: 100)
      XCTFail("expected the download to be refused")
    } catch let error as AppUpgradeError {
      XCTAssertEqual(error, .download("the server answered 404"))
    }
  }
}

/// Serves `answer` to every request, its body in `chunks` pieces.
final class ServedArchive: URLProtocol {
  struct Answer {
    let status: Int
    let chunks: Int
    let body: Data
    let declaresLength: Bool
  }

  nonisolated(unsafe) static var answer = Answer(status: 200, chunks: 1, body: Data(), declaresLength: true)

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let answer = Self.answer
    let headers = answer.declaresLength ? ["Content-Length": String(answer.body.count)] : [:]
    let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let size = max(1, (answer.body.count + answer.chunks - 1) / answer.chunks)
    var offset = 0
    while offset < answer.body.count {
      let end = min(offset + size, answer.body.count)
      client?.urlProtocol(self, didLoad: answer.body.subdata(in: offset..<end))
      offset = end
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
