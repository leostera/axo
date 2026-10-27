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
}

/// The Axo in the middle of an empty chat, as the pull plays it: it is squished as it is drawn
/// (and squeezes its eyes >_< once drawn all the way), is slung off the top of the screen when
/// let go, and drops straight back into place ^_^ when the refresh is over.
struct SlingMascotView: View {
  let pull: ConversationPull
  @StateObject private var mascot = Mascot()
  /// Off the top of the screen.
  @State private var slung = false
  /// Its turn as it is slung; only on the way up.
  @State private var spin: Double = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var phase: PullToRefresh.Phase { pull.state.phase }

  /// How far it is drawn, while it is still here.
  private var tension: Double {
    guard !reduceMotion, !slung, phase != .refreshing else { return 0 }
    return pull.state.progress
  }

  var body: some View {
    AxoMascotView(mascot: mascot, rubbable: false)
      .scaleEffect(x: 1 + 0.14 * tension, y: 1 - 0.22 * tension, anchor: .bottom)
      .offset(y: 10 * tension)
      .animation(.interactiveSpring, value: tension)
      .rotationEffect(.degrees(spin))
      .offset(y: slung ? -900 : 0)
    .onChange(of: phase) { old, new in react(from: old, to: new) }
    .sensoryFeedback(.impact(weight: .light), trigger: phase) { _, new in new == .armed }
  }

  private func react(from old: PullToRefresh.Phase, to new: PullToRefresh.Phase) {
    switch new {
    case .pulling:
      mascot.setSqueezed(false)
    case .armed:
      mascot.setSqueezed(true)
    case .refreshing:
      mascot.setSqueezed(false)
      guard !reduceMotion else { return }
      withAnimation(.easeIn(duration: 0.3)) {
        slung = true
        spin = -540
      }
    case .idle:
      mascot.setSqueezed(false)
      guard old == .refreshing else { return }
      guard slung else {
        mascot.react(.happy)
        return
      }
      // Upright again while out of sight, so it falls without turning; then it just lands.
      spin = 0
      withAnimation(.easeOut(duration: 0.4)) { slung = false }
      Task {
        try? await Task.sleep(for: .milliseconds(400))
        mascot.react(.happy)
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
