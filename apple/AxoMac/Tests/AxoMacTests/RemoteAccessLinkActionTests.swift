import AxoProtocol
import XCTest

@testable import AxoMac

final class RemoteAccessLinkActionTests: XCTestCase {
  private func status(linked: Bool?) -> RemoteAccessStatus {
    RemoteAccessStatus(
      state: .connected, connectedSinceUnixMillis: nil, hostName: "Studio", hostKind: "macos",
      lastError: nil, linked: linked)
  }

  func testAnUnlinkedMacLinksWithOneClick() {
    XCTAssertEqual(RemoteAccessLinkAction(status: status(linked: false)), .link)
  }

  func testALinkedMacOrOneThatDoesNotSayIsReplacedOnlyOnceConfirmed() {
    XCTAssertEqual(RemoteAccessLinkAction(status: status(linked: true)), .replace)
    XCTAssertEqual(RemoteAccessLinkAction(status: status(linked: nil)), .replace)
    XCTAssertEqual(RemoteAccessLinkAction(status: nil), .replace)
  }
}
