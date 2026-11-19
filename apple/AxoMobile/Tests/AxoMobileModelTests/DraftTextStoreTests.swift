import Foundation
import XCTest
@testable import AxoMobileModel

@MainActor
final class DraftTextStoreTests: XCTestCase {
  private func location() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root.appendingPathComponent("drafts.json")
  }

  func testTypedDraftsSurviveModelRecreationWithoutSending() throws {
    let url = try location()
    let target = PhoneWorkbench.Selection(host: UUID(), session: nil)
    let elsewhere = PhoneWorkbench.Selection(host: UUID(), session: 1)
    let world = PhoneWorld([], draftStore: DraftTextStore(url: url))
    world.workbench.setDraft("Fix the café 🌱", for: target)
    world.workbench.setDraft("Other chat", for: elsewhere)
    let restored = PhoneWorld([], draftStore: DraftTextStore(url: url))
    XCTAssertEqual(restored.workbench.draft(for: target), "Fix the café 🌱")
    XCTAssertEqual(restored.workbench.draft(for: elsewhere), "Other chat")
    XCTAssertTrue(restored.creations.prompts.isEmpty)
    XCTAssertNil(restored.workbench.draftStorageFailure)
  }

  func testPartialRecognitionRestoresOnceAndHandoffDoesNotDuplicateIt() throws {
    let url = try location()
    let target = PhoneWorkbench.Selection(host: UUID(), session: nil)
    let world = PhoneWorld([], draftStore: DraftTextStore(url: url))
    world.workbench.setDraft("Typed", for: target)
    let id = UUID()
    world.workbench.checkpointVoice(VoiceTranscript(id: id, text: "heard", delivery: .draft, destination: target))
    let transcript = VoiceTranscript(id: id, text: "heard more", delivery: .send, destination: target)
    world.workbench.checkpointVoice(transcript)
    let recovered = PhoneWorld([], draftStore: DraftTextStore(url: url))
    XCTAssertEqual(recovered.workbench.draft(for: target), "Typed heard more")
    XCTAssertTrue(recovered.creations.prompts.isEmpty, "Restored Send intent is never executed")
    recovered.workbench.setDraft("Typed heard more edited", for: target)
    XCTAssertEqual(PhoneWorld([], draftStore: DraftTextStore(url: url)).workbench.draft(for: target), "Typed heard more edited")
    // The ordinary live handoff atomically replaces its checkpoint with finalized text.
    world.workbench.keepVoiceTranscript(transcript)
    XCTAssertEqual(PhoneWorld([], draftStore: DraftTextStore(url: url)).workbench.draft(for: target), "Typed heard more")
  }

  func testExplicitCancelKeepsTypedTextButRemovesRecordingCheckpoint() throws {
    let url = try location()
    let target = PhoneWorkbench.Selection(host: UUID(), session: nil)
    let world = PhoneWorld([], draftStore: DraftTextStore(url: url))
    world.workbench.setDraft("Typed", for: target)
    world.workbench.checkpointVoice(VoiceTranscript(text: "discard this", delivery: .draft, destination: target))
    world.workbench.checkpointVoice(nil)
    XCTAssertEqual(PhoneWorld([], draftStore: DraftTextStore(url: url)).workbench.draft(for: target), "Typed")
  }

  func testCorruptSavedDataIsNotOverwrittenBySubsequentTyping() throws {
    let url = try location()
    let original = Data("unreadable archive".utf8)
    try original.write(to: url)
    let world = PhoneWorld([], draftStore: DraftTextStore(url: url))
    XCTAssertNotNil(world.workbench.draftStorageFailure)
    let target = PhoneWorkbench.Selection(host: UUID(), session: nil)
    world.workbench.setDraft("still usable in memory", for: target)
    XCTAssertEqual(world.workbench.draft(for: target), "still usable in memory")
    XCTAssertEqual(try Data(contentsOf: url), original)
  }

  func testSigningOutPreventsOldModelFromWritingAnotherSnapshot() throws {
    let url = try location()
    let target = PhoneWorkbench.Selection(host: UUID(), session: nil)
    let world = PhoneWorld([], draftStore: DraftTextStore(url: url))
    world.workbench.setDraft("Before sign-out", for: target)
    XCTAssertTrue(world.account.signOut())
    world.workbench.checkpointVoice(VoiceTranscript(text: "late recognition", delivery: .draft, destination: target))
    XCTAssertEqual(DraftTextStore(url: url).restoredTexts().first?.text, "Before sign-out")
  }
}
