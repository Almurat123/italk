import SwiftUI

/// Motion playground for the companion rig: the exact renderer used in production, with live control of gaze, eye shapes,
/// body actions, springs, speed, palette and (simulated, labelled) audio levels, plus a scripted end-to-end sequence.
struct CompanionPlayground: View {
    @State private var controller = CompanionRigController()
    @State private var mode = RigMode.idle
    @State private var emotion = RigEmotion.neutral
    @State private var followEmotion = true
    @State private var leftEye = RigEyeShape.normal
    @State private var rightEye = RigEyeShape.normal
    @State private var sweep = false
    @State private var manualGaze: CGPoint?
    @State private var amplitude = 1.0
    @State private var response = 0.42
    @State private var damping = 0.55
    @State private var speed = 1.0
    @State private var hue = 0.0
    @State private var glow = 1.0
    @State private var simulatedAudio = false
    @State private var audioLevel = 0.4
    @State private var sequence: Task<Void, Never>?
    @State private var sequenceLabel = ""

    init() {
        let c = CompanionRigController()
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-rigSweep") { c.autoGazeSweep = true }
        _controller = State(initialValue: c)
        _sweep = State(initialValue: args.contains("-rigSweep"))
        if let i = args.firstIndex(of: "-rigMode"), i + 1 < args.count, let m = RigMode(rawValue: args[i + 1]) { _mode = State(initialValue: m) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                CompanionRigSurface(controller: controller)
                    .frame(maxWidth: .infinity).frame(height: 330)
                    .accessibilityLabel("iTalk 角色").accessibilityIdentifier("rig.view")
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title + " · " + emotion.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if !sequenceLabel.isEmpty { Text(sequenceLabel).font(.caption2).foregroundStyle(.tertiary) }
                    if simulatedAudio { Label("模拟音量", systemImage: "testtube.2").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
                }.padding(12)
            }
            .background(Color(uiColor: .systemBackground))
            Divider()
            ScrollView { controls.padding(16) }
        }
        .navigationTitle("角色动作").navigationBarTitleDisplayMode(.inline)
        .onAppear { push(); if ProcessInfo.processInfo.arguments.contains("-rigSequence") { playSequence() } }
        .onDisappear { sequence?.cancel() }
        .task(id: simulatedAudio) {
            // Simulated audio drives listening/speaking only when switched on (labelled above). Production uses real levels.
            while simulatedAudio, !Task.isCancelled {
                let t = Date.now.timeIntervalSinceReferenceDate
                let syllables = max(0, sin(t * 11) * 0.5 + sin(t * 4.3) * 0.35 + 0.25)
                controller.inputLevel = audioLevel * syllables
                controller.outputLevel = audioLevel * syllables
                try? await Task.sleep(for: .milliseconds(33))
            }
            controller.inputLevel = 0; controller.outputLevel = 0
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button { playSequence() } label: { Label("播放完整演示", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("rig.sequence")
                Button { sequence?.cancel(); sequenceLabel = ""; mode = .idle; emotion = .neutral; push() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.bordered)
            }
            group("状态") {
                chips(RigMode.allCases, selection: $mode, title: \.title)
            }
            group("情绪") {
                chips(RigEmotion.allCases, selection: $emotion, title: \.title)
            }
            group("眼睛") {
                Toggle("跟随情绪", isOn: $followEmotion)
                if !followEmotion {
                    Text("左眼").font(.caption).foregroundStyle(.secondary)
                    chips(RigEyeShape.allCases, selection: $leftEye, title: \.title)
                    Text("右眼").font(.caption).foregroundStyle(.secondary)
                    chips(RigEyeShape.allCases, selection: $rightEye, title: \.title)
                }
            }
            group("视线") {
                Toggle("360° 连续扫视", isOn: $sweep)
                GazePad(gaze: $manualGaze).frame(height: 150)
                Button("交给角色自己看") { manualGaze = nil }.font(.footnote)
            }
            group("动作") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76))], spacing: 8) {
                    ForEach(RigAction.allCases) { a in
                        Button(a.title) { controller.perform(a) }.buttonStyle(.bordered).accessibilityIdentifier("rig.action.\(a.rawValue)")
                    }
                }
            }
            group("参数") {
                slider("动作幅度", $amplitude, 0...2)
                slider("弹簧响应（秒）", $response, 0.15...1.0)
                slider("阻尼", $damping, 0.15...1.2)
                slider("速度", $speed, 0.25...2)
                slider("色相", $hue, -0.5...0.5)
                slider("情绪光晕", $glow, 0...1.5)
            }
            group("音频（模拟）") {
                Toggle("模拟说话/收音", isOn: $simulatedAudio)
                slider("音量", $audioLevel, 0...1)
            }
        }
        .onChange(of: mode) { _, _ in push() }
        .onChange(of: emotion) { _, _ in push() }
        .onChange(of: followEmotion) { _, _ in push() }
        .onChange(of: leftEye) { _, _ in push() }
        .onChange(of: rightEye) { _, _ in push() }
        .onChange(of: sweep) { _, _ in push() }
        .onChange(of: manualGaze) { _, _ in push() }
        .onChange(of: amplitude) { _, _ in push() }
        .onChange(of: response) { _, _ in push() }
        .onChange(of: damping) { _, _ in push() }
        .onChange(of: speed) { _, _ in push() }
        .onChange(of: hue) { _, _ in push() }
        .onChange(of: glow) { _, _ in push() }
    }

    private func push() {
        controller.mode = mode; controller.emotion = emotion
        controller.eyeOverride = followEmotion ? nil : (leftEye, rightEye)
        controller.autoGazeSweep = sweep; controller.gazeOverride = manualGaze
        controller.amplitude = amplitude; controller.springResponse = response; controller.springDamping = damping
        controller.speed = speed; controller.hueShift = hue; controller.glow = glow
    }

    /// idle → notice → listen → think → tool → speak → interrupted → listen → finish, with real-looking (simulated) audio.
    private func playSequence() {
        sequence?.cancel()
        sequence = Task { @MainActor in
            let steps: [(RigMode, RigEmotion, Double, String, Bool)] = [
                (.idle, .neutral, 2.5, "待机：四处看看、呼吸、眨眼", false),
                (.attentive, .neutral, 1.4, "注意到你", false),
                (.listening, .neutral, 3.2, "在听（模拟音量）", true),
                (.thinking, .neutral, 2.8, "思考", false),
                (.working, .focused, 2.6, "使用工具", false),
                (.speaking, .happy, 3.4, "说话（模拟音量）", true),
                (.interrupted, .surprised, 1.2, "被打断", false),
                (.listening, .curious, 2.4, "再次倾听（模拟音量）", true),
                (.success, .neutral, 2.0, "完成", false),
                (.idle, .happy, 2.0, "回到待机", false),
            ]
            for (m, e, seconds, label, audio) in steps {
                guard !Task.isCancelled else { return }
                mode = m; emotion = e; sequenceLabel = label; simulatedAudio = audio; push()
                try? await Task.sleep(for: .seconds(seconds))
            }
            simulatedAudio = false; sequenceLabel = ""
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }
    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.footnote).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40)
        }
    }
    private func chips<T: Hashable & Identifiable>(_ items: [T], selection: Binding<T>, title: KeyPath<T, String>) -> some View {
        GenUIFlow(spacing: 6) {
            ForEach(items) { item in
                let on = selection.wrappedValue == item
                Button { selection.wrappedValue = item } label: {
                    Text(item[keyPath: title]).font(.footnote.weight(on ? .semibold : .regular))
                        .padding(.horizontal, 10).frame(minHeight: 30)
                        .foregroundStyle(on ? Color.white : .primary)
                        .background(on ? Color.accentColor : MarkdownStyle.surface, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
    }
}

/// Drag anywhere in the pad to aim the gaze (unit disk). Lets downward and diagonal looks be held as long as needed.
private struct GazePad: View {
    @Binding var gaze: CGPoint?
    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2 - 8
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle().strokeBorder(MarkdownStyle.hairline, lineWidth: 1).frame(width: r * 2, height: r * 2).position(c)
                Path { p in p.move(to: CGPoint(x: c.x - r, y: c.y)); p.addLine(to: CGPoint(x: c.x + r, y: c.y)); p.move(to: CGPoint(x: c.x, y: c.y - r)); p.addLine(to: CGPoint(x: c.x, y: c.y + r)) }
                    .stroke(MarkdownStyle.hairline, lineWidth: 0.5)
                Circle().fill(gaze == nil ? Color.secondary : Color.accentColor).frame(width: 18, height: 18)
                    .position(x: c.x + (gaze?.x ?? 0) * r, y: c.y + (gaze?.y ?? 0) * r)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                var x = (v.location.x - c.x) / r, y = (v.location.y - c.y) / r
                let m = sqrt(x * x + y * y); if m > 1 { x /= m; y /= m }
                gaze = CGPoint(x: x, y: y)
            })
        }
        .accessibilityLabel("视线控制")
    }
}
