import AxoProtocol
import Foundation

/// Resolves one sidebar/window label without turning Pi metadata into durable
/// Axo naming authority. Only the selected exact live binding may supply a
/// temporary title, and a manual Axo name always wins.
public enum CentralSessionDisplayName {
    public static func resolve(
        catalogName: String,
        manualName: Bool,
        sessionId: UUID,
        workspaceId: UUID?,
        selectedSessionId: UUID?,
        source: CentralSource?,
        revision: CentralRevision?,
        piResponse: CentralResponse?,
        piReadUnavailable: Bool
    ) -> String {
        guard !manualName,
              selectedSessionId == sessionId,
              !piReadUnavailable,
              let source,
              let revision,
              let piResponse,
              piResponse.source == source,
              piResponse.revision == revision,
              case .piObservation(.live(let target, let state)) = piResponse.payload,
              target.source == source,
              target.sessionId == sessionId,
              target.workspaceId == workspaceId,
              let title = state.title else {
            return catalogName
        }
        return title
    }
}
