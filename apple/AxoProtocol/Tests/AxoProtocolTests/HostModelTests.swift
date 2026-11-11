import XCTest

@testable import AxoProtocol

final class HostModelTests: XCTestCase {
  func testAHostListedWithItsModelHasItAndOneTooOldToSayHasNone() throws {
    let listed = #"""
      [{"hostId":"18355f00-95fd-4c93-8586-a71a8a52bf73","hostGeneration":"c3b6da28-55c0-4bb0-ac04-dd458fd41a2b","label":"Studio","hostKind":"macos","model":{"identifier":"Mac13,2","name":"Mac Studio"},"online":true,"lastSeenAt":"2026-11-11T00:00:00Z"},
       {"hostId":"28355f00-95fd-4c93-8586-a71a8a52bf73","hostGeneration":"c3b6da28-55c0-4bb0-ac04-dd458fd41a2b","label":"Old","hostKind":"macos","online":false,"lastSeenAt":"2026-11-11T00:00:00Z"}]
      """#
    let hosts = try JSONDecoder().decode([ClientHost].self, from: Data(listed.utf8))
    XCTAssertEqual(hosts[0].model, HostModel(identifier: "Mac13,2", name: "Mac Studio"))
    XCTAssertNil(hosts[1].model)
    // Renamed or seen again, it is still the same kind of Mac.
    XCTAssertEqual(hosts[0].named("Desk").model, hosts[0].model)
    XCTAssertEqual(hosts[0].present(online: false, generation: nil).model, hosts[0].model)
    XCTAssertEqual(RemoteHost(hosts[0], sessions: []).model?.family, .studio)
  }

  func testAMacIsShownByTheShapeItsNameSaysOrElseItsIdentifier() {
    XCTAssertEqual(HostModel(identifier: "Mac16,8", name: "MacBook Pro (14-inch, Nov 2024)").family, .laptop)
    XCTAssertEqual(HostModel(identifier: "Mac15,12", name: "MacBook Air (13-inch, M3, 2024)").family, .laptop)
    XCTAssertEqual(HostModel(identifier: "Mac13,2", name: "Mac Studio").family, .studio)
    XCTAssertEqual(HostModel(identifier: "Mac16,10", name: "Mac mini (2024)").family, .mini)
    XCTAssertEqual(HostModel(identifier: "Mac16,2", name: "iMac (24-inch, 2024)").family, .desktop)
    XCTAssertEqual(HostModel(identifier: "Mac14,8", name: "Mac Pro (2023)").family, .tower)
    // An Intel Mac has no name in its device tree; its identifier says it.
    XCTAssertEqual(HostModel(identifier: "MacBookPro16,1").family, .laptop)
    XCTAssertEqual(HostModel(identifier: "Macmini8,1").family, .mini)
    XCTAssertEqual(HostModel(identifier: "iMac20,1").family, .desktop)
    XCTAssertEqual(HostModel(identifier: "MacPro7,1").family, .tower)
    // An Apple silicon identifier without a name says nothing.
    XCTAssertNil(HostModel(identifier: "Mac13,2").family)
  }
}
