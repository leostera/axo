import AxoProtocol
import Foundation

/// Fixtures name Sessions by small numbers: `7` is the Session ID
/// `00000007-0000-4000-8000-000000000007`. Only tests may write a Session ID as a number; the
/// app's `SessionID` is a UUID and has no integer form (RFD0017).
extension SessionID: @retroactive ExpressibleByIntegerLiteral {
  public init(integerLiteral value: UInt32) { self = .fixture(value) }

  static func fixture(_ number: UInt32) -> SessionID {
    SessionID(rawValue: String(format: "%08x-0000-4000-8000-%012x", number, number))!
  }
}
