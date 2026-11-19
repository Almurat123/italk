import ActivityKit
import WidgetKit
import SwiftUI

/// The iTalk character in miniature: blue-and-white orb with two eyes. Widgets cannot run the full animation system,
/// so the phase is expressed by eye shape, a tint ring and (for live phases) a gentle pulse.
private struct PhaseOrb: View {
    let phase: AgentActivityAttributes.ContentState.Phase
    var size: CGFloat = 34

    private var tint: Color {
        switch phase {
        case .waitingForYou: .orange; case .failed: .red; case .done: .green; case .paused: .gray; default: Color(red: 0.12, green: 0.5, blue: 1)
        }
    }
    private var live: Bool { phase == .listening || phase == .speaking || phase == .thinking || phase == .working }

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [.white, Color(red: 0.55, green: 0.78, blue: 1), tint], center: .init(x: 0.35, y: 0.3), startRadius: 1, endRadius: size))
            HStack(spacing: size * 0.14) {
                ForEach(0..<2, id: \.self) { _ in
                    Capsule().fill(.white).frame(width: size * 0.13, height: phase == .paused ? size * 0.05 : size * (phase == .thinking ? 0.13 : 0.22))
                }
            }.offset(y: phase == .thinking ? -size * 0.06 : 0)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1.5))
        .symbolEffect(.pulse, isActive: live)
    }
}

/// Lock Screen and Dynamic Island presentation of the voice session / agent task.
/// The state contract is `AgentActivityAttributes`; this file only draws it.
struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            HStack(spacing: 12) {
                PhaseOrb(phase: context.state.phase, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.phase.label).font(.headline)
                    Text(context.state.detail.isEmpty ? context.attributes.title : context.state.detail)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let p = context.state.progress { ProgressView(value: p).frame(width: 60) }
                else if context.state.phase != .done && context.state.phase != .failed {
                    Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
            }
            .padding()
            .widgetURL(URL(string: "italk://open"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { PhaseOrb(phase: context.state.phase, size: 36).padding(.leading, 4) }
                DynamicIslandExpandedRegion(.center) { Text(context.state.phase.label).font(.headline) }
                DynamicIslandExpandedRegion(.trailing) {
                    if let p = context.state.progress { Text(p, format: .percent.precision(.fractionLength(0))).font(.footnote.monospacedDigit()) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.detail.isEmpty { Text(context.state.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                    if let p = context.state.progress { ProgressView(value: p) }
                }
            } compactLeading: {
                PhaseOrb(phase: context.state.phase, size: 22)
            } compactTrailing: {
                Image(systemName: context.state.phase.symbol).font(.caption2.weight(.semibold))
            } minimal: {
                PhaseOrb(phase: context.state.phase, size: 22)
            }
            .widgetURL(URL(string: "italk://open"))
        }
    }
}

#if canImport(AlarmKit)
import AlarmKit

/// Same name and shape as the metadata AppleSkills attaches to its alarms (AlarmKit matches the attributes by type name).
struct ITalkAlarmMetadata: AlarmMetadata { var label: String }

/// AlarmKit presents alarms and timers through a Live Activity owned by the app's widget extension.
struct ITalkAlarmActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<ITalkAlarmMetadata>.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "alarm.fill").font(.title2).foregroundStyle(.orange)
                Text(context.attributes.metadata?.label ?? "闹钟").font(.headline)
                Spacer()
                switch context.state.mode {
                case .countdown(let c): Text(timerInterval: Date.now...c.fireDate, countsDown: true).font(.title3.monospacedDigit())
                case .paused: Image(systemName: "pause.fill")
                default: EmptyView()
                }
            }.padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "alarm.fill").foregroundStyle(.orange) }
                DynamicIslandExpandedRegion(.center) { Text(context.attributes.metadata?.label ?? "闹钟") }
            } compactLeading: { Image(systemName: "alarm.fill") } compactTrailing: { EmptyView() } minimal: { Image(systemName: "alarm.fill") }
        }
    }
}
#endif
