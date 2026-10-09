import AxoCore
import Foundation

@MainActor
enum PhotoPublication {
    /// A Photos selection authorizes this upload, not a prompt. Re-check the
    /// destination after staging so a session/endpoint switch cannot retarget it.
    static func addSelectedPhoto(_ source: URL, to client: SessionFilesClient,
                                 isCurrentDestination: () -> Bool) async throws {
        let session = client.sessionId
        guard isCurrentDestination() else { throw FileTransferError.message("Photo destination changed. Choose a photo again in the intended conversation.") }
        guard let id = await client.addFile(source) else { return }
        guard isCurrentDestination(), client.sessionId == session else {
            throw FileTransferError.message("Photo kept as a local draft in its original conversation. Review it there before uploading.")
        }
        client.retryUpload(id)
    }
}
