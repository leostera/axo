import AxoMascotVector
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
    .privacySensitive(false)
    .unredacted() // Public artwork stays visible in placeholders/Always On; no account data.
  }

  private var mark: some View {
    // Native paths from the Rive source, in the default (normally white) foreground group.
    // Do not opt the mascot into the watch face’s personal accent color.
    AxoMascotMark().fill(.primary)
      .padding(3)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .widgetAccentable(false)
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
