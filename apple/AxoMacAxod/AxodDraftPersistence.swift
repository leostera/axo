import Foundation

/// One cache owns this worker. The cache admits at most one active operation
/// and one coalesced latest snapshot; actor mailboxes are not an edit outbox.
actor AxodDraftPersistence {
    private let parent: URL
    private var store: AxodChatDraftStore?
    private var checkpoint: AxodChatDraftStore.Checkpoint?

    init(parent: URL) { self.parent = parent }

    func load() throws -> AxodChatDraftArchive? {
        guard store == nil else { throw AxodChatDraftStore.Failure.conflict }
        let root = try AxodChatDraftStore.provision(in: parent)
        let opened = try AxodChatDraftStore(root: root)
        let initial = try opened.load()
        store = opened; checkpoint = initial
        return initial.archive
    }
    func save(drafts: [AxodChatDraftArchive.Draft], pending: [AxodChatDraftArchive.Pending]) throws -> AxodChatDraftArchive {
        let archive = try AxodChatDraftArchive.make(drafts: drafts, pending: pending)
        guard let store, let checkpoint else { throw AxodChatDraftStore.Failure.fenced }
        self.checkpoint = try store.commit(archive, replacing: checkpoint)
        return archive
    }
}
