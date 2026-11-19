#if DEBUG && targetEnvironment(simulator)
import AxoMobileModel
import AxoProtocol
import Foundation

/// UI fixtures never send fake credentials or codes to the real account service.
actor PreviewDeviceLinkingClient: DeviceLinkingClient {
  func redeemDevicePairing(_ claim: DevicePairingClaim) async throws -> DevicePairingReceipt {
    throw DeviceLinkError.notConfirmed
  }
  func linkDevice(_ grant: DeviceLinkGrant) async throws { throw DeviceLinkError.notConfirmed }
  func unlinkDevice(_ revocation: DeviceUnlink) async throws { throw DeviceLinkError.notConfirmed }
  func deviceLinkMailbox(_ command: DeviceLinkMailboxCommand) async throws -> DeviceMailboxReceipt {
    let state: String
    switch command {
    case .create, .poll: state = "waiting"
    case .cancel: state = "cancelled"
    case .complete: throw DeviceLinkError.notConfirmed
    }
    return try JSONDecoder().decode(DeviceMailboxReceipt.self, from: JSONSerialization.data(withJSONObject: ["state": state]))
  }
}
#endif
