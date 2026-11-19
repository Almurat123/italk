import SwiftUI
import AgentRuntime

/// Personal memory manager over MemoryCenter. Items, switches and the undo chip all come from the center.
struct MemoryManagerView: View {
    @Environment(MemoryCenter.self) private var center
    @State private var query = ""
    @State private var adding = false
    @State private var editing: MemoryItem?
    @State private var confirmClear = false

    private var items: [MemoryItem] { query.isEmpty ? center.items : center.search(query) }

    var body: some View {
        List {
            Section {
                Toggle("记忆", isOn: Binding(get: { center.settings.enabled }, set: { v in Task { await center.setEnabled(v) } }))
                if center.settings.enabled {
                    Toggle("参考聊天记录", isOn: Binding(get: { center.settings.referenceChatHistory }, set: { v in Task { await center.setReferenceChatHistory(v) } }))
                    Toggle("自动学习", isOn: Binding(get: { center.settings.learnAutomatically }, set: { v in Task { await center.setLearnAutomatically(v) } }))
                }
            } footer: { Text("记忆保存在本机。可以随时修改、删除或关闭。") }

            if let notice = center.notice {
                Section {
                    HStack {
                        Text(notice.text).font(.footnote).lineLimit(2)
                        Spacer()
                        Button("撤销") { Task { await center.undo(notice) } }.buttonStyle(.bordered).controlSize(.small)
                        Button { center.dismissNotice() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(items) { item in
                    Button { editing = item } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if item.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary) }
                                Text(item.text).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            }
                            Text(Self.caption(item)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("删除", role: .destructive) { Task { await center.delete(item.id) } } }
                    .swipeActions(edge: .leading) {
                        Button(item.pinned ? "取消置顶" : "置顶") { Task { try? await center.update(item.id, pinned: !item.pinned) } }.tint(.orange)
                    }
                }
                if items.isEmpty {
                    Text(query.isEmpty ? "还没有记忆。" : "没有匹配的记忆。").foregroundStyle(.secondary)
                }
            } header: { Text("已记住 \(center.items.count) 条") }

            Section {
                LabeledContent("个人记忆", value: "仅本机")
                LabeledContent("对话记录", value: "仅本机")
                LabeledContent("iCloud 同步", value: "暂未开放")
            } header: { Text("数据位置") } footer: {
                Text("记忆是 iTalk 记住的关于你的信息；对话记录是聊天内容，两者分开保存和删除。同步功能开放后，这里会显示同步状态和错误。")
            }
            if !center.items.isEmpty {
                Section { Button("清除全部记忆", role: .destructive) { confirmClear = true } }
            }
        }
        .searchable(text: $query, prompt: "搜索记忆")
        .navigationTitle("记忆").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("添加记忆") } }
        .sheet(isPresented: $adding) { MemoryEditSheet(item: nil) }
        .sheet(item: $editing) { MemoryEditSheet(item: $0) }
        .confirmationDialog("清除所有记忆？此操作无法撤销。", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除全部", role: .destructive) { Task { await center.deleteAll() } }
        }
    }

    static func caption(_ item: MemoryItem) -> String {
        let source: String
        switch item.source { case .user: source = "你添加"; case .agent: source = "iTalk 记住"; case .conversation: source = "来自对话" }
        return "\(item.kind.title) · \(source)" + (item.sensitive ? " · 敏感" : "")
    }
}

private struct MemoryEditSheet: View {
    let item: MemoryItem?
    @Environment(MemoryCenter.self) private var center
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var kind = MemoryKind.fact
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("记忆内容", text: $text, axis: .vertical).lineLimit(3...8)
                Picker("类型", selection: $kind) { ForEach(MemoryKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
            .navigationTitle(item == nil ? "添加记忆" : "编辑记忆").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if let item { text = item.text; kind = item.kind } }
        }.presentationDetents([.medium])
    }

    private func save() async {
        do {
            if let item { try await center.update(item.id, text: text, kind: kind, expectedRevision: item.revision) }
            else { try await center.add(text, kind: kind) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
