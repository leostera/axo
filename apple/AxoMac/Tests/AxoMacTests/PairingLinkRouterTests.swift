import XCTest
@testable import AxoMac

final class PairingLinkRouterTests: XCTestCase {
  @MainActor
  func testValidPairingLinkRoutesCanonicalCode() {
    let router = PairingLinkRouter()
    let link = URL(string: "axo://pair/b26a-nrkt")!

    XCTAssertTrue(router.receive(link))
    XCTAssertEqual(router.pendingCode?.value, "B26A-NRKT")
  }

  @MainActor
  func testRejectsNonPairingLinksWithoutReplacingPendingCode() {
    let router = PairingLinkRouter()
    let pairingLink = URL(string: "axo://pair/B26A-NRKT")!
    let invalidLink = URL(string: "axo://pair/not-a-code")!
    _ = router.receive(pairingLink)

    XCTAssertFalse(router.receive(invalidLink))
    XCTAssertEqual(router.pendingCode?.value, "B26A-NRKT")
  }
}
