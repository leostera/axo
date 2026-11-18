import Darwin
import Foundation
import XCTest

import AxoProtocol
@testable import AxoClient

/// RFD0069: Axo.app sends nothing on axod's socket until the listener is checked to be axod.
final class AxodPeerTests: XCTestCase {
  func testAxodIsNamedBySameCertificateAndItsOwnIdentifier() {
    let own = #"identifier "dev.leostera.axo" and anchor apple generic and certificate leaf[subject.OU] = "TEAM1234""#
    XCTAssertEqual(
      AxodPeer.axodRequirement(fromOwn: own),
      #"identifier "axod" and anchor apple generic and certificate leaf[subject.OU] = "TEAM1234""#)
    // An ad hoc build names no program, so it cannot name axod.
    XCTAssertNil(AxodPeer.axodRequirement(fromOwn: #"cdhash H"67f8ab""#))
    XCTAssertNil(AxodPeer.axodRequirement(fromOwn: #"identifier "dev.leostera.axo""#))
  }

  func testAListenerThatIsNotAxodGetsNothing() async throws {
    let listener = try Listener()
    let impostor = AxodPeer(requirement: #"identifier "axod" and anchor apple generic"#)
    let transport = UnixSocketTransport(socketPath: try UnixSocketPath(listener.path), peer: impostor)
    do {
      _ = try await transport.connect()
      XCTFail("connected to a listener that is not axod")
    } catch AxoClientError.untrustedPeer {}
    XCTAssertEqual(listener.received(), Data(), "not a byte went to it")
  }

  func testAListenerThatMeetsTheRequirementIsSpokenTo() async throws {
    // The test connects to itself, so its own designated requirement is the one to meet.
    let own = try XCTUnwrap(AxodPeer.ownDesignatedRequirement())
    let listener = try Listener()
    let transport = UnixSocketTransport(socketPath: try UnixSocketPath(listener.path), peer: AxodPeer(requirement: own))
    let channel = try await transport.connect()
    try await channel.send(Data("hello".utf8))
    channel.close()
    XCTAssertEqual(listener.received(), Data("hello\n".utf8))
  }

  func testTheAttachSocketIsCheckedBeforeTheShellIsNamed() throws {
    let listener = try Listener()
    let impostor = AxodPeer(requirement: #"identifier "axod" and anchor apple generic"#)
    XCTAssertThrowsError(
      try TerminalAttachment.open(socketPath: try UnixSocketPath(listener.path), shellID: 7, peer: impostor)
    ) { error in
      guard case AxoClientError.untrustedPeer = error else { return XCTFail("\(error)") }
    }
    XCTAssertEqual(listener.received(), Data())
  }

  func testABuildThatCannotCheckAxodSendsNoTypedValues() async throws {
    let unverified = UnixSocketTransport(
      socketPath: try UnixSocketPath("/tmp/axo-unverified-\(UUID().uuidString.prefix(8)).sock"),
      peer: AxodPeer(requirement: nil))
    let connection = AxodConnection(transport: unverified)
    do {
      try await connection.resolveElicitation("6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5a", action: .accept, values: ["f0": "hunter2"])
      XCTFail("typed values went to an unchecked socket")
    } catch AxoClientError.untrustedPeer {}
  }
}

/// A Unix socket that accepts one connection and keeps what it reads until the peer closes.
private final class Listener: @unchecked Sendable {
  let path: String
  private let socket: Int32
  private let directory: URL
  private let done = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var bytes = Data()

  init() throws {
    directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("axo-peer-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    path = directory.appendingPathComponent("axod.sock").path
    socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      let utf8 = Array(path.utf8)
      buffer.copyBytes(from: utf8)
      buffer[utf8.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, Darwin.listen(socket, 1) == 0 else { throw POSIXError(.EIO) }
    let socket = socket
    Thread.detachNewThread { [self] in
      let client = Darwin.accept(socket, nil, nil)
      defer {
        if client >= 0 { Darwin.close(client) }
        done.signal()
      }
      guard client >= 0 else { return }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = Darwin.read(client, &buffer, buffer.count)
        if count <= 0 { return }
        lock.withLock { bytes.append(contentsOf: buffer[..<count]) }
      }
    }
  }

  /// What the one connection sent, once it closed.
  func received() -> Data {
    _ = done.wait(timeout: .now() + 5)
    return lock.withLock { bytes }
  }

  deinit {
    Darwin.close(socket)
    try? FileManager.default.removeItem(at: directory)
  }
}
