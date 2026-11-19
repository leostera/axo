import AxoProtocol
import XCTest
@testable import AxoMobileModel

final class HostPresentationTests: XCTestCase {
  private func host(kind: String = "macos", model: HostModel? = nil, label: String = "Host") -> RemoteHost {
    RemoteHost(hostId: UUID(), hostGeneration: UUID(), label: label, hostKind: kind,
      model: model, status: .online, sessions: [])
  }

  func testOSMarksTakePrecedenceAndMacsKeepHardwareSymbols() {
    XCTAssertEqual(HostPresentation.logoName(host(kind: "linux")), "host-linux")
    XCTAssertEqual(HostPresentation.logoName(host(kind: "windows")), "host-windows")
    XCTAssertNil(HostPresentation.logoName(host(model: HostModel(identifier: "Mac13,2"))))
  }

  func testOnlyAnEntirelyKnownMacCollectionIsCalledMacs() {
    let studio = host(model: HostModel(identifier: "Mac13,2", name: "Mac Studio"))
    let book = host(model: HostModel(identifier: "MacBookPro18,1"))
    XCTAssertEqual(HostPresentation.collectionName([studio, book]), "Macs")
    XCTAssertEqual(HostPresentation.collectionName([studio, host(kind: "linux")]), "Hosts")
    XCTAssertEqual(HostPresentation.collectionName([]), "Hosts")
  }

  func testLegacyMacosTagAndEditableNameAreNotHardwareEvidence() {
    let unknown = host(label: "MacBook Pro")
    XCTAssertFalse(HostPresentation.isKnownMac(unknown))
    XCTAssertEqual(HostPresentation.collectionName([unknown]), "Hosts")
    XCTAssertEqual(HostPresentation.symbol(unknown), "server.rack")
    XCTAssertFalse(HostPresentation.isKnownMac(host(kind: "linux",
      model: HostModel(identifier: "Mac13,2", name: "Mac Studio"))))
  }

  func testSymbolsDescribeKnownHardwareWithoutGuessingALaptop() {
    XCTAssertEqual(HostPresentation.symbol(host(model: HostModel(identifier: "Mac13,2", name: "Mac Studio"))), "macstudio")
    XCTAssertEqual(HostPresentation.symbol(host(model: HostModel(identifier: "MacBookPro18,1"))), "laptopcomputer")
    XCTAssertEqual(HostPresentation.symbol(host(model: HostModel(identifier: "Mac99,1"))), "desktopcomputer")
    XCTAssertEqual(HostPresentation.symbol(host(kind: "windows")), "desktopcomputer")
    XCTAssertEqual(HostPresentation.symbol(host(kind: "linux")), "server.rack")
  }
}
