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
  private let studio = Mac("Studio", online: true)

  private func pairing(lasting seconds: TimeInterval = 600) -> HostPairing {
    HostPairing(code: HostPairingCode(parsing: "7KQ2-M4XD")!, expiresAt: clock.now + seconds)
  }

  private func make(_ issuer: Issuer, macs: [Mac]) async throws -> (MacPairing, PhoneWorld) {
    let world = PhoneWorld(macs)
    try await world.start()
    let clock = clock
    let workbench = world.workbench!
    let pairing = MacPairing(
      issuer: issuer, hosts: workbench.hosts, refresh: { await workbench.refresh() }, now: { clock.now },
      sleep: { clock.sleep($0) })
    return (pairing, world)
  }

  func testTheCodeShowsUntilAMacThatWasNotListedBeforeRedeemsIt() async throws {
    let pairing = pairing()
    let (model, world) = try await make(Issuer(result: .success(pairing)), macs: [studio])
    var polls = 0
    let transport = world.transport
    let studio = studio
    clock.onSleep = {
      polls += 1
      // The Macs already linked keep showing up; the new one arrives on the third look.
      if polls == 3 { transport.listing = Mac.listing([studio, Mac("Laptop", online: true)]) }
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

  func testACodeNobodyRedeemsExpires() async throws {
    let (model, _) = try await make(Issuer(result: .success(pairing(lasting: 10))), macs: [studio])
    await model.run()
    XCTAssertEqual(model.state, .expired)
  }

  func testTooManyCodesSaysToWait() async throws {
    let (model, _) = try await make(Issuer(result: .failure(.httpStatus(429))), macs: [studio])
    await model.run()
    guard case .failed(let message) = model.state else { return XCTFail("\(model.state)") }
    XCTAssertTrue(message.contains("Try again in a minute"), message)
  }
}
