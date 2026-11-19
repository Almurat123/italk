import SwiftUI
import PhotosUI
import ImageIO
import AssistantCore
import AgentRuntime

struct ConversationHeader: View {
    @Environment(LocalModelCenter.self) private var models
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsModelPicker = false
    var openHistory: () -> Void
    var openSettings: () -> Void
    var newConversation: () -> Void
    var toggleVoice: () -> Void
    var avatarFrameChanged: (CGRect) -> Void
    /// Scroll state; the title only fades, and the header never changes height (a changing safe-area inset makes the scroll view jump).
    var scroll: ChatScrollState? = nil
    var previewCharacter: (() -> Void)? = nil
    var body: some View {
        HStack {
            Button(action: openHistory) { Image(systemName: "sidebar.left").font(.system(size: 20)).frame(width: 44, height: 44) }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle).accessibilityLabel("展开对话侧边栏").accessibilityIdentifier("history.open")
            Spacer(minLength: 12)
            Button(action: toggleVoice) {
                let collapsed = scroll?.collapsed ?? false
                VStack(spacing: 3) {
                    // The measured anchor is static; only the glass circle (and, with the same offset and timing, the orb drawn over it by
                    // AssistantView) drops. Measuring the moved view would make the orb follow the drop a second time.
                    ZStack {
                        Color.clear.frame(width: 36, height: 36)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { avatarFrameChanged($0) }
                        Color.clear.frame(width: 36, height: 36).padding(4).glassEffect(.regular.interactive(), in: .circle)
                            .modifier(HeaderDrop(scroll: scroll))
                    }
                    // Opacity only, one short transition per threshold crossing: no layout, scale or offset change while scrolling.
                    modelTitle.opacity(collapsed ? 0 : 1)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: collapsed)
                }.contentShape(Rectangle()).foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            // CONTEXT MEMORY
            // Updated: 2026-10-30
            // Status: mixed
            // Why: The header avatar keeps tap-to-voice while long press opens the model sheet.
            // Debug Goal: A hold opens model selection without changing mode or losing the actual model name.
            // Search Tags: header long press model picker actual provider model name compact title
            // Invariants:
            // - A short tap still invokes the button action.
            // - The full header button bounds respond to a tap, including space around the avatar.
            // - A recognized hold presents the picker and leaves the current mode unchanged.
            // - Cloud titles resolve from the selected model entry, then its exact API ID.
            // - Long titles have no glass backdrop or forced empty width.
            // Failure Modes:
            // - A simultaneous tap and hold changes mode before the sheet opens.
            // - A transparent gap inside the button frame swallows a short tap.
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                showsModelPicker = true
            })
            .accessibilityLabel(currentModelName)
            .accessibilityHint("轻点切换语音与聊天，按住切换模型")
            .accessibilityAction(.default, toggleVoice)
            .accessibilityAction(named: Text("切换模型")) { showsModelPicker = true }
            .accessibilityIdentifier("assistant.mode")
            .sheet(isPresented: $showsModelPicker) {
                ConversationModelPickerView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
            }
            .onAppear {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-modelPickerPreview") {
                    showsModelPicker = true
                }
                #endif
            }
            Spacer(minLength: 12)
            Menu {
                Button("新对话", systemImage: "square.and.pencil", action: newConversation)
                Button("设置", systemImage: "gearshape", action: openSettings).accessibilityIdentifier("settings.open")
                #if DEBUG
                if let previewCharacter { Button("角色动作预览", systemImage: "face.smiling", action: previewCharacter) }
                #endif
            } label: { Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle).accessibilityLabel("更多").accessibilityIdentifier("assistant.more")
        }.tint(.primary).padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 10)
    }

    private var currentModelName: String {
        guard models.usesCloud else { return models.selected.displayName }
        if let id = models.selectedCloudId {
            if let model = models.cloudModels.first(where: { $0.id == id }) { return model.name }
            return knownCloudModelName(id) ?? id
        }
        if models.cloudModels.count == 1 { return models.cloudModels[0].name }
        return "选择云端模型"
    }

    @ViewBuilder private var modelTitle: some View {
        let title = currentModelName
        if title.count <= 14 {
            Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .glassEffect(.regular, in: .capsule)
        } else {
            Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func knownCloudModelName(_ id: String) -> String? {
        switch id.lowercased() {
        case "deepseek-flash": "DeepSeek V4.1 Flash"
        case "deepseek-v4-pro": "DeepSeek V4 Pro"
        default: nil
        }
    }
}

private struct ConversationModelPickerView: View {
    @Environment(LocalModelCenter.self) private var models
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let modelCards = ModelCenterCatalog.cards()
    private let unconfiguredCloudModel = GatewayCloudModel(
        id: "deepseek-flash", name: "DeepSeek V4.1 Flash", available: false,
        supportsImages: false, note: ""
    )

    // CONTEXT MEMORY
    // Updated: 2026-11-01
    // Status: mixed
    // Why: The managed account supplies the live entitlement and model list through LocalModelCenter.
    // Debug Goal: The chat picker and model center must reflect the same available cloud models.
    // Search Tags: deepseek model picker grey managed account models
    // Invariants:
    // - Selection uses the current managed list and account availability.
    // - Missing service data produces a disabled placeholder rather than invented availability.
    // Failure Modes:
    // - Reading the retired AppModel account keeps an enabled model grey.
    // - Replacing the managed catalog with stale legacy data desynchronizes selection.
    private var cloudModels: [GatewayCloudModel] {
        models.cloudModels.isEmpty ? [unconfiguredCloudModel] : models.cloudModels
    }

    private var switchingLocked: Bool {
        if models.localSwitchBlocked { return true }
        switch models.state {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("切换模型").font(.title3.weight(.semibold))
                Text("选择此对话使用的模型").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(models.options) { artifact in
                        localModelRow(artifact)
                    }
                    ForEach(cloudModels) { cloud in
                        cloudModelRow(cloud)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func localModelRow(_ artifact: ModelArtifact) -> some View {
        let selected = !models.usesCloud && models.selected.id == artifact.id
        let card = modelCards.first { $0.id == artifact.id }
        let capabilities = ["文本", "工具"] + ((card?.advertised.contains(.vision) == true) ? ["图片"] : [])
        return Button {
            guard selected || !switchingLocked else { return }
            if models.usesCloud { models.setUsesCloud(false) }
            models.select(artifact)
            dismiss()
        } label: {
            modelCapsule(
                name: artifact.displayName,
                capabilities: capabilities,
                price: "本地运行 · 不扣额度",
                selected: selected
            )
        }
        .buttonStyle(.plain)
        .disabled(!selected && switchingLocked)
        .accessibilityIdentifier("modelPicker.local.\(artifact.id)")
        .accessibilityLabel("\(artifact.displayName)，\(capabilities.joined(separator: "、"))，本地运行，不扣额度\(selected ? "，当前模型" : "")")
    }

    private func cloudModelRow(_ cloud: GatewayCloudModel) -> some View {
        let selected = models.usesCloud && models.selectedCloudId == cloud.id
        let capabilities = ["文本", "工具"] + (cloud.supportsImages ? ["图片"] : [])
        let price = "按用量计费"
        return Button {
            guard cloud.available, models.cloudAvailable, !switchingLocked else { return }
            models.selectCloud(cloud)
            if models.usesCloud && models.selectedCloudId == cloud.id { dismiss() }
        } label: {
            modelCapsule(
                name: cloud.name,
                capabilities: capabilities,
                price: price,
                selected: selected
            )
        }
        .buttonStyle(.plain)
        .disabled(!selected && (!cloud.available || !models.cloudAvailable || switchingLocked))
        .accessibilityIdentifier("modelPicker.cloud.\(cloud.id)")
        .accessibilityLabel("\(cloud.name)，\(capabilities.joined(separator: "、"))，\(price)\(selected ? "，当前模型" : "")")
    }

    private func modelCapsule(name: String, capabilities: [String], price: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            HStack(spacing: 6) {
                ForEach(capabilities, id: \.self) { capability in
                    Label(capability, systemImage: capabilitySymbol(capability))
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05), in: .capsule)
                }
                Spacer(minLength: 4)
                Text(price).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(selectedRowTint)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.spring(duration: 0.26, bounce: 0.05), value: selected)
    }

    private func capabilitySymbol(_ capability: String) -> String {
        switch capability {
        case "文本": "text.alignleft"
        case "工具": "wrench.and.screwdriver"
        case "图片": "photo"
        default: "checkmark"
        }
    }

    private var selectedRowTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.075) : Color.black.opacity(0.045)
    }
}

struct ConversationRow: View, Equatable {
    let turn: ConversationTurn
    var canRead = true
    var edit: (String, [ImageAttachment]) -> Void = { _, _ in }
    var read: (String) -> Void = { _ in }
    var selectionChanged: (String, Bool) -> Void = { _, _ in }
    /// Claude hook: reasoning + execution trace of this turn from AgentPlatform.traces (nil for plain chat).
    var trace: AgentTrace?
    /// Re-asks the same question (failed, stopped or finished turns). nil hides the control.
    var retry: (() -> Void)?
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.turn.id == b.turn.id && a.turn.question == b.turn.question && a.turn.answer == b.turn.answer && a.trace == b.trace
            && a.turn.state == b.turn.state && a.turn.failure == b.turn.failure
            && a.turn.images.map(\.id) == b.turn.images.map(\.id) && a.canRead == b.canRead
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(turn.images) { image in
                        AttachmentImage(attachment: image).frame(maxWidth: 230).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .accessibilityIdentifier("message.image.\(image.id)")
                            .contextMenu {
                                Button("复制图片", systemImage: "doc.on.doc") { UIPasteboard.general.image = UIImage(data: image.data) }
                                Button("编辑并重发", systemImage: "pencil") { edit(turn.question, turn.images) }
                            }
                    }
                    if !turn.question.isEmpty {
                        // ChatGPT/Codex: the person's message is a quiet neutral bubble; the answer sits on the page.
                        SelectableMessageText(text: turn.question, user: true, canRead: canRead,
                            identifier: "message.question.\(turn.id)", read: read,
                            edit: { edit($0, turn.images) }, selectionChanged: { selectionChanged("question.\(turn.id)", $0) })
                            .padding(.horizontal, 15).padding(.vertical, 10)
                            .background(UserBubbleStyle.fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
            }
            if let trace, !trace.isEmpty { AgentTraceView(trace: trace, turnId: turn.id) }
            if !turn.answer.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if MarkdownBlock.needsBlocks(turn.answer) {
                        MarkdownAnswerView(text: turn.answer, streaming: turn.state == .pending).accessibilityIdentifier("message.answer.\(turn.id)")
                    } else {
                        SelectableMessageText(text: turn.answer, user: false, canRead: canRead && turn.state != .pending,
                            identifier: "message.answer.\(turn.id)", read: read, edit: nil,
                            selectionChanged: { selectionChanged("answer.\(turn.id)", $0) })
                    }
                    if turn.state != .pending {
                        HStack(spacing: 8) {
                            AnswerActions(text: turn.answer, canRead: canRead, read: read, retry: retry)
                            Spacer(minLength: 0)
                            if !sources.isEmpty { SourcesPill(sources: sources) }
                        }
                    }
                }
            } else if turn.state == .pending, trace?.hasReasoning != true, !(trace?.steps.contains { $0.state == .running || $0.state == .awaitingApproval } ?? false) {
                // Only while the model is silently working. If it streams reasoning, tools run, or a confirmation waits,
                // the trace above already shows exactly that.
                let waitingForYou = trace?.steps.contains { $0.state == .needsPermission } ?? false
                if waitingForYou {
                    TurnNotice(symbol: "lock", text: "等待你处理上面的权限", tint: .secondary)
                } else {
                    ThinkingIndicator()
                }
            }
            if let failure = turn.failure {
                TurnNotice(symbol: "exclamationmark.circle", text: failure, tint: .orange, action: turn.answer.isEmpty ? retry : nil)
                    .accessibilityIdentifier("assistant.message")
            }
            if turn.state == .cancelled {
                TurnNotice(symbol: "stop.circle", text: "已停止", tint: .secondary, action: turn.answer.isEmpty ? retry : nil)
            }
        }
    }

    /// Every source the turn's tools actually returned, de-duplicated by URL.
    private var sources: [AgentStep.Source] {
        guard let trace else { return [] }
        var seen = Set<String>()
        return trace.steps.flatMap(\.sources).filter { seen.insert($0.url).inserted }
    }
}

enum UserBubbleStyle {
    static let fill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.055) })
}

/// Failure, stop and waiting states of a turn: one quiet line, with a retry where re-asking makes sense.
struct TurnNotice: View {
    let symbol: String
    let text: String
    let tint: Color
    var action: (() -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.subheadline).foregroundStyle(tint)
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action: action) { Label("重试", systemImage: "arrow.clockwise").font(.subheadline.weight(.medium)) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    .accessibilityIdentifier("turn.retry")
            }
        }
    }
}

private struct ThinkingIndicator: View {
    var body: some View {
        ShimmerText(text: "思考中")
            .accessibilityLabel("Thinking")
            .accessibilityIdentifier("agent.thinking")
            .fixedSize()
    }
}

// CONTEXT MEMORY
// Updated: 2026-10-27
// Status: mixed
// Why: Bubble Text selection did not expose reliable native selection handles or speech actions.
// Debug Goal: Long press selects real text while token updates preserve the current selection.
// Search Tags: chat UITextView selection edit menu copy cut draft streaming sizeThatFits
// Invariants:
// - Stored messages stay read-only; cutting a user selection edits a composer draft copy.
// - Selection pauses automatic following; programmatic text updates never publish selection state.
// - The view measures its text at the proposed width and never scrolls inside the chat bubble.
// - Ancestor scroll content shapes must not replace the native text view's hit region.
// Failure Modes:
// - An outer contextMenu steals the native word-selection gesture.
// - Assigning identical text or mutating SwiftUI state during updates resets selection or flashes layout.
private struct SelectableMessageText: UIViewRepresentable {
    var text: String
    var user: Bool
    var canRead: Bool
    var identifier: String
    var read: (String) -> Void
    var edit: ((String) -> Void)?
    var selectionChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true; view.delegate = context.coordinator
        context.coordinator.textView = view
        let menu = UIEditMenuInteraction(delegate: context.coordinator)
        context.coordinator.menu = menu; view.addInteraction(menu)
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectWord(_:)))
        press.minimumPressDuration = 0.45; press.cancelsTouchesInView = false; press.delegate = context.coordinator
        view.addGestureRecognizer(press)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        view.accessibilityIdentifier = identifier
        view.tintColor = .systemBlue
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: view.traitCollection)
        if view.text != text || view.font?.pointSize != font.pointSize {
            let previous = view.selectedRange
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = MarkdownStyle.lineSpacing
            view.attributedText = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph
            ])
            let length = (text as NSString).length, start = min(previous.location, length)
            view.selectedRange = NSRange(location: start, length: min(previous.length, length - start))
            view.invalidateIntrinsicContentSize()
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let content = view.attributedText ?? NSAttributedString(string: "")
        let rect = content.boundingRect(with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        // Assistant wrapping uses one stable column throughout a stream.
        let fittingWidth = user ? min(width, max(1, ceil(rect.width) + 2)) : width
        let size = view.sizeThatFits(CGSize(width: fittingWidth, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: fittingWidth, height: ceil(size.height) + 1)
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate, @MainActor UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
        var parent: SelectableMessageText
        var updating = false
        weak var textView: UITextView?
        var menu: UIEditMenuInteraction?
        init(_ parent: SelectableMessageText) { self.parent = parent }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating else { return }
            let selected = textView.selectedRange.length > 0
            parent.selectionChanged(selected)
        }
        @objc func selectWord(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = textView else { return }
            view.becomeFirstResponder()
            let point = gesture.location(in: view)
            if let position = view.closestPosition(to: point),
               let range = view.tokenizer.rangeEnclosingPosition(position, with: .word,
                    inDirection: UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)) {
                view.selectedTextRange = range
            } else { view.selectAll(nil) }
            parent.selectionChanged(true)
            menu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        }
        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                 suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let view = textView else { return nil }
            return textView(view, editMenuForTextIn: view.selectedRange, suggestedActions: suggestedActions)
        }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            let full = parent.text as NSString
            let valid = range.location != NSNotFound && range.location <= full.length && range.length <= full.length - range.location
            let selected = valid && range.length > 0 ? full.substring(with: range) : parent.text
            var extra: [UIMenuElement] = [
                UIAction(title: "复制全部", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = self.parent.text },
                UIAction(title: "朗读全文", image: UIImage(systemName: "speaker.wave.2"),
                         attributes: parent.canRead ? [] : [.disabled]) { _ in self.parent.read(self.parent.text) }
            ]
            if valid && range.length > 0 {
                extra.append(UIAction(title: "朗读所选文字", image: UIImage(systemName: "speaker.wave.1"),
                    attributes: parent.canRead ? [] : [.disabled]) { _ in self.parent.read(selected) })
            }
            if let edit = parent.edit {
                extra.append(UIAction(title: "编辑并重发", image: UIImage(systemName: "pencil")) { _ in edit(self.parent.text) })
                if valid && range.length > 0 {
                    extra.append(UIAction(title: "剪切到输入框", image: UIImage(systemName: "scissors")) { _ in
                        UIPasteboard.general.string = selected
                        edit(full.replacingCharacters(in: range, with: ""))
                    })
                }
            }
            return UIMenu(children: [UIMenu(options: .displayInline, children: extra)] + suggestedActions)
        }
    }
}
struct AttachmentImage: View {
    let attachment: ImageAttachment
    @State private var image: UIImage?
    private var aspect: CGFloat {
        guard let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber, height.doubleValue > 0 else { return 1 }
        return width.doubleValue / height.doubleValue
    }
    var body: some View {
        Group { if let image { Image(uiImage: image).resizable() } else { Rectangle().fill(.quaternary) } }
            .aspectRatio(aspect, contentMode: .fit)
            .task(id: attachment.id) { image = UIImage(data: attachment.data) }.accessibilityLabel("所选图片")
    }
}
enum PhotoPreparation {
    static func prepare(_ data: Data) throws -> ImageAttachment {
        guard data.count <= 30_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1280, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
              let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.72), jpeg.count <= 900_000 else { throw AppFailure.message("图片太大或格式不支持，请选择另一张图片。") }
        return ImageAttachment(data: jpeg)
    }
}
enum HoldDestination: String { case send, edit, cancel
    static func at(vertical translation: CGFloat) -> Self {
        translation <= -180 ? .cancel : translation <= -75 ? .edit : .send
    }
}

// CONTEXT MEMORY
// Updated: 2026-10-27
// Status: inferred
// Why: Release should send; dragging upward chooses edit, then cancel.
// Debug Goal: Keep the original gesture alive while the recording overlay hides the composer.
// Search Tags: hold speech release send drag edit cancel zones global translation
// Invariants:
// - Edit and cancel are drag destinations, not tap actions.
// - The pressed view stays mounted until release; global translation does not move with layout.
// - Recognition finalization completes before the parent routes the draft to send or edit.
// - Compact drag targets use their actual horizontal bounds; text growth never moves edit.
// Failure Modes:
// - Replacing the pressed view loses onEnded and leaves capture running.
// - Submitting a partial transcript before the final dictation draft arrives loses words.
struct HoldToTalkButton: View {
    var phase: VoicePhase
    var level: Double
    var showsControl = true
    var editZone = CGRect.zero
    var cancelZone = CGRect.zero
    var onStart: () -> Void
    var onRelease: (HoldDestination) -> Void
    var onCancel: () -> Void
    var onInteraction: (Bool, HoldDestination) -> Void = { _, _ in }
    @State private var active = false
    @State private var destination = HoldDestination.send
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        HStack(spacing: 9) {
            if active {
                Image(systemName: destination == .cancel ? "xmark" : "mic.fill").font(.system(size: 18))
                Text("松开发送").font(.subheadline.weight(.medium)).lineLimit(2)
            } else { Label("按住说话", systemImage: "mic.fill").font(.body.weight(.medium)) }
        }.frame(maxWidth: .infinity, minHeight: 48).contentShape(Capsule())
            .glassEffect(active || !showsControl ? .identity : .regular.interactive(), in: .capsule)
            .opacity(showsControl ? 1 : 0)
            .scaleEffect(active ? 1.02 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: active)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
            .onChange(of: active) { _, value in if value { AppFeedback.medium() } }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !active { active = true; destination = .send; onInteraction(true, .send); HoldTalkTrace.touchDown(); HoldTalkTrace.recordingVisible(); DispatchQueue.main.async { onStart() } }
                    let next = HoldZones.destination(at: value.location, cancel: cancelZone, edit: editZone, translation: value.translation)
                    if next != destination { destination = next; AppFeedback.medium() }
                    onInteraction(true, destination)
                }
                .onEnded { _ in finish(destination) })
            .onChange(of: scenePhase) { _, phase in if phase != .active, active { finish(.cancel) } }
            .onDisappear { if active { finish(.cancel) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(active ? "结束并发送" : "按住说话，松开发送，上滑编辑，再上滑取消").accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if active { finish(.send) }
                else { active = true; destination = .send; onInteraction(true, .send); onStart() }
            }
            .accessibilityAction(named: "结束并编辑") { if active { finish(.edit) } }
            .accessibilityAction(named: "取消录音") { if active { finish(.cancel) } }
            .accessibilityIdentifier("assistant.holdToTalk")
    }
    private func finish(_ result: HoldDestination) {
        guard active else { return }
        active = false; onInteraction(false, result)
        if result == .cancel { onCancel() } else { onRelease(result) }
    }
}

struct HoldRecordingOverlay: View {
    let destination: HoldDestination
    let transcript: String
    /// True once the session reports `.listening`; before that the microphone is not capturing yet and the text says so.
    var ready = true
    var frameChanged: (HoldDestination, CGRect) -> Void = { _, _ in }
    // Reserve three semantic text lines so live recognition cannot move either target.
    @ScaledMetric(relativeTo: .body) private var transcriptHeight = 72.0
    var body: some View {
        VStack(spacing: 14) {
            zone("取消", icon: "xmark", target: .cancel)
            Text(transcript.isEmpty ? (ready ? "正在听…" : "正在准备麦克风…") : transcript).font(.body).multilineTextAlignment(.center)
                .lineLimit(3).frame(height: transcriptHeight).frame(maxWidth: 320)
                .accessibilityIdentifier("composer.recording.transcript")
            zone("编辑", icon: "pencil", target: .edit)
            Text(destination == .cancel ? "松开取消" : destination == .edit ? "松开编辑" : "松开发送")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(height: 48)
                .accessibilityIdentifier("composer.recording.status")
        }.frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.bottom, 8)
    }
    private func zone(_ title: String, icon: String, target: HoldDestination) -> some View {
        Label(title, systemImage: icon).font(.subheadline.weight(.medium))
            .padding(.horizontal, 22).frame(minWidth: 104, minHeight: 44)
            .foregroundStyle(target == .cancel ? Color.red : Color.primary)
            .glassEffect(.regular.tint(target == .cancel ? .red.opacity(destination == target ? 0.16 : 0.06) : destination == target ? .accentColor.opacity(0.12) : .clear), in: .capsule)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameChanged(target, $0) }
            .scaleEffect(destination == target ? 1.03 : 1)
            .animation(.easeOut(duration: 0.16), value: destination)
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
            .accessibilityIdentifier("composer.recording.\(target.rawValue)")
    }
}
