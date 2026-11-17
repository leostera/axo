import AxoClient
import AxoProtocol
import XCTest

@testable import AxoMobileModel

private actor Uploads {
  var failures: Int
  let error: Error
  private(set) var inputs: [(Data, String, String)] = []

  init(failures: Int, error: Error = RelayError.unreachable("temporary network loss")) {
    self.failures = failures
    self.error = error
  }

  func upload(_ data: Data, name: String, mimeType: String) throws -> Attachment {
    inputs.append((data, name, mimeType))
    if failures > 0 {
      failures -= 1
      throw error
    }
    return Attachment(asset: "sha256:" + String(repeating: "ab", count: 32), name: name, mimeType: mimeType, size: data.count)
  }

  var count: Int { inputs.count }
}

@MainActor
final class AttachmentUploadTests: XCTestCase {
  private let picture: (data: Data, name: String, mimeType: String, thumbnail: Data?) =
    (Data("same picture bytes".utf8), "photo.png", "image/png", Data("small thumbnail".utf8))

  private func world(_ uploads: Uploads) async throws -> PhoneWorld {
    let world = PhoneWorld([Mac("A", online: true)], uploadAsset: { data, name, mime in
      try await uploads.upload(data, name: name, mimeType: mime)
    })
    world.workbench.uploadRetryDelays = [.milliseconds(1), .milliseconds(1)]
    try await world.start()
    return world
  }

  func testTwoTransientFailuresRecoverWithinOneBoundedBatchWithoutSending() async throws {
    let uploads = Uploads(failures: 2)
    let world = try await world(uploads)
    let phone = world.workbench!
    let selection = try XCTUnwrap(phone.selection)
    phone.attach([picture])
    let id = try XCTUnwrap(phone.attachments(for: selection).first?.id)
    try await eventually { phone.canSendDraft }
    let inputs = await uploads.inputs
    XCTAssertEqual(inputs.count, 3)
    XCTAssertTrue(inputs.allSatisfy { $0.0 == picture.data && $0.1 == picture.name && $0.2 == picture.mimeType })
    XCTAssertEqual(phone.attachments(for: selection).first?.id, id)
    XCTAssertFalse(phone.attachments(for: selection).first?.canRetry ?? true)
    XCTAssertTrue(world.creations.prompts.isEmpty, "completing an upload never sends")
  }

  func testExhaustionStopsUntilManualRetryAndRepeatedTapsStartOnlyOneUpload() async throws {
    let uploads = Uploads(failures: 3)
    let world = try await world(uploads)
    let phone = world.workbench!
    let selection = try XCTUnwrap(phone.selection)
    phone.attach([picture])
    try await eventually { phone.attachments(for: selection).first?.canRetry == true }
    let id = try XCTUnwrap(phone.attachments(for: selection).first?.id)
    let attempts = await uploads.count
    XCTAssertEqual(attempts, 3)
    XCTAssertFalse(phone.canSendDraft)
    try await Task.sleep(for: .milliseconds(20))
    let stopped = await uploads.count
    XCTAssertEqual(stopped, 3, "no background retry loop")
    phone.retryUpload(id)
    phone.retryUpload(id)
    phone.retryUpload(id)
    try await eventually { phone.canSendDraft }
    let retried = await uploads.count
    XCTAssertEqual(retried, 4)
    XCTAssertEqual(phone.attachments(for: selection).first?.id, id)
    XCTAssertTrue(world.creations.prompts.isEmpty)
  }

  func testPermanentRefusalsDoNotAutomaticallyRepeat() async throws {
    let uploads = Uploads(failures: 10, error: AppsRefusal(status: 413, message: "Too large"))
    let world = try await world(uploads)
    let phone = world.workbench!
    let selection = try XCTUnwrap(phone.selection)
    phone.attach([picture])
    try await eventually { phone.attachments(for: selection).first?.canRetry == true }
    let count = await uploads.count
    XCTAssertEqual(count, 1)
    XCTAssertEqual(phone.attachments(for: selection).first?.state, .failed("Too large"))
  }

  func testRemovingDuringBackoffCancelsFurtherAttempts() async throws {
    let uploads = Uploads(failures: 10)
    let world = try await world(uploads)
    let phone = world.workbench!
    phone.uploadRetryDelays = [.milliseconds(50), .milliseconds(50)]
    let selection = try XCTUnwrap(phone.selection)
    phone.attach([picture])
    let id = try XCTUnwrap(phone.attachments(for: selection).first?.id)
    for _ in 0..<100 {
      if await uploads.count > 0 { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    let started = await uploads.count
    XCTAssertEqual(started, 1)
    phone.detach(id)
    try await Task.sleep(for: .milliseconds(120))
    let count = await uploads.count
    XCTAssertEqual(count, 1)
    XCTAssertTrue(phone.attachments(for: selection).isEmpty)
  }

  func testAnUncooperativeLateUploadCannotResurrectARemovedAttachment() async throws {
    let gate = AsyncGate()
    let world = PhoneWorld([Mac("A", online: true)], uploadAsset: { data, name, mime in
      await gate.wait()
      return Attachment(asset: "sha256:" + String(repeating: "ab", count: 32), name: name, mimeType: mime, size: data.count)
    })
    try await world.start()
    let phone = world.workbench!
    let selection = try XCTUnwrap(phone.selection)
    phone.attach([picture])
    let id = try XCTUnwrap(phone.attachments(for: selection).first?.id)
    await Task.yield()
    phone.detach(id)
    await gate.open()
    await Task.yield()
    XCTAssertTrue(phone.attachments(for: selection).isEmpty)
  }

  func testAnUploadingDraftCanMoveHostsWithoutStrandingItsSpinner() async throws {
    let a = Mac("A", online: true), b = Mac("B", online: true)
    let gate = AsyncGate()
    let world = PhoneWorld([a, b], uploadAsset: { data, name, mime in
      await gate.wait()
      return Attachment(asset: "sha256:" + String(repeating: "ab", count: 32), name: name, mimeType: mime, size: data.count)
    })
    try await world.start()
    let phone = world.workbench!
    phone.select(host: a.id, session: nil)
    let original = try XCTUnwrap(phone.selection)
    phone.attach([picture])
    let id = try XCTUnwrap(phone.attachments(for: original).first?.id)
    phone.chooseHost(b.id)
    let moved = try XCTUnwrap(phone.selection)
    XCTAssertEqual(phone.attachments(for: moved).first?.id, id)
    await gate.open()
    try await eventually { phone.canSendDraft }
    XCTAssertTrue(phone.attachments(for: original).isEmpty)
    XCTAssertEqual(phone.attachments(for: moved).first?.id, id)
    XCTAssertTrue(world.creations.prompts.isEmpty)
  }

  func testOversizeFilesCannotRetryAndNeverStartAnUpload() async throws {
    let uploads = Uploads(failures: 0)
    let world = try await world(uploads)
    let phone = world.workbench!
    let selection = try XCTUnwrap(phone.selection)
    phone.attach([(Data(count: Attachment.maxBytes + 1), "huge.bin", "application/octet-stream", nil)])
    let file = try XCTUnwrap(phone.attachments(for: selection).first)
    XCTAssertFalse(file.canRetry)
    XCTAssertEqual(file.state, .failed("Files can be at most 100 MB."))
    phone.retryUpload(file.id)
    let count = await uploads.count
    XCTAssertEqual(count, 0)
  }

  func testTransportInterruptionOffersRetryInsteadOfLeavingAnEndlessSpinner() async throws {
    let uploads = Uploads(failures: 1, error: CancellationError())
    let world = try await world(uploads)
    let phone = world.workbench!
    let selection = try XCTUnwrap(phone.selection)
    phone.attach([picture])
    try await eventually { phone.attachments(for: selection).first?.canRetry == true }
    XCTAssertEqual(phone.attachments(for: selection).first?.state, .failed("Upload interrupted. Tap to retry."))
  }
}
