import AxoProtocol
import Foundation

/// Local reconciliation hints contain identities only; prompt bodies remain owned by Pi.
struct PendingPiStart: Codable, Equatable {
    let target: PiSessionTarget
    let commandId: UUID
    let persistence: PiPersistence
}

struct PendingPiCommand: Codable, Equatable {
    let target: PiChatTarget
    let commandId: UUID
    let operation: PiChatOperation
}
