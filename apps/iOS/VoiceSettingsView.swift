import SwiftUI
import AssistantCore
import NeuralSpeech

// CONTEXT MEMORY
// Updated: 2026-10-30
// Status: inferred (simulator verified; device pending)
// Why: The old page showed "ready" next to voices that did nothing when tapped, quoted a speed number backwards ("1.41 倍" meant slower than
//      real time) and promised an automatic switch to a retired voice. Kokoro is gone: one engine, four voices.
// Debug Goal: A tap on a voice selects it (checkmark) and plays it; every state the engine can be in is shown truthfully; the download can be
//      paused, resumed and deleted; the space it takes and the space freed from the old engine are visible.
// Search Tags: voice settings select preview download pause delete storage moss speed
// Invariants:
// - Rows are always tappable. Without the engine the tap still selects the voice and the page says that preview needs the download.
// - Every number comes from NeuralVoiceCenter (bytes, speed, latency); nothing is estimated here.
// - There is no fallback voice and the page never promises one.
// Failure Modes:
// - Disabling rows when the engine is missing reproduces "tapping does nothing".
struct VoiceSettingsView: View {
    @Environment(NeuralVoiceCenter.self) private var neural
    @State private var speed = 1.0
    @State private var confirmDelete = false
    @State private var confirmDownload = false
    @State private var confirmPartialDelete = false
    @AppStorage(NeuralVoiceCenter.voiceKey) private var selectedVoice = "moss-yunshu"

    var body: some View {
        Form {
            engineSection
            voicesSection
            if neural.isInstalled { rateSection }
            storageSection
        }
        .navigationTitle("声音")
        .task {
            speed = neural.speed
            await neural.refresh()
            neural.measureSpeedIfNeeded()
        }
        .onDisappear { neural.stopPreview() }
        .confirmationDialog("删除语音引擎？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除并释放 \(size(neural.artifact?.totalBytes ?? neural.diskBytes))", role: .destructive) { neural.deleteEngine() }
        } message: { Text("删除后回答只显示文字，直到再次下载。已选的声音会保留。") }
        .confirmationDialog("下载语音引擎？", isPresented: $confirmDownload, titleVisibility: .visible) {
            Button("下载") { neural.download() }
        } message: { Text("所有设备端声音共用这一个引擎。") }
        .confirmationDialog("清除未完成的下载？", isPresented: $confirmPartialDelete, titleVisibility: .visible) {
            Button("清除", role: .destructive) { neural.clearPartialDownload() }
        }
    }

    // MARK: Engine

    private var engineSection: some View {
        Section {
            LabeledContent("引擎", value: "MOSS-TTS-Nano · 中英双语")
            switch neural.state {
            case .installed:
                HStack {
                    Label("已安装 · 占用 \(size(neural.diskBytes))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityIdentifier("voice.engine.installed")
                    Spacer()
                    Button("删除", role: .destructive) { confirmDelete = true }.disabled(neural.isSpeaking)
                }
            case .downloading(let progress):
                DownloadProgressRow(fraction: progress.fraction, done: progress.bytesDone, total: progress.bytesTotal, speed: progress.bytesPerSecond,
                                    remaining: progress.secondsRemaining, note: progress.source.map { "来源：\($0)" })
                    .accessibilityIdentifier("voice.engine.progress")
                Button("暂停", role: .cancel) { neural.cancelDownload() }.accessibilityIdentifier("voice.engine.pause")
            case .verifying:
                LabeledContent("正在验证文件") { ProgressView().controlSize(.small) }
            case .notInstalled:
                downloadButton(partial: neural.partialBytes)
            case .failed(let why):
                Text(why).font(.footnote).foregroundStyle(.red)
                downloadButton(partial: neural.partialBytes, retry: true)
            case .unavailable:
                Text("这台设备暂时不能使用设备端语音。").foregroundStyle(.secondary)
            }
        } header: { Text("语音引擎") } footer: { Text(engineFooter) }
    }

    private func downloadButton(partial: Int64, retry: Bool = false) -> some View {
        Button {
            confirmDownload = true
        } label: {
            if partial > 0 { Label("继续下载（已有 \(size(partial))）", systemImage: "arrow.down.circle") }
            else { Label("\(retry ? "重试" : "下载")语音引擎（\(size(neural.artifact?.totalBytes ?? 0))）", systemImage: "arrow.down.circle") }
        }.accessibilityIdentifier("voice.engine.download")
    }

    private var engineFooter: String {
        switch neural.state {
        case .installed:
            var parts = ["在设备上合成，下载后可离线使用，中文和英文用同一个声音。"]
            if let rtf = neural.synthesis.median {
                let times = 1 / max(rtf, 0.01)
                parts.append(String(format: "本机合成速度约为播放速度的 %.1f 倍。", times) + (rtf <= 0.85 ? "足够流畅。" : rtf <= 1 ? "接近极限，首句会稍等一下。" : "比播放慢，会先缓冲一小段再开口，长句中间可能有停顿。"))
            } else { parts.append("还没有测速；第一次朗读后会显示。") }
            if let ms = neural.firstAudioMs { parts.append(String(format: "从文字到出声约 %.1f 秒。", ms / 1000)) }
            return parts.joined(separator: " ")
        case .notInstalled, .failed:
            return "没有语音引擎时，回答只显示文字，不会换成别的声音。下载一次后可离线使用。"
        default: return "在设备上合成，下载后可离线使用。"
        }
    }

    // MARK: Voices

    private var voicesSection: some View {
        Section {
            ForEach(NeuralVoiceCenter.voices) { voice in voiceRow(voice) }
        } header: { Text("声音") } footer: {
            if case .failed(let why) = neural.preview { Text(why).foregroundStyle(.red) }
            else if !neural.isInstalled { Text("点按声音即可选中；下载语音引擎后点按就能试听。") }
            else { Text("点按声音：选中并试听中文和英文各一句。") }
        }
    }

    private func voiceRow(_ voice: VoiceOption) -> some View {
        let selected = selectedVoice == voice.id
        let preparing = neural.preview == .preparing(voice.id), playing = neural.preview == .playing(voice.id)
        return Button {
            selectedVoice = voice.id
            neural.select(voice.id)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.name).foregroundStyle(.primary)
                    Text("\(voice.note) · \(voice.gender == .male ? "男声" : "女声")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if preparing { ProgressView().controlSize(.small) }
                else if playing { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).symbolEffect(.variableColor.iterative, isActive: true) }
                else if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("voice.option.\(voice.name)")
    }

    // MARK: Rate

    private var rateSection: some View {
        Section {
            Slider(value: $speed, in: 0.85...1.2, step: 0.05) { Text("语速") } minimumValueLabel: { Text("慢") } maximumValueLabel: { Text("快") } onEditingChanged: { editing in
                if !editing { neural.speed = speed; neural.playPreview(neural.voiceID) }
            }.accessibilityIdentifier("voice.rate")
        } header: { Text("语速") } footer: { Text(String(format: "当前 %.2f 倍。", speed)) }
    }

    // MARK: Storage

    private var storageSection: some View {
        Section {
            if neural.isInstalled {
                LabeledContent("语音引擎占用", value: size(neural.diskBytes))
                Button("删除语音引擎", role: .destructive) { confirmDelete = true }
                    .disabled(neural.isSpeaking).accessibilityIdentifier("voice.engine.delete")
            } else if neural.partialBytes > 0 {
                LabeledContent("未完成的下载", value: size(neural.partialBytes))
                Button("清除未完成的下载", role: .destructive) { confirmPartialDelete = true }
                    .disabled(neural.isDownloading).accessibilityIdentifier("voice.engine.clearPartial")
            } else {
                Text("没有占用空间。").foregroundStyle(.secondary)
            }
            if let message = neural.lastError { Text(message).font(.footnote).foregroundStyle(.orange) }
            if let cleanup = neural.lastCleanup {
                Label("已清理旧版语音文件，释放 \(size(cleanup.bytes))", systemImage: "trash.circle").font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("voice.legacy.cleaned")
            }
        } header: { Text("存储") }
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
