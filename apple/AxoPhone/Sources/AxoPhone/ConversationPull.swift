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

/// The Axo in the middle of an empty chat, as the pull plays it: it gets nervous as it is drawn
/// (trembles, squashes, flutters, squeezes >_< when drawn all the way), is slung off the top of
/// the screen when let go, and springs back in ^_^ when the refresh is over.
struct SlingMascotView: View {
  let pull: ConversationPull
  @StateObject private var mascot = Mascot()
  @State private var slung = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var phase: PullToRefresh.Phase { pull.state.phase }

  /// How far it is drawn, while it is still here.
  private var tension: Double {
    guard !reduceMotion, !slung, phase != .refreshing else { return 0 }
    return pull.state.progress
  }

  var body: some View {
    TimelineView(.animation(paused: tension < 0.3)) { context in
      AxoMascotView(mascot: mascot, rubbable: false)
        .scaleEffect(x: 1 + 0.08 * tension, y: 1 - 0.12 * tension, anchor: .bottom)
        .offset(x: tremble(at: context.date), y: 14 * tension)
    }
    .rotationEffect(.degrees(slung ? -540 : 0))
    .offset(y: slung ? -900 : 0)
    .onChange(of: phase) { old, new in react(from: old, to: new) }
    .sensoryFeedback(.impact(weight: .light), trigger: phase) { _, new in new == .armed }
  }

  /// Shaking more the further it is drawn.
  private func tremble(at date: Date) -> CGFloat {
    guard tension >= 0.3 else { return 0 }
    return sin(date.timeIntervalSinceReferenceDate * 70) * 2.5 * tension
  }

  private func react(from old: PullToRefresh.Phase, to new: PullToRefresh.Phase) {
    switch new {
    case .pulling:
      if old == .idle { mascot.setLoading(true) }
    case .armed:
      mascot.react(.annoyed)
    case .refreshing:
      mascot.setLoading(false)
      guard !reduceMotion else { return }
      withAnimation(.easeIn(duration: 0.3)) { slung = true }
    case .idle:
      mascot.setLoading(false)
      guard old == .refreshing else { return }
      if slung {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.55)) { slung = false }
        Task {
          try? await Task.sleep(for: .milliseconds(350))
          mascot.react(.happy)
        }
      } else {
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
