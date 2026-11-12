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

  var body: some View {
    Group {
      if family == .accessoryCorner { mark.widgetLabel { Text("Axo") } }
      else { mark }
    }
    .containerBackground(for: .widget) { Color.clear }
    .accessibilityLabel("Open Axo")
  }

  private var mark: some View {
    // Outlines, rather than the filled face: template tinting must preserve the eyes and mouth.
    Image("AxoMark").resizable().renderingMode(.template).scaledToFit()
      .padding(3).foregroundStyle(.primary).widgetAccentable()
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
