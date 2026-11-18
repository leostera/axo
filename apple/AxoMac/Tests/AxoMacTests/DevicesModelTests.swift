import AxoProtocol
import XCTest

@testable import AxoMac

@MainActor
private final class FakeDevicesClient: AxodDevicesClient {
  var devices = AnsweringDevices(allowed: [], waiting: [], inputKey: "1a2b 3c4d 5e6f 7a8b")
  private(set) var decisions: [(String, Bool)] = []
  private(set) var revoked: [String] = []

  func answeringDevices() async throws -> AnsweringDevices { devices }

  func decideDevice(_ key: String, allow: Bool) async throws {
    decisions.append((key, allow))
    let device = devices.waiting.filter { $0.key == key }
    devices = AnsweringDevices(
      allowed: devices.allowed + (allow ? device : []), waiting: devices.waiting.filter { $0.key != key },
      inputKey: devices.inputKey)
  }

  func revokeDevice(_ key: String) async throws {
    revoked.append(key)
    devices = AnsweringDevices(
      allowed: devices.allowed.filter { $0.key != key }, waiting: devices.waiting, inputKey: devices.inputKey)
  }
}

@MainActor
final class DevicesModelTests: XCTestCase {
  private let phone = AnsweringDevice(key: "AAAA", name: "Leo's iPhone", fingerprint: "6520 7919 59be e144", at: 1)

  func testAWaitingDeviceIsAllowedOnceThenRemoved() async {
    let client = FakeDevicesClient()
    client.devices = AnsweringDevices(allowed: [], waiting: [phone], inputKey: "1a2b 3c4d 5e6f 7a8b")
    let model = DevicesModel(client: client)
    await model.refresh()
    XCTAssertEqual(model.devices?.inputKey, "1a2b 3c4d 5e6f 7a8b", "the Mac shows its key for devices to compare")
    await model.decide("AAAA", allow: true)
    await model.decide("AAAA", allow: true)
    XCTAssertEqual(client.decisions.map(\.0), ["AAAA"], "a device no longer waiting is not decided again")
    XCTAssertEqual(model.devices?.allowed, [phone])
    XCTAssertEqual(model.devices?.waiting, [])
    await model.revoke("AAAA")
    XCTAssertEqual(client.revoked, ["AAAA"])
    XCTAssertEqual(model.devices?.allowed, [])
  }

  func testOnlyWaitingDevicesAreDecidedAndOnlyAllowedOnesRemoved() async {
    let client = FakeDevicesClient()
    let model = DevicesModel(client: client)
    await model.refresh()
    await model.decide("AAAA", allow: true)
    await model.revoke("AAAA")
    XCTAssertTrue(client.decisions.isEmpty)
    XCTAssertTrue(client.revoked.isEmpty)
  }
}
