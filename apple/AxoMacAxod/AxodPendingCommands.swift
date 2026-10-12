import AxoProtocol
import Foundation

/// Local reconciliation hints contain identities only; prompt bodies remain owned by Pi.
struct PendingPiCommand: Codable, Equatable {
    let target: PiChatTarget
    let commandId: UUID
    let operation: PiChatOperation
}
