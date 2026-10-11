import AxoProtocol
import Darwin
import Foundation

@main struct ChatDraftStorageChecks {
    @MainActor private static var phase = "Setup"
    @MainActor static func main() {
        do { try checks() }
        catch {
            let classification = (error as? AxodChatDraftStore.Failure).map { String(describing: $0) } ?? "Other"
            fputs("Draft storage checks failed: stage=\(phase) class=\(classification)\n", stderr); exit(1)
        }
    }
    @MainActor private static func checks() throws {
        guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw AxodChatDraftStore.Failure.unsafeStorage }
        let temporary = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        let base = temporary.appendingPathComponent("axo-draft-store-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        func root() throws -> URL {
            let value = base.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return value
        }
        func target(workspace: UUID? = nil) -> PiChatTarget {
            PiChatTarget(machineId: UUID(), hostGeneration: UUID(), workspaceId: workspace, sessionId: UUID(), paneId: UUID(),
                         runtimeHostGeneration: UUID(), runtimeGeneration: UUID(), chatId: UUID())
        }
        let original = target(), other = target(workspace: UUID())
        let text = "synthetic private draft 🦊\n\"\\\0"
        let entry = AxodChatDraftArchive.Draft(conversation: .init(original), revision: UUID(), text: text)
        let pending = AxodChatDraftArchive.Pending(commandID: UUID(), target: original, revision: entry.revision)
        let archive = try AxodChatDraftArchive.make(drafts: [entry, .init(conversation: .init(other), revision: UUID(), text: "other")], pending: [pending])
        let parsed = try AxodChatDraftArchive.parse(archive.encoded)
        precondition(parsed.encoded == archive.encoded && parsed.drafts[0].text == text)
        precondition(parsed.pending[0].target == original && parsed.pending[0].commandID == pending.commandID)
        for end in 0..<archive.encoded.count { precondition((try? AxodChatDraftArchive.parse(archive.encoded.prefix(end))) == nil) }
        precondition((try? AxodChatDraftArchive.parse(archive.encoded + Data([0]))) == nil)
        var version = archive.encoded; version[10] = 2
        precondition((try? AxodChatDraftArchive.parse(version)) == nil)
        precondition((try? AxodChatDraftArchive.make(drafts: [entry, entry], pending: [])) == nil)
        precondition((try? AxodChatDraftArchive.make(drafts: [], pending: [pending, pending])) == nil)
        precondition((try? AxodChatDraftArchive.make(drafts: [.init(conversation: .init(original), revision: UUID(), text: "")], pending: [])) == nil)
        let nilID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        precondition((try? AxodChatDraftArchive.make(revision: nilID, drafts: [], pending: [])) == nil)
        let large = String(repeating: "🦊", count: AxodChatDrafts.maximumDraftBytes / 4)
        var full: [AxodChatDraftArchive.Draft] = []
        for _ in 0..<16 { full.append(.init(conversation: .init(target()), revision: UUID(), text: large)) }
        let bounded = try AxodChatDraftArchive.make(drafts: full, pending: [])
        let parsedBounded = try AxodChatDraftArchive.parse(bounded.encoded)
        precondition(parsedBounded.drafts.count == 16)
        full.append(.init(conversation: .init(target()), revision: UUID(), text: "refused"))
        precondition((try? AxodChatDraftArchive.make(drafts: full, pending: [])) == nil)

        phase = "StoreInit"
        let location = try root(), store = try AxodChatDraftStore(root: location)
        phase = "StoreRead"
        let absent = try store.load()
        precondition(absent.archive == nil)
        phase = "StoreCommit"
        let first = try store.commit(archive, replacing: absent)
        precondition(first.archive?.encoded == archive.encoded)
        phase = "StoreReopen"
        let reopened = try AxodChatDraftStore(root: location), restored = try reopened.load()
        precondition(restored.archive?.encoded == archive.encoded)
        let replacement = try AxodChatDraftArchive.make(drafts: [.init(conversation: entry.conversation, revision: UUID(), text: "later revision")], pending: [pending])
        let current = try reopened.commit(replacement, replacing: restored)
        fails(.conflict) { _ = try store.commit(archive, replacing: absent) }
        fails(.conflict) { _ = try store.commit(replacement, replacing: restored) }
        let afterConflict = try store.load()
        precondition(afterConflict.archive?.encoded == replacement.encoded)
        let lock = open(location.appendingPathComponent("drafts.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        precondition(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
        fails(.writerBusy) { _ = try store.load() }
        let duplicate = dup(lock)
        precondition(duplicate >= 0)
        _ = flock(lock, LOCK_UN); close(lock)
        let afterUnlock = try store.load()
        precondition(afterUnlock.archive?.encoded == replacement.encoded)
        close(duplicate)
        precondition(current.archive?.pending[0].revision == entry.revision)

        // Opaque/corrupt/unsafe files are preserved, never reset to an empty draft.
        phase = "UnsafeCases"
        let badRoot = try root(), badPath = badRoot.appendingPathComponent("drafts.bin")
        try Data("opaque".utf8).write(to: badPath)
        chmod(badPath.path, 0o600)
        let corrupt = try AxodChatDraftStore(root: badRoot)
        fails(.invalidArchive) { _ = try corrupt.load() }
        let preservedOpaque = try Data(contentsOf: badPath)
        precondition(preservedOpaque == Data("opaque".utf8))
        chmod(badPath.path, 0o644)
        fails(.unsafeStorage) { _ = try corrupt.load() }
        chmod(badPath.path, 0o600)
        let hardRoot = try root(), hardPath = hardRoot.appendingPathComponent("drafts.bin")
        precondition(link(badPath.path, hardPath.path) == 0)
        fails(.unsafeStorage) { _ = try AxodChatDraftStore(root: hardRoot).load() }
        let symRoot = try root()
        precondition(symlink(badPath.path, symRoot.appendingPathComponent("drafts.bin").path) == 0)
        fails(.unsafeStorage) { _ = try AxodChatDraftStore(root: symRoot).load() }
        let fifoRoot = try root()
        precondition(mkfifo(fifoRoot.appendingPathComponent("drafts.bin").path, 0o600) == 0)
        fails(.unsafeStorage) { _ = try AxodChatDraftStore(root: fifoRoot).load() }
        let alias = base.appendingPathComponent("alias")
        precondition(symlink(location.path, alias.path) == 0)
        fails(.unsafeStorage) { _ = try AxodChatDraftStore(root: alias) }
        fails(.unsafeStorage) { _ = try AxodChatDraftStore(root: alias.appendingPathComponent("child")) }
        chmod(location.path, 0o755)
        fails(.unsafeStorage) { _ = try store.load() }
        chmod(location.path, 0o700)
        let oldLocation = base.appendingPathComponent("retained-root")
        try FileManager.default.moveItem(at: location, to: oldLocation)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        fails(.unsafeStorage) { _ = try store.load() }
        let retained = try AxodChatDraftStore(root: oldLocation).load()
        precondition(retained.archive?.encoded == replacement.encoded)
        let lockRoot = try root()
        precondition(symlink(badPath.path, lockRoot.appendingPathComponent("drafts.lock").path) == 0)
        fails(.unsafeStorage) { _ = try AxodChatDraftStore(root: lockRoot).load() }
        let bigRoot = try root(), bigPath = bigRoot.appendingPathComponent("drafts.bin")
        let big = open(bigPath.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        precondition(big >= 0 && ftruncate(big, off_t(AxodChatDraftArchive.maximumEncodedBytes + 1)) == 0)
        close(big)
        fails(.invalidArchive) { _ = try AxodChatDraftStore(root: bigRoot).load() }

        phase = "FaultCases"
        for fault in [AxodChatDraftStore.FixtureFault.beforeRename, .afterRename] {
            let faultRoot = try root(), faultStore = try AxodChatDraftStore(root: faultRoot)
            let checkpoint = try faultStore.commit(archive, replacing: faultStore.load())
            faultStore.fixtureFault = fault
            fails(.io) { _ = try faultStore.commit(replacement, replacing: checkpoint) }
            fails(.fenced) { _ = try faultStore.commit(replacement, replacing: checkpoint) }
            let recovery = try AxodChatDraftStore(root: faultRoot).load()
            precondition(recovery.archive?.encoded == (fault == .beforeRename ? archive.encoded : replacement.encoded))
            let files = try FileManager.default.contentsOfDirectory(atPath: faultRoot.path).sorted()
            precondition(files == ["drafts.bin", "drafts.lock"])
        }
        print("PASS: bounded closed draft archive, exact logical/dispatch identities, pending revisions, UTF-8 and opaque/truncated/capacity refusal")
        print("PASS: pinned owner-only draft storage, fresh-store reads, writer lease/release, stale CAS refusal, unsafe/opaque preservation and pre/post-rename write fences; not editor integration or crash/power-loss proof")
    }
    private static func fails(_ expected: AxodChatDraftStore.Failure, _ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected static storage failure") }
        catch { precondition(error as? AxodChatDraftStore.Failure == expected) }
    }
}
