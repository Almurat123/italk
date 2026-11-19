import SwiftUI
import WidgetKit

struct VoiceEntry: TimelineEntry { let date: Date }
struct VoiceTimeline: TimelineProvider {
    func placeholder(in context: Context) -> VoiceEntry { VoiceEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (VoiceEntry) -> Void) { completion(VoiceEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceEntry>) -> Void) { completion(Timeline(entries: [VoiceEntry(date: .now)], policy: .never)) }
}
struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 4) { Label("iTalk", systemImage: "mic").font(.headline); Text("点按，开始对话").font(.caption) }
            case .accessoryCorner:
                Image(systemName: "mic").widgetLabel("iTalk")
            default:
                Image(systemName: "mic").font(.title2)
            }
        }
        .widgetURL(URL(string: "italk://voice/start?source=complication"))
        .containerBackground(.background, for: .widget)
        .accessibilityLabel("打开 iTalk 语音助手")
    }
}
@main struct VoiceComplications: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.italk.watch.voice", provider: VoiceTimeline()) { _ in ComplicationView() }
            .configurationDisplayName("iTalk 对话").description("打开普通话语音助手，不在表盘显示私人信息。")
            .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular])
    }
}
