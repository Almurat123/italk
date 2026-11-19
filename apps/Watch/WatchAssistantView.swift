import SwiftUI
import AssistantCore

struct WatchAssistantView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var input = ""
    @State private var settings = false
    @FocusState private var inputFocused: Bool
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label(model.session.phase.label, systemImage: "waveform").font(.headline)
                    TextField("说话或输入", text: $input)
                        .focused($inputFocused)
                        .onSubmit { let text = input; input = ""; model.submit(text, speak: true) }
                        .accessibilityLabel("使用系统听写向 iTalk 提问")
                    if !model.session.transcript.isEmpty { Text(model.session.transcript).font(.caption).foregroundStyle(.secondary) }
                    if !model.session.answer.isEmpty { Text(model.session.answer).font(.body) }
                    if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if [.thinking, .synthesizing, .speaking].contains(model.session.phase) { Button("停止") { model.cancel() } }
                    Text("系统听写 · 普通话").font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 8)
            }
            .navigationTitle("iTalk")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("设置", systemImage: "gearshape") { model.cancel(); settings = true } } }
            .sheet(isPresented: $settings) { SettingsView() }
            .onOpenURL { url in
                guard url.scheme == "italk", url.host == "voice", url.path == "/start" else { return }
                inputFocused = true
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.cancel(clear: true); inputFocused = false } }
        }.tint(.teal)
    }
}
