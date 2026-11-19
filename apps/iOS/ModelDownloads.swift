import SwiftUI
import AgentRuntime

/// One download/installed control for every downloadable resource (language models, voice base, voice packs).
/// State comes from ModelCenter; the view never starts anything the center does not offer.
struct ModelDownloadControl: View {
    let entry: ModelEntry
    @Environment(ModelCenter.self) private var center
    @State private var confirmDelete = false
    @State private var confirmDownload = false

    private func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    var body: some View {
        if entry.kind == .voicePack {
            Label("包含在语音引擎中", systemImage: "waveform")
                .font(.footnote).foregroundStyle(.secondary)
        } else { switch entry.state {
        case .notInstalled:
            action("下载 · \(size(entry.totalBytes))", "arrow.down.circle") { center.download(entry.id) }
        case .partial(let done):
            action("继续 · 已有 \(size(done))", "arrow.down.circle") { center.download(entry.id) }
        case .queued:
            Label("排队中", systemImage: "clock").font(.footnote).foregroundStyle(.secondary)
        case .downloading(let p):
            progress(p, paused: false)
        case .paused(let p):
            progress(p, paused: true)
        case .verifying:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("正在验证").font(.footnote).foregroundStyle(.secondary) }
        case .installed, .loading, .loaded:
            HStack {
                Label(entry.isActive ? "使用中" : "已下载", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash").font(.footnote) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(entry.busyReason != nil)
                    .accessibilityIdentifier("model.delete.\(entry.id)")
            }
            .confirmationDialog(entry.isActive ? "「\(entry.name)」正在使用，删除后需要重新下载才能使用。" : "删除「\(entry.name)」？释放 \(size(entry.totalBytes))。",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { center.delete(entry.id) }
            }
        case .updateAvailable:
            HStack {
                action("更新", "arrow.triangle.2.circlepath") { center.download(entry.id) }
                Spacer()
                Button("删除", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.bordered).controlSize(.small).disabled(entry.busyReason != nil)
            }
            .confirmationDialog("删除「\(entry.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { center.delete(entry.id) }
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 4) {
                Text(why).font(.caption).foregroundStyle(.orange).lineLimit(2)
                action("重试", "arrow.clockwise") { center.download(entry.id) }
            }
        } }
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button { confirmDownload = true } label: { Label(title, systemImage: symbol).font(.footnote) }.buttonStyle(.bordered).controlSize(.small)
            .disabled(entry.busyReason != nil).accessibilityIdentifier("model.download.\(entry.id)")
            .confirmationDialog("确认\(title)？", isPresented: $confirmDownload, titleVisibility: .visible) {
                Button("继续") { run() }
            } message: { Text("资源：\(entry.name)") }
    }

    private func progress(_ p: DownloadProgress, paused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: p.fraction)
            HStack {
                Text("\(size(p.bytesDone)) / \(size(p.bytesTotal))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if paused { Text("已暂停").font(.caption).foregroundStyle(.secondary) }
                else if let speed = p.bytesPerSecond, speed > 0 {
                    Text(size(Int64(speed)) + "/s" + (p.secondsRemaining.map { " · " + DownloadProgressRow.eta($0) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(paused ? "继续" : "暂停") { paused ? center.resume(entry.id) : center.pause(entry.id) }
                    .font(.footnote).buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}

/// Voice and model downloads in one list, with delete for what is installed.
struct DownloadsListView: View {
    let title: String
    let entries: [ModelEntry]
    @Environment(ModelCenter.self) private var center

    var body: some View {
        List {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text(entry.subtitle).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    ModelDownloadControl(entry: entry)
                    if let why = entry.busyReason { Text(why).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task { await center.refresh() }
    }
}
