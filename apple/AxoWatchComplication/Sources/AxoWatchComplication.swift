import SwiftUI
import WidgetKit

private struct MascotEntry: TimelineEntry { let date: Date }

/// A launcher, not a status indicator. No network, account data, audio, or background polling.
private struct MascotTimeline: TimelineProvider {
  func placeholder(in context: Context) -> MascotEntry { MascotEntry(date: .now) }
  func getSnapshot(in context: Context, completion: @escaping (MascotEntry) -> Void) {
    completion(MascotEntry(date: .now))
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<MascotEntry>) -> Void) {
    completion(Timeline(entries: [MascotEntry(date: .now)], policy: .never))
  }
}

private struct MascotComplicationView: View {
  @Environment(\.widgetFamily) private var family
  @Environment(\.widgetRenderingMode) private var renderingMode

  var body: some View {
    Group {
      if family == .accessoryCorner { mark.widgetLabel { Text("Axo") } }
      else { mark }
    }
    .containerBackground(for: .widget) { Color.clear }
    .accessibilityLabel("Open Axo")
    .privacySensitive(false)
    .unredacted() // Public artwork stays visible in placeholders/Always On; no account data.
  }

  private var mark: some View {
    // The real face in full color; outlines in tinted modes so the eyes/mouth do not vanish
    // into a single filled silhouette. Complications are snapshots, not live Rive animations.
    Group {
      if renderingMode == .fullColor {
        Image("AxoFace").resizable().renderingMode(.original).scaledToFit()
      } else {
        Image("AxoMark").resizable().renderingMode(.template).scaledToFit().widgetAccentable()
      }
    }
    .padding(3).foregroundStyle(.primary)
  }
}

@main
struct AxoWatchComplication: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "dev.leostera.axo.mascot", provider: MascotTimeline()) { _ in
      MascotComplicationView()
    }
    .configurationDisplayName("Axo")
    .description("A little Axo on your watch face. Tap to return to your session.")
    .supportedFamilies([.accessoryCircular, .accessoryCorner])
    .contentMarginsDisabled()
    // WidgetKit opens the containing app on tap. Never starts the microphone automatically.
  }
}
