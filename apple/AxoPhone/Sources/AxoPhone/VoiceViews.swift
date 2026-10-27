import AxoPhoneModel
import SwiftUI

/// The microphone in the empty message box, where Send goes: tap to talk.
struct VoiceButton: View {
  let voice: VoicePrompt
  let enabled: Bool

  var body: some View {
    Button { voice.start() } label: {
      Group {
        if case .requestingPermission = voice.state {
          ProgressView().tint(ChatColors.background)
        } else {
          Image(systemName: "waveform").font(.system(size: 20, weight: .medium))
        }
      }
      .foregroundStyle(enabled ? ChatColors.background : Color.secondary)
      .frame(width: 44, height: 44)
      .background(enabled ? Color.primary : ChatColors.disabledControl, in: Circle())
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled || voice.isBusy)
    .padding(.bottom, 1)
    .accessibilityLabel("Talk")
    .accessibilityHint("Say your message; stop to read it first, or send it straight away")
    .accessibilityIdentifier("voice-start")
  }
}

/// While listening, the message box becomes this: the words as they are heard, how loud, and
/// what to do with them. Cancel forgets them, Stop puts them in the box, Send sends them.
struct VoiceListeningBar: View {
  let voice: VoicePrompt
  let canSend: Bool

  private var heard: HeardText {
    if case .listening(let heard) = voice.state { heard } else { HeardText() }
  }
  private var finishing: Bool { voice.state == .finishing }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      heardText
        .padding(.horizontal, 12).padding(.top, 6)
      HStack(spacing: 10) {
        circleButton("xmark", label: "Cancel", id: "voice-cancel") { voice.cancel() }
        if finishing {
          ProgressView().frame(maxWidth: .infinity, minHeight: 34)
        } else {
          VoiceWaveform(voice: voice).frame(maxWidth: .infinity)
        }
        circleButton("stop.fill", label: "Stop", id: "voice-stop") { voice.finish(.draft) }
          .accessibilityHint("Put the words in the message box to read first")
          .disabled(finishing)
        Button { voice.finish(.send) } label: {
          Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold))
            .foregroundStyle(canSend ? ChatColors.background : Color.secondary)
            .frame(width: 44, height: 44)
            .background(canSend ? Color.primary : ChatColors.disabledControl, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend || finishing)
        .accessibilityLabel("Send")
        .accessibilityHint("Send what you said")
        .accessibilityIdentifier("voice-send")
      }
    }
    .padding(8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 27))
    .overlay(RoundedRectangle(cornerRadius: 27).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    .padding(.horizontal, 16)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voice-listening")
  }

  @ViewBuilder private var heardText: some View {
    if heard.isEmpty {
      Text(finishing ? "Finishing…" : "Listening…")
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("voice-heard")
    } else {
      (Text(heard.settled) + Text(heard.tentative).foregroundStyle(.secondary))
        .lineLimit(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("voice-heard")
    }
  }

  private func circleButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 18, weight: .medium))
        .frame(width: 44, height: 44)
        .background(ChatColors.inset, in: Circle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .accessibilityLabel(label)
    .accessibilityIdentifier(id)
  }
}

/// The microphone's loudness over the last second and a half, as bars. Only measured levels are
/// drawn; nothing is made up.
private struct VoiceWaveform: View {
  let voice: VoicePrompt
  @State private var levels = Array(repeating: 0.0, count: 30)
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: reduceMotion ? 0.2 : 0.05)) { context in
      HStack(spacing: 3) {
        ForEach(levels.indices, id: \.self) { index in
          Capsule().fill(Color.secondary)
            .frame(height: max(3, VoiceWaveformScale.heightFraction(for: levels[index]) * 30))
            .frame(maxWidth: .infinity)
        }
      }
      .frame(height: 34)
      .onChange(of: context.date) {
        levels.removeFirst()
        levels.append(voice.audioLevel)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Listening")
  }
}

/// Setting up the speech model the first time, or why voice did not work.
struct VoiceStatusCard: View {
  let voice: VoicePrompt

  var body: some View {
    switch voice.state {
    case .preparing(let progress):
      card {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 10) {
            Image(systemName: "waveform").foregroundStyle(.secondary)
            Text(title(progress)).font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            if progress.stage == .downloading {
              Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            dismissButton("Cancel") { voice.cancel() }
          }
          Text("Speech is turned into words on this iPhone; audio never leaves it.")
            .font(.caption).foregroundStyle(.secondary)
          if progress.stage == .downloading {
            ProgressView(value: progress.fraction).tint(.primary)
          } else {
            ProgressView().tint(.primary).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .accessibilityIdentifier("voice-setup")
    case .failed(let message):
      card {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "mic.slash").foregroundStyle(.orange)
          Text(message).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
          dismissButton("Dismiss") { voice.dismissFailure() }
        }
      }
      .accessibilityIdentifier("voice-failure")
    default:
      EmptyView()
    }
  }

  private func title(_ progress: VoiceSetupProgress) -> String {
    switch progress.stage {
    case .checking: "Getting voice ready…"
    case .downloading: "Downloading the speech model"
    case .finishing: "Getting voice ready…"
    }
  }

  private func card(@ViewBuilder _ content: () -> some View) -> some View {
    content()
      .padding(14)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
      .padding(.horizontal, 16)
      .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  private func dismissButton(_ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 28, height: 28)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .accessibilityLabel(label)
  }
}
