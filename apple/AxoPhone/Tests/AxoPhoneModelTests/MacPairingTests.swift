import AxoClient
import AxoProtocol
import XCTest

@testable import AxoPhoneModel

@MainActor
final class MacPairingTests: XCTestCase {
  private struct Issuer: HostPairingIssuing {
    let result: Result<HostPairing, RelayError>
    func createHostPairing() async throws -> HostPairing { try result.get() }
  }

  /// A clock that moves only when the pairing waits, and runs `onSleep` each time it does.
  private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var onSleep: () -> Void = {}
    var now: Date { lock.withLock { current } }
    func sleep(_ duration: Duration) {
      lock.withLock { current += Double(duration.components.seconds) }
      onSleep()
    }
  }

  private let clock = FakeClock()
  private let studio = host("Studio")

  private func pairing(lasting seconds: TimeInterval = 600) -> HostPairing {
    HostPairing(code: HostPairingCode(parsing: "7KQ2-M4XD")!, expiresAt: clock.now + seconds)
  }

  private func make(_ issuer: Issuer, listing: SwitchableListing) async -> MacPairing {
    let hosts = HostsModel(listing: listing, account: AccountSession(store: MemoryTokenStore(SessionToken.fixture())))
    await hosts.refresh()
    let clock = clock
    return MacPairing(issuer: issuer, hosts: hosts, now: { clock.now }, sleep: { clock.sleep($0) })
  }

  func testTheCodeShowsUntilAMacThatWasNotListedBeforeRedeemsIt() async {
    let listing = SwitchableListing([studio])
    let pairing = pairing()
    let model = await make(Issuer(result: .success(pairing)), listing: listing)
    var polls = 0
    clock.onSleep = {
      polls += 1
      // The Macs already linked keep showing up; the new one arrives on the third look.
      if polls == 3 { listing.set([self.studio, host("Laptop")]) }
    }
    let states = Task { @MainActor in
      var seen: [MacPairing.State] = []
      while true {
        if seen.last != model.state { seen.append(model.state) }
        if case .linked = model.state { return seen }
        await Task.yield()
      }
    }
    await model.run()
    XCTAssertEqual(model.state, .linked(label: "Laptop"))
    XCTAssertEqual(polls, 3)
    let seen = await states.value
    XCTAssertTrue(seen.contains(.waiting(pairing)), "the code was shown while waiting: \(seen)")
  }

  func testACodeNobodyRedeemsExpires() async {
    let model = await make(Issuer(result: .success(pairing(lasting: 10))), listing: SwitchableListing([studio]))
    await model.run()
    XCTAssertEqual(model.state, .expired)
  }

  func testTooManyCodesSaysToWait() async {
    let model = await make(Issuer(result: .failure(.httpStatus(429))), listing: SwitchableListing([studio]))
    await model.run()
    guard case .failed(let message) = model.state else { return XCTFail("\(model.state)") }
    XCTAssertTrue(message.contains("Try again in a minute"), message)
  }
}

private func host(_ label: String) -> RemoteHost {
  try! JSONDecoder().decode(
    RemoteHost.self,
    from: Data("""
      {"hostId":"\(UUID().uuidString)","hostGeneration":"\(UUID().uuidString)","label":"\(label)","hostKind":"macos",
      "status":"online","stale":false,"lastSeenAt":"2026-10-16T00:00:00Z","sessions":[]}
      """.utf8))
}
