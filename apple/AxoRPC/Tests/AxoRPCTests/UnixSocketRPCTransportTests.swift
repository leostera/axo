import Darwin
import Foundation
import XCTest

@testable import AxoRPC

final class UnixSocketRPCTransportTests: XCTestCase {
  func testHealthFailsWhenTheSocketDoesNotExist() async throws {
    let path = "/tmp/axo-rpc-missing-\(UUID().uuidString).sock"
    do {
      _ = try await UnixSocketRPC.health(at: UnixSocketPath(path))
      XCTFail("Expected a missing socket to fail")
    } catch let error as UnixSocketRPCError {
      guard case .connectionFailed = error else {
        return XCTFail("Unexpected RPC error: \(error)")
      }
    }
  }

  func testHealthAcceptsAnOlderDaemonWithoutVersionInItsResponse() async throws {
    let fixture = try OneResponseUnixSocket(
      response: #"{"jsonrpc":"2.0","id":1,"result":{"buildNumber":41,"status":"running"}}"#
    )
    let responder = Task.detached {
      try fixture.receiveOneRequestAndReply()
    }

    let health = try await UnixSocketRPC.health(at: UnixSocketPath(fixture.path))
    _ = try await responder.value

    XCTAssertNil(health.version)
    XCTAssertEqual(health.buildNumber, 41)
    XCTAssertEqual(health.status, "running")
  }

  func testHealthUsesJsonRPCOverNewlineFramedUnixSocket() async throws {
    let fixture = try OneResponseUnixSocket(
      response:
        #"{"jsonrpc":"2.0","id":1,"result":{"version":"0.1.0","buildNumber":42,"status":"running"}}"#
    )
    let responder = Task.detached {
      try fixture.receiveOneRequestAndReply()
    }

    let health = try await UnixSocketRPC.health(at: UnixSocketPath(fixture.path))
    let requestData = try await responder.value
    let request = try XCTUnwrap(
      JSONSerialization.jsonObject(with: requestData) as? [String: Any]
    )

    XCTAssertEqual(health.version, "0.1.0")
    XCTAssertEqual(health.buildNumber, 42)
    XCTAssertEqual(health.status, "running")
    XCTAssertEqual(request["jsonrpc"] as? String, "2.0")
    XCTAssertEqual(request["method"] as? String, "axo.daemon.health")
    XCTAssertNotNil(request["id"])
  }
}

private final class OneResponseUnixSocket: @unchecked Sendable {
  private let fileDescriptor: Int32
  private let response: Data
  private let directory: URL
  let path: String

  init(response: String) throws {
    let temporaryDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
    directory =
      temporaryDirectory
      .appendingPathComponent("axo-rpc-\(UUID().uuidString.prefix(12))", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    path = directory.appendingPathComponent("axod.sock").path
    self.response = Data((response + "\n").utf8)

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    let copiedLength = path.withCString { source in
      withUnsafeMutablePointer(to: &address.sun_path) { destination in
        destination.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
          strlcpy($0, source, pathCapacity)
        }
      }
    }
    guard copiedLength < pathCapacity else {
      throw UnixSocketRPCError.invalidSocketPath
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0, Darwin.listen(fileDescriptor, 1) == 0 else {
      let error = POSIXError(.init(rawValue: errno) ?? .EIO)
      Darwin.close(fileDescriptor)
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  deinit {
    Darwin.close(fileDescriptor)
    try? FileManager.default.removeItem(at: directory)
  }

  func receiveOneRequestAndReply() throws -> Data {
    let client = Darwin.accept(fileDescriptor, nil, nil)
    guard client >= 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(client) }

    var request = Data()
    var byte: UInt8 = 0
    while Darwin.read(client, &byte, 1) == 1, byte != 0x0A {
      request.append(byte)
    }
    try response.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.send(
          client,
          baseAddress.advanced(by: offset),
          bytes.count - offset,
          0
        )
        guard count > 0 else {
          throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        offset += count
      }
    }
    return request
  }
}
