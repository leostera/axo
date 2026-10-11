import AxoProtocol
import Darwin
import Foundation

@main struct DraftPersistenceChecks {
    @MainActor static func main() async {
        do { try await checks() }
        catch { fputs("Draft persistence checks failed: class=Unexpected\n", stderr); exit(1) }
    }
    @MainActor private static func checks() async throws {
        guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw AxodChatDraftStore.Failure.unsafeStorage }
        let base = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("axo-draft-persistence-\(UUID())")
        free(canonical)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        func root() throws -> URL {
            let value = base.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return value
        }
        let machine = UUID(), session = UUID(), pane = UUID(), chat = UUID()
        func target() -> PiChatTarget {
            PiChatTarget(machineId: machine, hostGeneration: UUID(), workspaceId: nil, sessionId: session, paneId: pane,
                         runtimeHostGeneration: UUID(), runtimeGeneration: UUID(), chatId: chat)
        }
        let original = target(), resumed = target(), parent = try root()
        let cache = AxodChatDrafts(requiresPersistence: true)
        precondition(!cache.canEdit && !cache.edit("not accepted before trusted load", for: original))
        await cache.openStorage(in: parent)
        precondition(cache.canEdit && !cache.blocksAutomaticStartup)
        for value in 0..<1000 { precondition(cache.edit("coalesced synthetic revision \(value)", for: original)) }
        let flushed = await cache.flush()
        precondition(flushed)
        let fresh = AxodChatDrafts(requiresPersistence: true)
        await fresh.openStorage(in: parent)
        precondition(fresh.text(for: resumed) == "coalesced synthetic revision 999")
        let submission = fresh.capture(for: original, operation: .sendSteeringMessage)!
        let persisted = await fresh.persist(submission)
        precondition(persisted)
        let pending = AxodChatDrafts(requiresPersistence: true)
        await pending.openStorage(in: parent)
        precondition(pending.pending(for: resumed)?.commandID == submission.commandID)
        precondition(pending.pending(for: resumed)?.target == original && pending.pending(for: resumed)?.operation == .sendSteeringMessage)
        precondition(pending.capture(for: resumed) == nil)
        let mismatched = await pending.settle(commandID: submission.commandID, target: resumed, outcome: .dispatched)
        precondition(!mismatched && !pending.text(for: original).isEmpty)
        let unknown = await pending.settle(commandID: submission.commandID, target: original, outcome: .unknown)
        precondition(unknown && pending.pending(for: original) != nil)
        let rejected = await pending.settle(commandID: submission.commandID, target: original, outcome: .rejected)
        precondition(rejected && !pending.text(for: original).isEmpty)
        let accepted = pending.capture(for: resumed)!
        let acceptedSaved = await pending.persist(accepted)
        precondition(acceptedSaved)
        pending.edit("later edit", for: original)
        pending.edit("coalesced synthetic revision 999", for: original)
        let clearedOriginal = await pending.settle(commandID: accepted.commandID, target: resumed, outcome: .dispatched)
        precondition(clearedOriginal && pending.text(for: resumed) == "coalesced synthetic revision 999")
        let same = pending.capture(for: original)!
        let sameSaved = await pending.persist(same)
        precondition(sameSaved)
        let clear = await pending.settle(commandID: same.commandID, target: original, outcome: .dispatched)
        precondition(clear && pending.text(for: resumed).isEmpty)
        let afterAck = AxodChatDrafts(requiresPersistence: true)
        await afterAck.openStorage(in: parent)
        precondition(afterAck.text(for: original).isEmpty && afterAck.pending(for: original) == nil)

        // A stale process's accepted local editor value is not permission to
        // overwrite another process's archive. Failure keeps local text visible.
        cache.edit("stale process local edit", for: original)
        let staleSave = await cache.flush()
        precondition(!staleSave && cache.text(for: original) == "stale process local edit")
        precondition(cache.capture(for: original) == nil)
        let unchanged = AxodChatDrafts(requiresPersistence: true)
        await unchanged.openStorage(in: parent)
        precondition(unchanged.text(for: original).isEmpty)

        let lockedParent = try root(), locked = AxodChatDrafts(requiresPersistence: true)
        await locked.openStorage(in: lockedParent)
        locked.edit("ack must not erase on storage failure", for: original)
        let ticket = locked.capture(for: original)!
        let ticketSaved = await locked.persist(ticket)
        precondition(ticketSaved)
        let fd = open(lockedParent.appendingPathComponent("chat-drafts/drafts.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        precondition(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
        let failedClear = await locked.settle(commandID: ticket.commandID, target: original, outcome: .dispatched)
        precondition(!failedClear && locked.text(for: original) == "ack must not erase on storage failure")
        let refusedQuit = await locked.prepareToQuit()
        precondition(!refusedQuit && locked.canEdit)
        precondition(locked.pending(for: original)?.commandID == ticket.commandID)
        _ = flock(fd, LOCK_UN); close(fd)
        let recovered = AxodChatDrafts(requiresPersistence: true)
        await recovered.openStorage(in: lockedParent)
        precondition(recovered.text(for: resumed) == "ack must not erase on storage failure")
        precondition(recovered.pending(for: resumed)?.commandID == ticket.commandID && recovered.capture(for: resumed) == nil)

        let corruptParent = try root(), directory = corruptParent.appendingPathComponent("chat-drafts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("drafts.bin"), bytes = Data("opaque private draft".utf8)
        try bytes.write(to: file); chmod(file.path, 0o600)
        let corrupt = AxodChatDrafts(requiresPersistence: true)
        await corrupt.openStorage(in: corruptParent)
        precondition(!corrupt.canEdit && corrupt.blocksAutomaticStartup && corrupt.capture(for: original) == nil)
        let preserved = try Data(contentsOf: file)
        precondition(preserved == bytes)
        let quitParent = try root(), quitting = AxodChatDrafts(requiresPersistence: true)
        await quitting.openStorage(in: quitParent)
        quitting.edit("accepted before ordinary quit", for: original)
        let allowedQuit = await quitting.prepareToQuit()
        precondition(allowedQuit && !quitting.canEdit && !quitting.edit("late callback after quit barrier", for: original))
        let relaunched = AxodChatDrafts(requiresPersistence: true)
        await relaunched.openStorage(in: quitParent)
        precondition(relaunched.text(for: resumed) == "accepted before ordinary quit")
        print("PASS: off-typing-path bounded/coalesced draft persistence, fresh caches/exact resume, operation/target/revision tickets, rejected/unknown/ABA and conditional durable acknowledgement")
        print("PASS: stale process/lease failure fences, local text and original ticket preservation, opaque storage blocks automation without reset; not actual composer/crash/power-loss/branch acceptance")
    }
}
