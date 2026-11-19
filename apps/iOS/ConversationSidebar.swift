import SwiftUI
import AssistantCore
import AgentRuntime

struct ConversationSidebar: View {
    private enum SortOrder: String, CaseIterable {
        case recent, oldest, title
        var label: String { switch self { case .recent: "最近活动"; case .oldest: "最早活动"; case .title: "名称" } }
    }
    private enum BatchAction { case pin, archive, delete }
    @Environment(AppModel.self) private var model
    @Environment(ConversationLibrary.self) private var library
    @AppStorage("italk.history.sort") private var sortValue = SortOrder.recent.rawValue
    @State private var query = ""
    @State private var hits: [ConversationSearchHit] = []
    @State private var searchRevision = 0
    @State private var showArchived = false
    @State private var renaming: Conversation?
    @State private var newTitle = ""
    @State private var selecting = false
    @State private var selection = Set<UUID>()
    @State private var managing = false
    @State private var undoBatch: [UUID] = []
    @State private var operationNote: String?
    @State private var drawerWidth: CGFloat = 320
    @FocusState private var searchFocused: Bool
    var close: () -> Void
    var newConversation: () -> Void
    var openSettings: () -> Void
    var selectConversation: (UUID) -> Void

    private var sort: SortOrder { SortOrder(rawValue: sortValue) ?? .recent }
    private var allRows: [Conversation] { library.conversations + library.archived }
    private var rows: [Conversation] { ordered(query.isEmpty ? library.conversations : hits.map(\.conversation)) }
    private var visibleRows: [Conversation] { query.isEmpty && showArchived ? rows + ordered(library.archived) : rows }
    private var visibleIDs: Set<UUID> { Set(visibleRows.map(\.id)) }
    private var selectedRows: [Conversation] { allRows.filter { selection.contains($0.id) } }
    private var allSelectedPinned: Bool { !selectedRows.isEmpty && selectedRows.allSatisfy(\.pinned) }
    private var allSelectedArchived: Bool { !selectedRows.isEmpty && selectedRows.allSatisfy(\.archived) }
    private var hasMessages: Bool { !allRows.isEmpty || !model.conversation.isEmpty }

    // CONTEXT MEMORY
    // Updated: 2026-11-01
    // Status: mixed
    // Why: Plain List section headers stick underneath the search bar; added material backgrounds made visible bands.
    // Debug Goal: Sidebar groups scroll normally beneath softly blurred fixed controls.
    // Search Tags: sidebar today sticky header footer soft blur
    // Invariants:
    // - Search/actions live in a top safeAreaBar, the account row in a bottom safeAreaBar; no opaque bar backgrounds.
    // - Group headings are ordinary list rows, not pinned section headers.
    // - Extra space above the footer extends its scroll edge while keeping the account button anchored below.
    // Failure Modes:
    // - Adding a material background to either bar creates a visible rectangular band.
    var body: some View {
        content
            .safeAreaBar(edge: .top, spacing: 0) {
                if hasMessages {
                    VStack(spacing: 0) {
                        topBar
                        if selecting { managementBar.id(selecting).transaction { $0.disablesAnimations = true } }
                    }
                }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) { footer.padding(.top, 20) }
            .background { Color(.systemBackground).ignoresSafeArea(.container, edges: .vertical) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { drawerWidth = $0 }
        .overlay(alignment: .topLeading) {
            // Visually absent (tap the scrim or swipe to close) but present for VoiceOver and automation.
            Button(action: close) { Color.clear.frame(width: 1, height: 1) }
                .accessibilityLabel("收起侧边栏").accessibilityIdentifier("history.close")
        }
        .accessibilityElement(children: .contain).accessibilityAction(.escape, close)
        .task(id: "\(query)::\(searchRevision)") {
            let key = query
            guard !key.isEmpty else { hits = []; return }
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            let found = await library.search(key)
            guard !Task.isCancelled, query == key else { return }; hits = found
        }
        .onChange(of: library.conversations) { _, _ in searchRevision &+= 1 }
        .onChange(of: library.archived) { _, _ in searchRevision &+= 1 }
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: $newTitle)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") { if let c = renaming { Task { await library.rename(c.id, to: newTitle) } }; renaming = nil }
        }
    }

    @ViewBuilder private var content: some View {
        if hasMessages {
            if !query.isEmpty && rows.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配的对话", systemImage: "magnifyingglass")
                } description: {
                    Text("试试其他关键词。")
                } actions: {
                    Button("清除搜索") { query = "" }.accessibilityIdentifier("history.clearSearch")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { messageList }
        } else {
            ContentUnavailableView {
                Label("从一句话开始", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("你的聊天会显示在这里。")
            } actions: {
                Button("开始新对话", action: newConversation).buttonStyle(.glass)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Search, new chat and list options share one row; the drawer needs no title or duplicate close button.
    private var topBar: some View {
        HStack(spacing: 10) {
            searchField
            Menu {
                Picker("排序方式", selection: $sortValue) {
                    ForEach(SortOrder.allCases, id: \.self) { order in Text(order.label).tag(order.rawValue) }
                }
                Button("选择", systemImage: "checkmark.circle") { selecting = true; selection = [] }.disabled(visibleRows.isEmpty)
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.medium)).frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
            }.accessibilityLabel("排序与选择").accessibilityValue(sort.label).accessibilityIdentifier("history.sort")
            Button(action: newConversation) {
                Image(systemName: "square.and.pencil").font(.body.weight(.medium)).frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
            }.buttonStyle(.plain).accessibilityLabel("新对话").accessibilityIdentifier("history.new")
        }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6).tint(.primary)
    }
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索对话", text: $query).font(.subheadline).autocorrectionDisabled().submitLabel(.search)
                .focused($searchFocused)
                .accessibilityIdentifier("history.search")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索").accessibilityIdentifier("history.clearSearch")
            }
        }.padding(.horizontal, 14).frame(minHeight: 42)
            .glassEffect(.regular.interactive(), in: .capsule)
    }
    private var managementBar: some View {
        HStack {
            if selecting {
                Button(visibleIDs.isSubset(of: selection) && !visibleIDs.isEmpty ? "取消全选" : "全选") {
                    if visibleIDs.isSubset(of: selection) { selection.subtract(visibleIDs) } else { selection.formUnion(visibleIDs) }
                }.disabled(visibleIDs.isEmpty).accessibilityIdentifier("history.selectAll")
                Spacer()
                Button("完成") { selecting = false; selection = [] }.accessibilityIdentifier("history.selectionDone")
            } else {
                Menu {
                    Picker("排序方式", selection: $sortValue) {
                        ForEach(SortOrder.allCases, id: \.self) { order in Text(order.label).tag(order.rawValue) }
                    }
                } label: { Label(sort.label, systemImage: "arrow.up.arrow.down") }
                    .accessibilityLabel("对话排序").accessibilityValue(sort.label).accessibilityIdentifier("history.sort")
                Spacer()
                Button("选择") { selecting = true; selection = [] }.disabled(visibleRows.isEmpty)
                    .accessibilityIdentifier("history.select")
            }
        }.font(.caption).buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
            .tint(.primary).frame(minHeight: 48).padding(.horizontal, 16).disabled(managing)
    }
    private var messageList: some View {
        List {
            if query.isEmpty && sort == .recent {
                ForEach(library.grouped(), id: \.0) { group, items in
                    Text(group.title).font(.headline).foregroundStyle(.secondary)
                        .textCase(nil).listRowSeparator(.hidden).listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
                    ForEach(items) { conversationRow($0) }
                }
            } else {
                ForEach(rows) { conversationRow($0) }
            }
            if query.isEmpty && !library.archived.isEmpty {
                Button(showArchived ? "收起已归档" : "已归档（\(library.archived.count)）") { showArchived.toggle() }
                    .font(.footnote).accessibilityIdentifier("history.archived")
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                if showArchived { ForEach(ordered(library.archived)) { conversationRow($0) } }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively).scrollEdgeEffectStyle(.soft, for: .vertical)
        .contentMargins(.bottom, 8, for: .scrollContent)
        .disabled(managing).transaction { if managing { $0.disablesAnimations = true } }
    }
    private var footer: some View {
        VStack(spacing: 8) {
            if !undoBatch.isEmpty {
                Button("已删除 \(undoBatch.count) 个对话 · 撤销", action: undoBatchDelete)
                    .font(.footnote).accessibilityIdentifier("history.undoBatchDelete")
            } else if let deleted = library.lastDeleted {
                Button("已删除「\(deleted.title)」 · 撤销") { Task { await library.undoDelete() } }
                    .font(.footnote).accessibilityIdentifier("history.undoDelete")
            }
            if let operationNote { Text(operationNote).font(.caption).foregroundStyle(.secondary) }
            if selecting {
                HStack(spacing: 0) {
                    batchButton(allSelectedPinned ? "取消置顶" : "置顶", icon: "pin", id: "history.batchPin") { performBatch(.pin) }
                    batchButton(allSelectedArchived ? "取消归档" : "归档", icon: "archivebox", id: "history.batchArchive") { performBatch(.archive) }
                    batchButton("删除", icon: "trash", id: "history.batchDelete", destructive: true) { performBatch(.delete) }
                }.disabled(selection.isEmpty || managing)
            } else {
                Button(action: openSettings) {
                    HStack(spacing: 12) {
                        BrandAvatar(size: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("我的 iTalk").font(.body.weight(.medium))
                            if !model.grants.contains(.history) { Text("历史保存已关闭").font(.caption).foregroundStyle(Color(.secondaryLabel)) }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }.frame(minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("history.settings")
            }
        }.padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 8)
    }
    private func batchButton(_ title: String, icon: String, id: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) { Image(systemName: icon).font(.body); Text(title).font(.caption2) }
                .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(destructive ? Color.red : Color.primary)
            .accessibilityLabel(title).accessibilityIdentifier(id)
    }
    private func conversationRow(_ c: Conversation) -> some View {
        Button {
            if selecting { if selection.contains(c.id) { selection.remove(c.id) } else { selection.insert(c.id) } }
            else { selectConversation(c.id) }
        } label: {
            HStack(spacing: 10) {
                if selecting {
                    Image(systemName: selection.contains(c.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(selection.contains(c.id) ? Color.accentColor : Color.secondary)
                }
                historyLabel(c)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 8).padding(.horizontal, 10)
                .background(selection.contains(c.id) || (!selecting && library.currentId == c.id) ? Color.accentColor.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
            .accessibilityIdentifier(query.isEmpty ? "history.conversation.\(c.id)" : "history.hit.\(c.id)")
            .accessibilityValue(selecting ? (selection.contains(c.id) ? "已选择" : "未选择") : "")
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
            .contextMenu {
                Button("选择", systemImage: "checkmark.circle") { selecting = true; selection = [c.id] }
                Button("重命名", systemImage: "pencil") { newTitle = c.title; renaming = c }
                Button(c.pinned ? "取消置顶" : "置顶", systemImage: c.pinned ? "pin.slash" : "pin") { Task { await library.setPinned(c.id, !c.pinned) } }
                Button(c.archived ? "取消归档" : "归档", systemImage: "archivebox") {
                    if library.currentId == c.id { model.newConversation() }
                    Task { await library.setArchived(c.id, !c.archived) }
                }
                Button("删除", systemImage: "trash", role: .destructive) {
                    if library.currentId == c.id { model.newConversation() }
                    Task { await library.delete(c.id) }
                }
            } preview: {
                // CONTEXT MEMORY
                // Updated: 2026-10-27
                // Status: inferred
                // Why: A system-lifted List row can exceed the custom drawer width.
                // Debug Goal: Keep the lifted history preview inside the sidebar.
                // Search Tags: sidebar context menu preview exceeds drawer width
                // Invariants:
                // - Preview width derives from the measured drawer, with room for system scaling.
                // - The system still owns menu actions, dismissal and accessibility.
                // Failure Modes:
                // - Reusing an unconstrained List row lifts a screen-width snapshot.
                historyLabel(c).frame(width: max(120, drawerWidth - 64), alignment: .leading).padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityElement(children: .combine).accessibilityIdentifier("history.preview")
            }
    }
    private func historyLabel(_ c: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(c.title).font(.subheadline.weight(library.currentId == c.id ? .semibold : .regular))
                    .foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                if c.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary) }
            }
            Text(c.lastActivityAt, format: .dateTime.month().day().hour().minute())
                .font(.caption2).foregroundStyle(Color(.secondaryLabel))
        }
    }
    private func ordered(_ values: [Conversation]) -> [Conversation] {
        values.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            switch sort {
            case .recent: return $0.lastActivityAt > $1.lastActivityAt
            case .oldest: return $0.lastActivityAt < $1.lastActivityAt
            case .title: return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    // CONTEXT MEMORY
    // Updated: 2026-10-26
    // Status: inferred
    // Why: History management previously required a separate long press for every conversation.
    // Debug Goal: Apply explicit selection to multiple conversations and restore the whole deleted batch.
    // Search Tags: sidebar select all batch delete archive pin undo conversations
    // Invariants:
    // - Select All affects visible filtered rows; row identity stays the conversation UUID.
    // - Deleting or archiving the current conversation cancels its run before mutation.
    // - Existing ConversationLibrary APIs own mutations; original stored messages are preserved.
    // Failure Modes:
    // - Undoing only the last item loses the rest of a deleted batch from the UI.
    // - Cancelling every run while merely opening history interrupts unrelated streaming.
    private func performBatch(_ action: BatchAction) {
        let records = selectedRows
        guard !records.isEmpty, !managing else { return }
        managing = true; operationNote = nil
        let pin = !allSelectedPinned, archive = !allSelectedArchived
        if action != .pin, let current = library.currentId, selection.contains(current) { model.newConversation() }
        Task {
            for record in records {
                switch action {
                case .pin: await library.setPinned(record.id, pin)
                case .archive: await library.setArchived(record.id, archive)
                case .delete: await library.delete(record.id)
                }
            }
            if action == .delete {
                let remaining = Set(allRows.map(\.id))
                undoBatch = records.map(\.id).filter { !remaining.contains($0) }
                if undoBatch.count != records.count { operationNote = "部分对话未能删除，请重试。" }
            }
            selection = []; selecting = false; managing = false
        }
    }
    private func undoBatchDelete() {
        guard !managing else { return }
        let ids = undoBatch
        managing = true
        Task {
            let last = library.lastDeleted?.id
            await library.undoDelete()
            for id in ids where id != last {
                try? await library.store.restore(id)
            }
            await library.refresh()
            let restored = Set(allRows.map(\.id))
            undoBatch = ids.filter { !restored.contains($0) }; managing = false
            if !undoBatch.isEmpty { operationNote = "部分对话未能恢复，请重试。" }
        }
    }
}
