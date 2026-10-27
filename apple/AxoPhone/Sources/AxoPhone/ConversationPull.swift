import AxoPhoneModel
import SwiftUI

/// The conversation's pull-to-refresh, shared by the screen (which feeds it scroll positions)
/// and the Axo that plays it. A reference, so the pull redraws only the Axo, not the transcript.
@MainActor
@Observable
final class ConversationPull {
  var state = PullToRefresh()
  /// A finger is on the scroll view; set from its scroll phase.
  @ObservationIgnored var touching = false
  /// The last time a pull was let go: how far it had got, and whether it was drawn all the way
  /// (which refreshes). Axo is thrown up by it.
  private(set) var letGo = LetGo(travel: 0, drawn: false, count: 0)

  struct LetGo: Equatable {
    /// How far the finger had travelled, as a fraction of the screen.
    var travel: Double
    var drawn: Bool
    var count: Int
  }

  /// The finger lifted: refreshes if drawn all the way; either way Axo is thrown.
  func release(refresh: () -> Void) {
    let travel = state.travel
    let drawn = state.released()
    if drawn { refresh() }
    guard drawn || travel > 0.01 else { return }
    letGo = LetGo(travel: travel, drawn: drawn, count: letGo.count + 1)
  }
}

/// The Axo in the middle of an empty chat, as the pull plays it. It is squished as it is drawn,
/// and squeezes its eyes >_< once drawn all the way. Let go, it is thrown straight up and gravity
/// does the rest (`MascotFlight`). Short of drawn it hops ^_^, higher the further it was pulled,
/// and lands with a tiny squish. Drawn, it is slung clean off the top, spinning and screaming,
/// and once the refresh is over it fades back in where it sits.
struct SlingMascotView: View {
  let pull: ConversationPull
  @StateObject private var mascot = Mascot()
  /// The throw under way and when it left.
  @State private var flight: MascotFlight?
  @State private var thrownAt: Date = .distantPast
  /// Slung off the screen and not back yet.
  @State private var away = false
  @State private var shown = true
  /// The squish of landing: a blink of a moment, then back to its size.
  @State private var landed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Above this it is out of sight, past the top of the screen.
  private static let outOfSight = 900.0

  private var phase: PullToRefresh.Phase { pull.state.phase }

  /// How far it is drawn, while it is sitting there.
  private var tension: Double {
    guard !reduceMotion, flight == nil, !away, phase != .refreshing else { return 0 }
    return pull.state.progress
  }

  var body: some View {
    TimelineView(.animation(paused: flight == nil)) { context in
      let t = context.date.timeIntervalSince(thrownAt)
      AxoMascotView(mascot: mascot, rubbable: false)
        .scaleEffect(x: 1 + 0.14 * tension, y: 1 - 0.22 * tension, anchor: .bottom)
        .scaleEffect(x: landed ? 1.06 : 1, y: landed ? 0.92 : 1, anchor: .bottom)
        .offset(y: 10 * tension)
        .animation(.interactiveSpring, value: tension)
        .rotationEffect(.degrees(flight?.angle(after: t) ?? 0))
        .offset(y: -(flight?.height(after: t) ?? 0))
    }
    .opacity(shown && !away ? 1 : 0)
    .onChange(of: phase) { old, new in react(from: old, to: new) }
    .onChange(of: pull.letGo) { _, letGo in throwUp(letGo) }
    .sensoryFeedback(.impact(weight: .light), trigger: phase) { _, new in new == .armed }
  }

  private func throwUp(_ letGo: ConversationPull.LetGo) {
    guard !reduceMotion else { return }
    let flight = MascotFlight.released(travel: letGo.travel, drawn: letGo.drawn)
    // A hop is fun ^_^; being slung off the screen is not.
    mascot.react(letGo.drawn ? .scream : .happy)
    let start = Date.now
    self.flight = flight
    thrownAt = start
    Task {
      if letGo.drawn, let gone = flight.time(toPass: Self.outOfSight) {
        // Out of sight: it stays away until the refresh is over.
        try? await Task.sleep(for: .seconds(gone))
        guard thrownAt == start else { return }
        away = true
      } else {
        try? await Task.sleep(for: .seconds(flight.duration))
        guard thrownAt == start else { return }
        self.flight = nil
        // Touching down: squish for a couple of frames, then back, no rebound.
        withAnimation(.linear(duration: 0.035)) { landed = true }
        try? await Task.sleep(for: .milliseconds(35))
        withAnimation(.easeOut(duration: 0.09)) { landed = false }
        return
      }
      if thrownAt == start { self.flight = nil }
    }
  }

  private func react(from old: PullToRefresh.Phase, to new: PullToRefresh.Phase) {
    switch new {
    case .pulling, .refreshing:
      mascot.setSqueezed(false)
    case .armed:
      mascot.setSqueezed(true)
    case .idle:
      mascot.setSqueezed(false)
      guard old == .refreshing else { return }
      Task {
        // Still on its way out when a quick refresh ends: let it go first.
        while flight != nil && !away { try? await Task.sleep(for: .milliseconds(50)) }
        guard away else {
          mascot.react(.happy)
          return
        }
        // Back where it sits, unseen, smiling already (not still screaming), then it fades in.
        shown = false
        away = false
        mascot.react(.happy)
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.easeOut(duration: 0.35)) { shown = true }
      }
    }
  }
}

/// A small Axo at the top of a chat with messages, as the pull plays it: it winds round as the
/// chat is drawn down, spins while the refresh runs, then settles ^_^ and goes.
struct SpinningPullMascotView: View {
  let pull: ConversationPull
  @StateObject private var mascot = Mascot()
  /// When the refresh started: it spins from then.
  @State private var spinningSince: Date?
  /// Where it came to rest when the refresh ended.
  @State private var settledAngle: Double?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let turnsPerSecond = 1.2

  private var phase: PullToRefresh.Phase { pull.state.phase }
  /// How much of it shows: as drawn, and all of it while it settles.
  private var reveal: Double { settledAngle != nil ? 1 : pull.state.progress }

  var body: some View {
    TimelineView(.animation(paused: spinningSince == nil)) { context in
      AxoMascotView(mascot: mascot, rubbable: false)
        .frame(height: 30)
        .padding(9)
        .background(.ultraThinMaterial, in: Circle())
        .overlay(Circle().stroke(ChatColors.border, lineWidth: 0.5))
        .rotationEffect(.degrees(reduceMotion ? 0 : angle(at: context.date)))
    }
    .scaleEffect(0.5 + 0.5 * min(reveal * 1.4, 1))
    .opacity(min(reveal * 2, 1))
    .padding(.top, 10)
    .allowsHitTesting(false)
    .onChange(of: phase) { old, new in react(from: old, to: new) }
    .sensoryFeedback(.impact(weight: .light), trigger: phase) { _, new in new == .armed }
    .accessibilityHidden(phase != .refreshing)
    .accessibilityLabel("Refreshing")
  }

  private func angle(at date: Date) -> Double {
    if let settledAngle { return settledAngle }
    // A full turn once drawn; then on round from there.
    guard let spinningSince else { return pull.state.progress * 360 }
    return 360 + date.timeIntervalSince(spinningSince) * Self.turnsPerSecond * 360
  }

  private func react(from old: PullToRefresh.Phase, to new: PullToRefresh.Phase) {
    switch new {
    case .refreshing:
      spinningSince = .now
    case .idle where old == .refreshing:
      // Settle on the next full turn, smile, then go.
      let now = angle(at: .now)
      spinningSince = nil
      settledAngle = now
      withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { settledAngle = (now / 360).rounded(.up) * 360 }
      mascot.react(.happy)
      Task {
        try? await Task.sleep(for: .milliseconds(900))
        // The same pose as a whole number of turns, so it does not unwind as it goes.
        settledAngle = 0
        withAnimation(.easeOut(duration: 0.25)) { settledAngle = nil }
      }
    default:
      break
    }
  }
}
