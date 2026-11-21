import AxoProtocol
import Foundation

/// The account's published transcript boundary, not the cursor of the page on screen.
public struct SessionForkSnapshot: Equatable, Sendable {
  public let hostID: UUID
  public let sessionID: SessionID
  public let epoch: Int64
  public let head: Int64

  public init(_ source: RemoteSession) throws {
    guard let epoch = source.epoch, epoch > 0, let head = source.head, head > 0 else {
      throw SessionForkError.historyUnavailable
    }
    hostID = source.hostId
    sessionID = source.sessionId
    self.epoch = epoch
    self.head = head
  }
}

/// An unacknowledged submission must be replayed with exactly the same payload and ID.
public struct SessionForkAttempt: Equatable, Sendable {
  public let id: UUID
  public let folder: String?
  public let agent: CodingAgent?

  public init(id: UUID = UUID(), folder: String?, agent: CodingAgent?) {
    self.id = id
    self.folder = folder
    self.agent = agent
  }
}

public enum SessionForkError: LocalizedError, Equatable {
  case harnessUnavailable
  case historyUnavailable
  case destinationUnavailable
  case selectionChanged
  case pendingAttempt

  public var errorDescription: String? {
    switch self {
    case .harnessUnavailable: "The selected harness is no longer available."
    case .historyUnavailable: "This session’s history is not available to fork yet."
    case .destinationUnavailable: "The destination machine is no longer available."
    case .selectionChanged: "This session is no longer available to fork here."
    case .pendingAttempt: "Retry the existing fork before requesting a new one."
    }
  }

  public static func permitsNewAttempt(_ error: Error) -> Bool {
    (error as? Self) == .harnessUnavailable || needsDestinationFolder(error)
  }

  public static func needsDestinationFolder(_ error: Error) -> Bool {
    guard let rpc = error as? AxoClientError,
      case .serverRejected(_, let message) = rpc else { return false }
    return message == "Choose a destination folder"
  }
}

extension RemoteSession {
  func forkChild(of sourceID: SessionID, on destinationID: UUID) throws -> RemoteSession {
    guard hostId == destinationID, sessionId != sourceID else {
      throw AxoClientError.invalidResponse("the host did not return a new Session on the destination")
    }
    return self
  }
}
