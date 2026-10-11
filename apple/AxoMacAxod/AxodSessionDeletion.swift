import Foundation
import AxoProtocol

/// Frozen row identities/revision, not whichever session is displayed when a menu completes.
struct AxodSessionDeletion {
    let id = UUID()
    let operation: UUID
    let parameters: SessionDeletionParameters
    let names: [String]
}
