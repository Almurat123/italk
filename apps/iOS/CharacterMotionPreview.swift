import SwiftUI
import AssistantCore
import AVFoundation

struct CharacterMotionPreview: View {
    private enum Demo: String, CaseIterable {
        case idle, listening, thinking, speaking, confirming, failed
        var title: String {
            switch self {
            case .idle: "待机"
            case .listening: "倾听"
            case .thinking: "思考"
            case .speaking: "说话"
            case .confirming: "等待确认"
            case .failed: "出错"
            }
        }
        var phase: VoicePhase { VoicePhase(rawValue: rawValue) ?? .idle }
        var note: String {
            switch self {
            case .idle: "蓝白云流缓慢流动，白色眼睛偶尔眨动。"
            case .listening: "白色眼睛看向你，球内液体随声音轻轻涌动。"
            case .thinking: "目光稍稍抬起，液体在圆形内部缓慢回旋。"
            case .speaking: "眼神、轮廓和液体随表达变化，交流中会出现长方形与五角星等形状。"
            case .confirming: "抬眼等待你的决定。"
            case .failed: "眼神停下来，球内流动放缓，等待你处理。"
            }
        }
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected = Demo.idle
    @State private var emotion = VoiceEmotion.neutral
    @State private var performance: CharacterPerformance?
    @State private var autoplay = true
    @State private var previewLevel = 0.0
    @State private var speechBeat = 0
    @State private var lastPreviewBeat = -1
    @State private var playingSample = false
    @State private var error: String?
    @State private var epoch = Date.now
    @State private var tourBegan = Date.now
    @State private var speech = SpeechOutput()
    @State private var cloudPlayback = CloudSpeechPlayback()
    @State private var voiceGateway = GatewayClient()
    @State private var sampleTask: Task<Void, Never>?
    @State private var playbackRun = UUID()
    @State private var playbackLevel = 0.0
    @State private var emphasis = 0.35
    @State private var samplePreparing = false
    @State private var foreground = true
    @State private var motionEnabled = true

    var embedded = false
    @ViewBuilder private func wrapped<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if embedded { content() } else { NavigationStack { content() } }
    }

    var body: some View {
        wrapped {
            ScrollView {
                VStack(spacing: 18) {
                    Text("动作与情绪预览 · 不录音").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("character.preview.runtime").accessibilityValue(scenePhase == .active ? "active" : "inactive")
                    if ProcessInfo.processInfo.arguments.contains("-orbSizePreview") {
                        HStack(alignment: .bottom, spacing: 24) {
                            ForEach([36, 52, 80], id: \.self) { size in
                                VStack(spacing: 6) {
                                    VoiceOrbView(phase: .speaking, level: 0, emotion: emotion, isStatic: true, performanceOverride: performance)
                                        .frame(width: CGFloat(size), height: CGFloat(size))
                                    Text("\(size) pt").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    VoiceOrbView(phase: samplePreparing ? .synthesizing : selected.phase, level: previewLevel,
                                 speechBeat: speechBeat, speechLevel: playbackLevel, emotion: emotion, emphasis: emphasis, epoch: epoch, performanceOverride: performance)
                        .frame(width: 260, height: 260)
                    VStack(spacing: 8) {
                        Text((performance ?? .resolve(selected.phase, emotion)).title).font(.title3.weight(.medium))
                            .accessibilityIdentifier("character.preview.performance")
                        HStack(spacing: 12) {
                            Text(samplePreparing ? VoicePhase.synthesizing.label : selected.title).accessibilityIdentifier("character.preview.status")
                            Text(emotion.label).accessibilityIdentifier("character.preview.emotion")
                        }.font(.caption).foregroundStyle(.secondary)
                        Text((performance ?? .resolve(selected.phase, emotion)).note).font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(minHeight: 32)
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(CharacterPerformance.allCases, id: \.self) { item in
                                Button(item.title) {
                                    stopSample(); autoplay = false; performance = item
                                    selected = Demo(rawValue: item.previewPhase.rawValue) ?? .idle; emotion = item.previewEmotion
                                }.buttonStyle(.glass).controlSize(.large).accessibilityIdentifier("character.performance.\(item.rawValue)")
                            }
                        }.padding(.vertical, 4)
                    }.scrollIndicators(.hidden)
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(VoiceEmotion.allCases, id: \.self) { mood in
                                Button(mood.label) { stopSample(); autoplay = false; emotion = mood }
                                    .buttonStyle(.glass).controlSize(.large).tint(emotion == mood ? .accentColor : .primary)
                                    .accessibilityIdentifier("character.emotion.\(mood.rawValue)")
                            }
                        }.padding(.vertical, 4)
                    }.scrollIndicators(.hidden)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 12) {
                        ForEach(Demo.allCases, id: \.self) { item in
                            Button {
                                stopSample(); autoplay = false; performance = nil; selected = item
                            } label: { Text(item.title).font(.subheadline).frame(maxWidth: .infinity, minHeight: 44) }
                                .buttonStyle(.glass).tint(selected == item ? .accentColor : .primary)
                                .accessibilityIdentifier("character.preview.\(item.rawValue)")
                        }
                    }
                    Toggle("自动轮播", isOn: $autoplay).font(.subheadline)
                        .onChange(of: autoplay) { _, enabled in if enabled { stopSample(); tourBegan = .now } }
                        .accessibilityIdentifier("character.preview.autoplay")
                    Button(playingSample ? "停止播放" : "播放设备语音", systemImage: playingSample ? "stop.fill" : "speaker.wave.2") {
                        if playingSample { stopSample(); selected = .idle }
                        else { playSample() }
                    }.buttonStyle(.glass).controlSize(.large).accessibilityIdentifier("character.preview.sample")
                        .accessibilityValue("\(speechBeat)")
                    Button("播放情绪语音", systemImage: "waveform") { playCloudSample() }
                        .buttonStyle(.glass).controlSize(.large).accessibilityIdentifier("character.preview.cloudSample")
                        .disabled(playingSample || !model.grants.contains(.cloudVoice) || !model.grants.contains(.cloudAI))
                    Button("播放逐句表情示例", systemImage: "face.smiling") {
                        playSample("太好了，这个难题我们终于一起完成了！没关系，我们可以慢慢来，一步一步就好。注意风险，这项决定需要认真核实，先把事实和每一个条件检查清楚再行动。你觉得接下来我们该怎么做呢？")
                    }.buttonStyle(.glass).controlSize(.large).accessibilityIdentifier("character.preview.expressionSample")
                    Text(model.grants.contains(.cloudVoice) ? "情绪语音需配置兼容服务，成功合成后按字符用量计费。" : "尚未连接情绪语音服务。设备朗读用于检查动作节奏。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                }.padding(20).frame(maxWidth: 440).frame(maxWidth: .infinity)
            }
            .background(.background).scrollEdgeEffectStyle(.soft, for: .vertical)
            .navigationTitle("角色动作预览").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        // CONTEXT MEMORY
        // Updated: 2026-10-26
        // Status: inferred
        // Why: A long-running task captured the sheet's initial inactive environment value.
        // Debug Goal: Autoplay resumes when the presented sheet becomes active.
        // Search Tags: character preview autoplay frozen first frame scenePhase captured task
        // Invariants:
        // - Loop gates use live State storage updated by environment changes.
        // - Reduced Motion disables autoplay without hiding manual expression controls.
        // Failure Modes:
        // - Reading a captured environment copy freezes the loop after presentation.
        // - Animation continues after the app loses foreground.
        .onAppear {
            foreground = scenePhase == .active; motionEnabled = !reduceMotion
            if ProcessInfo.processInfo.arguments.contains("-orbPerformanceProbe") { autoplay = false; selected = .speaking }
            if ProcessInfo.processInfo.arguments.contains("-orbSizePreview") {
                autoplay = false; selected = .speaking; performance = .amazed; emotion = .happy
            }
        }
        .onChange(of: reduceMotion) { _, value in motionEnabled = !value }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                guard foreground else { continue }
                let elapsed = Date.now.timeIntervalSince(tourBegan)
                if autoplay && motionEnabled {
                    let item = CharacterPerformance.allCases[Int(elapsed / 2.8) % CharacterPerformance.allCases.count]
                    performance = item; emotion = item.previewEmotion
                    selected = Demo(rawValue: item.previewPhase.rawValue) ?? .idle
                }
                previewLevel = selected == .listening ? 0.35 + sin(elapsed * 4) * 0.27 : 0
                let beat = Int(elapsed / 0.30)
                if selected == .speaking && !playingSample && beat != lastPreviewBeat {
                    lastPreviewBeat = beat; speechBeat &+= 1
                }
            }
        }
        .onDisappear { stopSample() }
        .onChange(of: scenePhase) { _, phase in
            foreground = phase == .active
            if !foreground { stopSample(); selected = .idle; performance = nil }
        }
    }

    private func stopSample() {
        let wasPlaying = playingSample
        playbackRun = UUID(); sampleTask?.cancel(); sampleTask = nil; voiceGateway.cancel()
        cloudPlayback.stop(); playbackLevel = 0; samplePreparing = false
        speech.stop(); playingSample = false
        if wasPlaying { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    private func playSample(_ text: String? = nil) {
        stopSample()
        autoplay = false; performance = nil; selected = .speaking; error = nil; playingSample = true
        let run = playbackRun
        do {
            try speech.speak(text ?? sampleText, emotion: emotion, onExpression: { cue in
                guard playbackRun == run else { return }
                emotion = cue.emotion; emphasis = cue.emphasis
            }, onWord: { if playbackRun == run { speechBeat &+= 1 } }) {
                guard playbackRun == run else { return }
                playingSample = false; selected = .idle; emotion = .neutral; emphasis = 0.35
            }
        } catch { playingSample = false; selected = .failed; self.error = error.localizedDescription }
    }
    private var sampleText: String {
        switch emotion {
        case .neutral: "你好，我是 iTalk。我们可以从你想聊的事情开始。"
        case .happy: "太好了，终于完成了！这一步值得开心一下。"
        case .calm: "没关系，我们慢慢来。先停一下，一起把事情理清楚。"
        case .sad: "这个结果确实令人遗憾。我们一起想想，接下来能做些什么。"
        case .curious: "咦，这个想法很有意思。后来发生了什么？"
        case .serious: "这件事需要认真核实。我们先看事实，再决定下一步。"
        }
    }
    private func playCloudSample() {
        stopSample(); autoplay = false; performance = nil; selected = .speaking; error = nil
        playingSample = true; samplePreparing = true
        let run = playbackRun, text = sampleText, mood = emotion
        sampleTask = Task {
            do {
                let audio = try await voiceGateway.synthesize(endpoint: model.archive.preferences.endpoint, token: model.token,
                    text: text, emotion: mood, healthConsent: false)
                try Task.checkCancellation()
                guard playbackRun == run else { return }
                samplePreparing = false
                try cloudPlayback.play(audio, onLevel: { value in if playbackRun == run { playbackLevel = value } }) { success in
                    guard playbackRun == run else { return }
                    playingSample = false; selected = .idle
                    if !success { error = "语音播放中断。" }
                }
            } catch {
                guard playbackRun == run, !(error is CancellationError) else { return }
                playingSample = false; samplePreparing = false; selected = .failed; self.error = error.localizedDescription
            }
        }
    }
}
