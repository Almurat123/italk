import SwiftUI
import AssistantCore

#if DEBUG && targetEnvironment(simulator)
/// Simulator-only controllable voice state (`-voicePreview`). The simulator has no audio input, so a live voice session and a live microphone
/// level cannot exist there. This object overrides what the production views read; it is not compiled for devices and the production
/// code paths still go through the same views (VoiceSessionBar, HoldRecordingOverlay, voice screen).
@MainActor @Observable final class VoicePreview {
    static let shared = VoicePreview()
    static let enabled = ProcessInfo.processInfo.arguments.contains("-voicePreview")

    enum Session: String, CaseIterable, Identifiable {
        case off = "无会话", listening = "在听", speaking = "在说", processing = "思考", interrupted = "被打断", paused = "已暂停"
        var id: String { rawValue }
        var live: Bool { self == .listening || self == .speaking || self == .processing }
    }
    var session = Session.off
    var level = 0.0
    var sweep = false
    var recording: RecordingLightState?
    var transcript = ""

    /// Launch arguments make a state reproducible without tapping: `-vpSession listening|speaking|processing|interrupted|paused`,
    /// `-vpRecording preparing|recording|cancelling|sending|failed`, `-vpLevel 0.7`, `-vpSweep`.
    init() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? { args.firstIndex(of: key).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        switch value("-vpSession") {
        case "listening": session = .listening
        case "speaking": session = .speaking
        case "processing": session = .processing
        case "interrupted": session = .interrupted
        case "paused": session = .paused
        default: break
        }
        switch value("-vpRecording") {
        case "preparing": recording = .preparing
        case "recording": recording = .recording
        case "cancelling": recording = .cancelling
        case "sending": recording = .sending
        case "failed": recording = .failed
        default: break
        }
        if let raw = value("-vpLevel"), let v = Double(raw) { level = v }
        sweep = args.contains("-vpSweep")
    }

    var phase: VoicePhase {
        switch session { case .off: .idle; case .listening: .listening; case .speaking: .speaking; case .processing: .thinking; case .interrupted, .paused: .interrupted }
    }
    var status: (title: String, hint: String?) {
        switch session {
        case .off: ("轻点麦克风开始", nil)
        case .listening: ("在听", transcript.isEmpty ? nil : transcript)
        case .speaking: ("正在说", "直接说话可以打断")
        case .processing: ("思考中", "轻点可停止")
        case .interrupted: ("被打断", "来电或其他 App 占用了声音 · 轻点继续")
        case .paused: ("已暂停", "轻点继续")
        }
    }
}

/// Floating controls for the preview. Labelled as simulated so it can never be mistaken for product UI.
struct VoicePreviewControls: View {
    @Bindable var preview: VoicePreview
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { expanded.toggle() } } label: {
                Label("模拟（仅模拟器）", systemImage: expanded ? "chevron.down" : "testtube.2").font(.caption.bold())
            }.tint(.orange)
            if expanded {
                Picker("会话", selection: $preview.session) { ForEach(VoicePreview.Session.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu).labelsHidden()
                Picker("录音", selection: $preview.recording) {
                    Text("录音：真实").tag(RecordingLightState?.none)
                    Text("准备").tag(RecordingLightState?.some(.preparing))
                    Text("录音").tag(RecordingLightState?.some(.recording))
                    Text("取消").tag(RecordingLightState?.some(.cancelling))
                    Text("发送").tag(RecordingLightState?.some(.sending))
                    Text("失败").tag(RecordingLightState?.some(.failed))
                }.pickerStyle(.menu).labelsHidden()
                HStack { Text("音量").font(.caption2); Slider(value: $preview.level, in: 0...1) }.frame(width: 190)
                Toggle("自动扫频", isOn: $preview.sweep).font(.caption2).toggleStyle(.switch).frame(width: 190)
            }
        }
        .padding(10).frame(width: 214, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.orange.opacity(0.6)) }
        .task(id: preview.sweep) {
            guard preview.sweep else { return }
            var t = 0.0
            while !Task.isCancelled {
                // silence → whisper → normal → loud → silence, repeating every 8 s
                let phase = t.truncatingRemainder(dividingBy: 8) / 8
                let envelope = phase < 0.15 ? 0.0 : phase < 0.35 ? (phase - 0.15) / 0.2 * 0.35 : phase < 0.7 ? 0.35 + (phase - 0.35) / 0.35 * 0.6 : phase < 0.85 ? 0.95 - (phase - 0.7) / 0.15 * 0.9 : 0.05
                preview.level = max(0, min(1, envelope + 0.08 * sin(t * 9) * envelope))
                t += 0.05; try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
#endif
