import SwiftUI
import PhotosUI
import AssistantCore
import AgentRuntime
import UIKit

/// Latest scroll zone seen by the scroll observer. Plain reference, deliberately not observable: it only lets the header state be
/// re-synchronised when the scroll view is created already scrolled (no change event ever fires for a value that starts there).
private final class ScrollZoneBox { var zone = 0 }

/// The message column. Short and medium conversations use a plain stack: every row is measured, so scrolling to the end is exact and the
/// screen is never left blank. (A lazy stack scrolled to an id before its rows were measured landed in an unrendered region.)
/// Very long conversations fall back to a lazy stack.
private struct ChatStack<Content: View>: View {
    var lazy: Bool
    @ViewBuilder var content: Content
    var body: some View {
        if lazy { LazyVStack(alignment: .leading, spacing: 0) { content } }
        else { VStack(alignment: .leading, spacing: 0) { content } }
    }
}

/// What the conversation scroll position is allowed to cause. Equatable and coarse on purpose (see the observer in `chatScroll`).
private struct ChatScrollSnapshot: Equatable {
    var zone: Int
    var nearBottom: Bool
    var contentHeight: CGFloat
    /// The offset is past the end of the content (blank screen). A lazy stack scrolled to an id before its rows were measured can land here.
    var beyondEnd = false
    var offset: CGFloat = 0
    var debug = ""
}

struct AssistantView: View {
    private enum Mode: String { case orb, chat }
    @Environment(AppModel.self) private var model
    @Environment(ConversationLibrary.self) private var library
    #if DEBUG && targetEnvironment(simulator)
    @Environment(AccountCenter.self) private var accountCenter
    @Environment(LocalModelCenter.self) private var localModelCenter
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("italk.conversation.mode") private var selectedMode = "orb"
    @Namespace private var motion
    @State private var orbEpoch = Date.now
    @State private var input = ""
    @State private var settings = false
    @State private var sidebar = false
    @State private var started = false
    @State private var dictation = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var attachments: [ImageAttachment] = []
    @State private var attachSheet = false
    @State private var showCamera = false
    @State private var showSkills = false
    @State private var showRemote = false
    @State private var afterAttachSheet: AttachmentChoice?
    @State private var afterAttachCamera = false
    @State private var preparingPhotos = false
    @State private var photoTask: Task<Void, Never>?
    @State private var confirmImages = false
    @State private var pendingScrollTarget: UUID?
    @State private var followLatest = true
    @State private var nearBottom = true
    @State private var userScrolling = false
    @State private var scrollState = ChatScrollState()
    @State private var zoneBox = ScrollZoneBox()
    @State private var micHoldStarted = 0.0
    @State private var micHoldFromField = false
    @State private var composerPressed = false
    /// Voice/microphone notices may show in the text composer only right after a hold-to-talk attempt or in the dictation bar.
    @State private var holdNoticeVisible = false
    @State private var followTask: Task<Void, Never>?
    @State private var selectedMessage: String?
    @State private var editingMessage = false
    @State private var openingConversation = false
    @State private var composerFrame = CGRect.zero
    @State private var fullOrbFrame = CGRect.zero
    @State private var compactOrbFrame = CGRect.zero
    @State private var expandedDraft = false
    @State private var availableHeight: CGFloat = 700
    @State private var recordingPress = false
    @State private var micHold = false
    @State private var micHoldDestination = HoldDestination.send
    @State private var recordingCancel = false
    @State private var recordingDestination = HoldDestination.send
    @State private var pendingDictation: HoldDestination?
    @State private var recordingEditFrame = CGRect.zero
    @State private var recordingCancelFrame = CGRect.zero
    @State private var characterPreview = false
    @State private var playground = false
    @State private var rigPlayground = false
    @FocusState private var focused: Bool
    @FocusState private var editorFocused: Bool
    private var mode: Mode { Mode(rawValue: selectedMode) ?? .orb }
    private var busy: Bool { [.preparing, .listening, .finalizing, .thinking, .synthesizing, .speaking].contains(model.session.phase) }
    private var canSend: Bool {
        !busy && !preparingPhotos && input.count <= 3000
            && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }
    private var transition: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.48, bounce: 0.08) }

    var body: some View {
        @Bindable var model = model
        navigation
            .background(AppInteractionFeedback())
            .background(OutsideKeyboardDismissal(enabled: mode == .chat && !sidebar && !settings && !expandedDraft && !characterPreview, excluded: composerFrame, dismiss: dismissKeyboard))
            .sheet(isPresented: $settings) { SettingsView() }
            .sheet(isPresented: $attachSheet, onDismiss: {
                if afterAttachCamera { afterAttachCamera = false; showCamera = true }
                else if afterAttachSheet == .skills { afterAttachSheet = nil; showSkills = true }
            }) {
                AttachmentSheet(photos: $photos, cameraAvailable: CameraPicker.isAvailable) { choice, camera in
                    afterAttachSheet = choice; afterAttachCamera = camera
                }
            }
            .sheet(isPresented: $showSkills) { NavigationStack { SkillsHubView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSkills = false } } } } }
            .sheet(isPresented: $showRemote) { NavigationStack { RemoteDevicesView() } }
            .fullScreenCover(isPresented: $showCamera) { CameraPicker(captured: attachCaptured).ignoresSafeArea() }
            .sheet(isPresented: $characterPreview) {
                #if DEBUG
                CharacterMotionPreview().environment(\.scenePhase, scenePhase)
                #endif
            }
            .sheet(isPresented: $expandedDraft, onDismiss: { focused = mode == .chat }) { draftEditor }
            .fullScreenCover(isPresented: $playground) { NavigationStack { MessageScenarioPlayground() } }
            .fullScreenCover(isPresented: $rigPlayground) { NavigationStack { CompanionPlayground() } }
            .sheet(item: $model.actionDraft) { draft in ActionReviewView(draft: draft) }
            .sheet(item: $model.confirmation) { value in memoryConfirmation(value) }
            .confirmationDialog("发送这些图片？", isPresented: $confirmImages, titleVisibility: .visible) {
                Button("确认发送 \(attachments.count) 张图片") { send(approvedImages: true) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("所选图片和文字会发送到你配置的网关及其模型服务商，按用量计费。图片可能包含私人或健康信息，请确认愿意处理这些内容；本次授权不包含长期保存。")
            }
            .onOpenURL { url in
                guard url.scheme == "italk", url.host == "voice", url.path == "/start" else { return }
                closeSidebar(); switchMode(.orb); model.startListening()
            }
            .task { await initialLaunch() }
            .onChange(of: model.dictationDraft) { _, value in
                if let value {
                    let destination = pendingDictation ?? .edit
                    pendingDictation = nil
                    model.dictationDraft = nil
                    guard destination != .cancel else { return }
                    input = input.isEmpty ? value : input + " " + value
                    dictation = false
                    if destination == .send { focused = false; requestSend() }
                    else { focused = mode == .chat && !sidebar }
                }
            }
            .onChange(of: photos) { _, items in preparePhotos(items) }
            .onChange(of: model.session.phase) { _, phase in if phase == .listening { HoldTalkTrace.microphoneReady() } }
            .onChange(of: scenePhase) { _, phase in
                // Claude hook: leaving the foreground (or pulling down Notification Center) must not stop the voice session
                // or running answers; only a held dictation is dropped.
                if phase == .background || phase == .inactive {
                    focused = false; recordingPress = false; recordingCancel = false; micHold = false; model.sceneLeftForeground()
                    pendingDictation = nil
                }
            }
            .overlay {
                if scenePhase != .active {
                    Rectangle().fill(.background).overlay { Label("iTalk", systemImage: "lock").foregroundStyle(.secondary) }.ignoresSafeArea()
                }
            }
    }

    private var navigation: some View {
        NavigationStack {
            GeometryReader { geometry in
                let drawerWidth = min(320, geometry.size.width - 56)
                ZStack(alignment: .leading) {
                    conversationPage(bottomSafeArea: geometry.safeAreaInsets.bottom)
                        .allowsHitTesting(!sidebar).accessibilityHidden(sidebar)
                    if sidebar {
                        Button(action: closeSidebar) {
                            Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.08)).ignoresSafeArea()
                        }
                            .buttonStyle(.plain).accessibilityLabel("收起侧边栏").accessibilityIdentifier("history.dismiss")
                            .transition(.opacity)
                        ConversationSidebar(close: closeSidebar, newConversation: startNewConversation, openSettings: showSettings,
                            selectConversation: openConversation)
                            .frame(width: drawerWidth).frame(maxHeight: .infinity)
                            .shadow(color: .black.opacity(0.06), radius: 12, x: 4)
                            .transition(reduceMotion ? .opacity : .move(edge: .leading))
                            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
                                if value.translation.width < -60 && abs(value.translation.width) > abs(value.translation.height) { closeSidebar() }
                            })
                            .zIndex(2)
                    }
                }
                .background(.background)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
                .toolbar(.hidden, for: .navigationBar)
                .overlay(alignment: .leading) {
                    if !sidebar {
                        Color.clear.frame(width: 16).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                                if value.translation.width > 65 && abs(value.translation.width) > abs(value.translation.height) * 1.5 { openSidebar() }
                            }).accessibilityHidden(true)
                    }
                }
            }
        }.tint(Color(red: 0.06, green: 0.48, blue: 0.94))
    }

    // CONTEXT MEMORY
    // Updated: 2026-10-26
    // Status: mixed
    // Why: iOS 27 automatic scroll edges differ from the requested soft treatment.
    // Debug Goal: Let the native bar blur scrolled content without an opaque header.
    // Search Tags: iOS 27 soft scroll edge transparent header safeAreaBar
    // Invariants:
    // - Both scroll containers explicitly request soft vertical edges.
    // - Header and composer occupy native safe-area bars; content remains inset.
    // - Recording color reaches beneath the bottom safe area while transcript and controls stay inset.
    // Failure Modes:
    // - An opaque header background hides the native progressive effect.
    // - A fixed-height backdrop stops above the Home Indicator despite ignoring the safe area.
    // - Using automatic switches the visual treatment after an OS upgrade.
    private func conversationPage(bottomSafeArea: CGFloat) -> some View {
        let reducesMotion = reduceMotion
        return ZStack {
            if mode == .orb { voiceScreen.transition(.opacity) }
            else { chatScreen.transition(.opacity) }
        }
        .keyframeAnimator(initialValue: CGFloat.zero, trigger: selectedMode) { content, blur in
            content.blur(radius: reducesMotion ? 0 : blur).opacity(reducesMotion ? 1 : 1 - blur * 0.025)
        } keyframes: { _ in
            CubicKeyframe(CGFloat(10), duration: 0.12)
            CubicKeyframe(CGFloat.zero, duration: 0.38)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .top, spacing: 0) {
            ConversationHeader(openHistory: openSidebar, openSettings: showSettings, newConversation: startNewConversation,
                toggleVoice: { switchMode(mode == .chat ? .orb : .chat) }, avatarFrameChanged: { compactOrbFrame = $0 },
                scroll: Self.headerStatic ? nil : scrollState,
                previewCharacter: { dismissKeyboard(); model.cancel(); characterPreview = true })
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            Group {
                if mode == .orb { voiceControls }
                else { composer }
            }.transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 18)))
        }
        // The colour lives on the page's background layer: conversation text and controls draw on top of it, so it can be strong without
        // hiding anything. Always mounted (invisible when idle) so the first hold never pays for creating its layers.
        .background(alignment: .bottom) {
            RecordingBackdrop(state: displayedRecordingState, level: backdropLevel)
                .frame(height: max(340, availableHeight * 0.86) + bottomSafeArea)
                .offset(y: bottomSafeArea).allowsHitTesting(false).accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            if showsHoldOverlay {
                HoldRecordingOverlay(destination: recordingDestination, transcript: recordingTranscript,
                                     ready: model.session.phase == .listening, frameChanged: { target, frame in
                    if target == .edit { recordingEditFrame = frame } else { recordingCancelFrame = frame }
                }).transition(.opacity).allowsHitTesting(false)
            }
        }
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topLeading) {
            if VoicePreview.enabled { VoicePreviewControls(preview: VoicePreview.shared).padding(.leading, 10).padding(.top, 120) }
        }
        #endif
        .overlay { if !Self.hidesOrb { cloudPresentation.allowsHitTesting(false).accessibilityHidden(true) } }
    }

    // CONTEXT MEMORY
    // Updated: 2026-10-30
    // Status: mixed
    // Why: One renderer moves between the compact chat avatar and full voice orb.
    // Debug Goal: Keep the glass holder fixed while the shared orb moves between modes.
    // Search Tags: voice cloud single renderer avatar ghost source avatar transition
    // Invariants:
    // - Only the measured destination and size change during a mode transition.
    // - The renderer clock survives keyboard and presentation changes.
    // - The shared orb is the only animated avatar; header glass stays fixed in both modes.
    // Failure Modes:
    // - Two conditional renderers reset the noise field and snap between hosts.
    // - A second BrandAvatar renderer duplicates the orb after it reaches the header.
    // - A decorative overlay captures composer taps.
    private var cloudPresentation: some View {
        GeometryReader { geometry in
            let origin = geometry.frame(in: .global).origin
            let fallback = mode == .orb
                ? CGRect(x: origin.x + geometry.size.width / 2 - 150, y: origin.y + geometry.size.height * 0.42 - 150, width: 300, height: 300)
                : CGRect(x: origin.x + geometry.size.width / 2 - 18, y: origin.y + geometry.safeAreaInsets.top + 8, width: 36, height: 36)
            let measured = mode == .orb ? fullOrbFrame : compactOrbFrame
            let target = measured.isEmpty ? fallback : measured
            VoiceOrbView(phase: model.session.phase, level: model.audioLevel, speechBeat: model.speechBeat,
                         speechLevel: model.speechLevel, emotion: model.voiceEmotion, emphasis: model.speechEmphasis, epoch: orbEpoch,
                         performanceOverride: voicePerformance)
                .frame(width: target.width, height: target.height)
                .position(x: target.midX - origin.x, y: target.midY - origin.y)
                .animation(reduceMotion ? nil : transition, value: mode)
                // Follows the header avatar's small drop when the model name fades out (same offset, same timing).
                .modifier(HeaderDrop(scroll: mode == .chat && !Self.headerStatic ? scrollState : nil))
        }
    }

    private var voiceScreen: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 20)
                    Color.clear
                        .frame(width: min(geometry.size.width * 0.73, 300), height: min(geometry.size.width * 0.73, 300))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { fullOrbFrame = $0 }
                        .accessibilityElement(children: .ignore).accessibilityLabel("iTalk 语音球").accessibilityValue(model.session.phase.label)
                        .accessibilityIdentifier("assistant.orb")
                        .padding(.vertical, 16)
                    VStack(spacing: 14) {
                        VStack(spacing: 4) {
                            let snapshot = voiceSnapshot
                            Text(snapshot.title).font(.title3.weight(.medium)).accessibilityIdentifier("assistant.state")
                                .contentTransition(.opacity).animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: snapshot.title)
                            if let hint = snapshot.hint { Text(hint).font(.footnote).foregroundStyle(.secondary) }
                        }
                        if !model.session.answer.isEmpty {
                            Text(model.session.answer).font(.body).lineSpacing(4).multilineTextAlignment(.center).textSelection(.enabled)
                        } else if !model.session.transcript.isEmpty {
                            Text(model.session.transcript).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        } else {
                            Text("想到什么，就说给我听。").font(.body).foregroundStyle(.secondary)
                        }
                        if let message = model.message {
                            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).accessibilityIdentifier("assistant.message")
                        }
                    }.padding(.horizontal, 30).frame(maxWidth: 540)
                    Spacer(minLength: 32)
                }.frame(minHeight: geometry.size.height).frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden).scrollEdgeEffectStyle(.soft, for: .vertical)
        }
    }

    private var showsSuggestions: Bool {
        model.conversation.isEmpty && !openingConversation && input.isEmpty && attachments.isEmpty && !dictation && !recordingPress
            && !voiceLive
    }

    private var showsActionCapsules: Bool {
        mode == .chat && !model.conversation.isEmpty && !voiceLive && !dictation && !showsHoldOverlay
            && input.isEmpty && attachments.isEmpty && !focused && !expandedDraft && !editingMessage
    }

    /// Skills and remote computers (real destinations) plus quick actions that make sense for the last finished answer.
    private var actionCapsules: [ActionCapsule] {
        var actions = [
            ActionCapsule(id: "skills", title: "技能", icon: "sparkles") { dismissKeyboard(); showSkills = true },
            ActionCapsule(id: "remote", title: "我的电脑", icon: "laptopcomputer.and.iphone") { dismissKeyboard(); showRemote = true },
        ]
        if let last = model.conversation.last, last.state == .complete, !last.answer.isEmpty {
            actions += [
                ActionCapsule(id: "summarize", title: "总结", icon: "text.alignleft", enabled: !busy) { model.submit("请用三句话总结以上内容。") },
                ActionCapsule(id: "continue", title: "继续", icon: "arrow.turn.down.right", enabled: !busy) { model.submit("请继续。") },
                ActionCapsule(id: "read", title: "朗读", icon: "speaker.wave.2", enabled: !busy) { model.readAloud(last.answer) },
            ]
        }
        return actions
    }

    private var chatScreen: some View {
        ZStack(alignment: .bottom) {
            // An inset, not an overlay: messages scroll above the row and are never covered by it.
            chatScroll.safeAreaInset(edge: .bottom, spacing: 0) {
                if showsActionCapsules {
                    ActionCapsules(actions: actionCapsules).padding(.vertical, 4).transition(.opacity)
                }
            }
            // Starter prompts belong to the empty page, not to the composer bar: the bar stays one input row tall so its edge material is small.
            if showsSuggestions {
                SuggestionCapsules(suggestions: SuggestionEngine.suggestions(recent: library.conversations), icon: suggestionIcon, choose: chooseSuggestion)
                    .padding(.bottom, 4).transition(.opacity)
            }
        }
    }

    private var chatScroll: some View {
        GeometryReader { geometry in
            // Safe-area bars and keyboard avoidance already reduce this proposed height.
            let viewport = max(0, geometry.size.height)
            let turnMinimum = model.conversation.count == 1
                ? max(0, viewport - UIFont.preferredFont(forTextStyle: .caption2).lineHeight - 34) : viewport
            ScrollViewReader { proxy in
                ScrollView {
                    ChatStack(lazy: model.conversation.count > 60) {
                        if model.conversation.isEmpty {
                            if openingConversation { ProgressView().frame(maxWidth: .infinity, minHeight: viewport) }
                            else if input.isEmpty && attachments.isEmpty { HomeWordmark().frame(minHeight: viewport) }
                            else { Color.clear.frame(height: viewport) }
                        } else {
                            Text(model.conversation.first?.createdAt ?? .now, format: .dateTime.month().day())
                                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 16)
                            ForEach(model.conversation) { turn in
                                ConversationRow(turn: turn, canRead: !busy, edit: editMessage, read: model.readAloud, selectionChanged: messageSelection,
                                                trace: AgentPlatform.shared.traces[turn.id],   // Claude hook: reasoning + execution trace
                                                retry: busy || !turn.images.isEmpty || turn.question.isEmpty ? nil : { [question = turn.question] in model.submit(question) })
                                    .equatable().padding(.top, 8).padding(.bottom, 24)
                                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
                                    // The newest turn only holds the extra room while it is still being answered; afterwards the room is
                                    // released smoothly so a finished short answer never leaves a screenful of blank scrolling behind it.
                                    .frame(minHeight: turn.id == model.conversation.last?.id && turn.state == .pending ? turnMinimum : 0, alignment: .top)
                                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: turn.state == .pending)
                                    .id(turn.id)
                                    #if DEBUG && targetEnvironment(simulator)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                                        if Self.auditsLayout, turn.id == model.conversation.last?.id { ChatSendAudit.record("turn", frame) }
                                    }
                                    #endif
                            }
                            ForEach(model.researchSources) { source in Link(source.title, destination: source.url).font(.caption).padding(.bottom, 8) }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }.padding(.horizontal, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .defaultScrollAnchor(.top)
                // Generated interfaces may post a message back into this conversation (never while an answer is running).
                .environment(\.genUIHandler, GenUIHandler(send: { text, _ in model.submit(text); return true }, canSend: !busy))
                .scrollDismissesKeyboard(.interactively).scrollEdgeEffectStyle(.soft, for: .vertical)
                .accessibilityIdentifier("assistant.messages")
                // One observer for everything the scroll position drives. The snapshot only changes when a threshold is crossed or the
                // content grows, so nothing is written (and no view is re-evaluated) on ordinary scroll frames.
                .onScrollGeometryChange(for: ChatScrollSnapshot.self) { scroll in
                    let y = scroll.contentOffset.y + scroll.contentInsets.top
                    let zone = y < 10 ? 0 : y > 28 ? 2 : 1
                    zoneBox.zone = zone
                    var snapshot = ChatScrollSnapshot(zone: zone,
                        nearBottom: scroll.contentOffset.y + scroll.containerSize.height + scroll.contentInsets.bottom >= scroll.contentSize.height - 80,
                        contentHeight: scroll.contentSize.height,
                        beyondEnd: scroll.contentOffset.y > max(scroll.contentSize.height + scroll.contentInsets.bottom - scroll.containerSize.height,
                                                                -scroll.contentInsets.top) + 24)
                    #if DEBUG && targetEnvironment(simulator)
                    if Self.auditsLayout { snapshot.offset = scroll.contentOffset.y }
                    #endif
                    #if DEBUG
                    if HitchMeter.enabled {
                        snapshot.debug = String(format: "off=%.0f content=%.0f container=%.0f inTop=%.0f inBot=%.0f", scroll.contentOffset.y,
                            scroll.contentSize.height, scroll.containerSize.height, scroll.contentInsets.top, scroll.contentInsets.bottom)
                    }
                    #endif
                    return snapshot
                } action: { before, after in
                    #if DEBUG && targetEnvironment(simulator)
                    if Self.auditsLayout {
                        ChatLayoutAudit.record(height: after.contentHeight, offset: after.offset, viewport: viewport)
                        ChatSendAudit.record("viewport", CGRect(x: geometry.safeAreaInsets.top, y: geometry.safeAreaInsets.bottom, width: geometry.size.height, height: viewport))
                    }
                    #endif
                    #if DEBUG
                    if HitchMeter.enabled, after.beyondEnd != before.beyondEnd || after.contentHeight != before.contentHeight { HitchMeter.shared.note("scroll \(after.debug) beyondEnd=\(after.beyondEnd)") }
                    #endif
                    syncHeaderCollapse()
                    if after.beyondEnd, !userScrolling, !before.beyondEnd || after.contentHeight != before.contentHeight { correctOverscroll(proxy) }
                    if after.nearBottom != before.nearBottom {
                        nearBottom = after.nearBottom
                        if userScrolling { followLatest = after.nearBottom }
                    }
                    if after.contentHeight > before.contentHeight + 0.5 { scheduleFollow(proxy) }
                }
                .onAppear { Task { @MainActor in try? await Task.sleep(for: .milliseconds(250)); syncHeaderCollapse() } }
                .onScrollPhaseChange { _, phase in
                    if phase == .idle { syncHeaderCollapse() }
                    let wasUserScrolling = userScrolling
                    userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                    #if DEBUG
                    HitchMeter.shared.setScrolling(userScrolling)
                    #endif
                    if phase == .tracking { followLatest = false }
                    if phase == .idle, wasUserScrolling, selectedMessage == nil { followLatest = nearBottom }
                }
                .onChange(of: model.conversation.last?.id, initial: true) { _, id in
                    followTask?.cancel(); followTask = nil; selectedMessage = nil
                    followLatest = true
                    guard let id, !sidebar else { pendingScrollTarget = id; return }
                    // The first turn is already at the top below its date; scrolling would lift it a second time.
                    guard model.conversation.count > 1 else { pendingScrollTarget = nil; return }
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { proxy.scrollTo(id, anchor: .top) }
                    pendingScrollTarget = nil
                }
                .onChange(of: viewport) { _, _ in scheduleFollow(proxy) }
                .onChange(of: sidebar) { _, open in
                    if !open, let id = pendingScrollTarget {
                        var transaction = Transaction(); transaction.disablesAnimations = true
                        withTransaction(transaction) { proxy.scrollTo(id, anchor: .top) }; pendingScrollTarget = nil
                    } else if !open { scheduleFollow(proxy) }
                }
                .onDisappear { followTask?.cancel(); followTask = nil }
                .overlay(alignment: .bottomTrailing) {
                    // Always in the tree (opacity only): creating a glass view in the middle of a scroll gesture is a hitch of its own.
                    let visible = !nearBottom && !model.conversation.isEmpty
                    Button { selectedMessage = nil; followLatest = true; scheduleFollow(proxy) } label: {
                        Image(systemName: "arrow.down").frame(width: 40, height: 40)
                    }.buttonStyle(.glass).buttonBorderShape(.circle).padding(12)
                        .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: visible)
                        .accessibilityLabel("回到最新消息").accessibilityIdentifier("assistant.scrollLatest")
                }
            }
        }
    }

    #if DEBUG
    // A/B switches for frame-pacing experiments (`-hitchMeter`): not shipped behaviour.
    private static let headerStatic = ProcessInfo.processInfo.arguments.contains("-abHeaderStatic")
    private static let hidesOrb = ProcessInfo.processInfo.arguments.contains("-abNoOrb")
    #else
    private static let headerStatic = false
    private static let hidesOrb = false
    #endif
    #if DEBUG && targetEnvironment(simulator)
    private static let auditsLayout = ProcessInfo.processInfo.arguments.contains("-chatLayoutFixture")
    #endif

    /// The header state follows the scroll zone (title and avatar drop). Idempotent, and called on every scroll change, when a scroll ends and
    /// shortly after the scroll view appears, so a freshly created, already scrolled view can never leave the title in the wrong state.
    private func syncHeaderCollapse() {
        let desired: Bool?
        switch zoneBox.zone { case 2: desired = !model.conversation.isEmpty; case 0: desired = false; default: desired = nil }
        if let desired, scrollState.collapsed != desired { scrollState.collapsed = desired }
    }

    /// Never leave the person looking at nothing: if the scroll offset ended up past the content (estimated row heights), go to the real end.
    private func correctOverscroll(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            guard !userScrolling else { return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func chooseSuggestion(_ suggestion: PromptSuggestion) {
        switch suggestion.action {
        case .send(let text): editingMessage = false; model.submit(text)
        case .openConversation(let id): openConversation(id)
        }
    }
    private func attachCaptured(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        do { attachments = Array((attachments + [try PhotoPreparation.prepare(data)]).suffix(3)) }
        catch { model.message = error.localizedDescription }
    }
    private func suggestionIcon(_ suggestion: PromptSuggestion) -> String {
        switch suggestion.kind {
        case .unfinishedTask: "arrow.trianglehead.clockwise"
        case .continueConversation: "bubble.left.and.bubble.right"
        case .timeOfDay: "sun.horizon"
        case .starter:
            suggestion.title.contains("消息") ? "square.and.pencil" : suggestion.title.contains("饭") ? "fork.knife" : "lightbulb"
        }
    }

    // CONTEXT MEMORY
    // Updated: 2026-10-27
    // Status: inferred
    // Why: Measuring a growing row into a separate tail spacer caused two layout passes per token.
    // Debug Goal: Anchor new user turns at the top and coalesce streaming follow after layout.
    // Search Tags: chat streaming scroll throttle latest turn spacer first image message top
    // Invariants:
    // - The newest turn owns a minimum viewport height; no measured tail feeds back into layout.
    // - Geometry size already excludes safe-area bars and keyboard; do not subtract their insets again.
    // - A first turn stays below its date without a delayed second scroll.
    // - Selection, manual scrolling and the sidebar suspend automatic following.
    // - Only committed content-size growth schedules follow; token arrival alone never scrolls.
    // Failure Modes:
    // - Bottom-anchoring a short first image puts it in the wrong vertical position.
    // - A separately resized tail alternately grows and shrinks the scroll content.
    private func scheduleFollow(_ proxy: ScrollViewProxy) {
        guard followLatest, !sidebar, selectedMessage == nil, pendingScrollTarget == nil, followTask == nil else { return }
        followTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            defer { followTask = nil }
            guard !Task.isCancelled, followLatest, !sidebar, selectedMessage == nil, pendingScrollTarget == nil else { return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
    private func messageSelection(_ id: String, _ selected: Bool) {
        if selected { if selectedMessage != id { selectedMessage = id }; followLatest = false }
        else if selectedMessage == id { selectedMessage = nil }
    }
    private func editMessage(_ text: String, _ images: [ImageAttachment]) {
        input = text; attachments = images; dictation = false; editingMessage = true
        selectedMessage = nil; focused = true
    }
    private func openConversation(_ id: UUID) {
        endVoice(); dismissKeyboard(); openingConversation = true; closeSidebar(); switchMode(.chat)
        Task { await model.openConversation(id); openingConversation = false }
    }

    private var voiceControls: some View {
        HStack(spacing: 28) {
            Button { switchMode(.chat) } label: { Image(systemName: "text.bubble").font(.system(size: 21)).frame(width: 48, height: 48) }
                .buttonStyle(.glass).buttonBorderShape(.circle).tint(.primary).accessibilityLabel("文本聊天").accessibilityIdentifier("assistant.keyboard")
            Button { model.toggleVoice() } label: {
                Image(systemName: voiceControlIcon).font(.system(size: 24)).frame(width: 64, height: 64)
            }
            .buttonStyle(.glassProminent).buttonBorderShape(.circle)
            .matchedGeometryEffect(id: "microphoneControl", in: motion, properties: .position)
            .accessibilityLabel(voiceControlLabel).accessibilityIdentifier("assistant.voice")
            Button(action: showSettings) { Image(systemName: "slider.horizontal.3").font(.system(size: 21)).frame(width: 48, height: 48) }
                .buttonStyle(.glass).buttonBorderShape(.circle).tint(.primary).accessibilityLabel("语音设置")
        }.padding(.top, 12).padding(.bottom, 18).frame(maxWidth: .infinity)
    }

    /// Session states the coarse phase cannot express (paused, interrupted, end-of-turn check, error) act through the character.
    private var voicePerformance: CharacterPerformance? {
        switch model.voice.state {
        case .paused: .drowsy
        case .interrupted: .puzzled
        case .detectingEndOfTurn: .attentive
        case .error: .blocked
        default: nil
        }
    }

    /// What the voice session is doing, in words, taken from the coordinator state (never inferred from the orb).
    private var voiceStatus: (title: String, hint: String?) {
        if model.recognizerPreparing { return ("正在准备语音识别…", "可以先开始说话") }
        switch model.voice.state {
        case .idle: return ("轻点麦克风开始", nil)
        case .listening: return ("在听", nil)
        case .detectingEndOfTurn: return ("在听", "好像说完了…")
        case .processing: return ("思考中", "轻点可停止")
        case .speaking: return ("正在说", "直接说话可以打断")
        case .paused(let reason):
            switch reason {
            case .noSpeech: return ("已暂停", "太久没听到声音 · 轻点继续")
            case .background: return ("已暂停", "切回 iTalk 后轻点继续")
            case .user: return ("已暂停", "轻点继续")
            case .routeChange: return ("已暂停", "音频设备变了 · 轻点继续")
            }
        case .interrupted: return ("被打断", "来电或其他 App 占用了声音 · 轻点继续")
        case .error(let why): return ("出错了", why)
        }
    }

    // Claude hook: the model decides what the central control does (VoiceControlAction); the view only renders it.
    private var voiceControlIcon: String {
        switch model.voiceControlAction { case .start: "mic.fill"; case .submit: "arrow.up"; case .pause: "pause.fill"; case .stop: "stop.fill" }
    }
    private var voiceControlLabel: String {
        switch model.voiceControlAction { case .start: "开始说话"; case .submit: "说完了"; case .pause: "暂停"; case .stop: "停止" }
    }

    /// What the voice UI reads. Production values come from the model; the simulator-only preview can override them because the
    /// simulator has no audio input (see DebugVoicePreview.swift).
    private struct VoiceSnapshot {
        var live: Bool
        var phase: VoicePhase
        var title: String
        var hint: String?
        var micLevel: Double
        var speechLevel: Double
    }
    private var voiceSnapshot: VoiceSnapshot {
        #if DEBUG && targetEnvironment(simulator)
        if VoicePreview.enabled {
            let p = VoicePreview.shared
            return VoiceSnapshot(live: p.session.live, phase: p.phase, title: p.status.title, hint: p.status.hint, micLevel: p.level, speechLevel: p.level)
        }
        #endif
        let status = voiceStatus
        let transcript = model.session.phase == .listening ? model.session.transcript : ""
        return VoiceSnapshot(live: model.voice.isActive, phase: model.session.phase, title: status.title,
                             hint: transcript.isEmpty ? status.hint : String(transcript.suffix(40)),
                             micLevel: model.audioLevel, speechLevel: model.speechLevel)
    }
    private var voiceLive: Bool { voiceSnapshot.live }
    private var voiceBarLive: Bool { voiceLive && !dictation && mode == .chat }
    private func endVoice() {
        #if DEBUG && targetEnvironment(simulator)
        if VoicePreview.enabled { VoicePreview.shared.session = .off }
        #endif
        model.endVoiceSession()
    }

    /// While a voice session runs the transcript is visible with a compact control in place of the text composer.
    private var composer: some View {
        Group {
            if voiceBarLive {
                let snapshot = voiceSnapshot
                VoiceSessionBar(phase: snapshot.phase, title: snapshot.title, hint: snapshot.hint,
                    micLevel: snapshot.micLevel, speechLevel: snapshot.speechLevel,
                    returnToVoice: { switchMode(.orb) },
                    typeInstead: {
                        endVoice()
                        Task { @MainActor in try? await Task.sleep(for: .milliseconds(220)); focused = true }
                    },
                    end: { endVoice() })
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
            } else {
                textComposer.transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }.animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.42, bounce: 0.06), value: voiceBarLive)
    }

    /// Notices that belong to the text conversation. Voice-session hints ("已暂停，点按麦克风继续") stay on the voice screen.
    private var composerMessage: String? {
        guard let message = model.message, model.conversation.last?.failure != message else { return nil }
        if Self.isVoiceHint(message), !holdNoticeVisible, !dictation { return nil }
        return message
    }
    /// Anything about the microphone, audio route or voice session: it belongs to the voice screen, not to a text conversation.
    private static func isVoiceHint(_ message: String) -> Bool {
        ["麦克风", "音频", "耳机", "语音"].contains { message.contains($0) }
    }

    private var textComposer: some View {
        VStack(spacing: 8) {
            if editingMessage {
                HStack {
                    Text("编辑消息副本").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { input = ""; attachments = []; editingMessage = false }.font(.caption)
                }.padding(.horizontal, 8)
            }
            if let message = composerMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("composer.message")
            }
            if !attachments.isEmpty { attachmentStrip }
            if preparingPhotos { ProgressView("正在准备图片").font(.caption) }
            if input.count > 180 || input.filter({ $0 == "\n" }).count > 3 {
                HStack {
                    Button("展开编辑", systemImage: "arrow.up.left.and.arrow.down.right") { dismissKeyboard(); expandedDraft = true }
                        .font(.caption).accessibilityIdentifier("composer.expand")
                    Spacer()
                    Text("\(input.count)/3000").font(.caption2.monospacedDigit()).foregroundStyle(input.count > 3000 ? Color.red : Color.secondary)
                }.padding(.horizontal, 58)
            }
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    Button { dismissKeyboard(); attachSheet = true } label: {
                        Image(systemName: "plus").font(.system(size: 20)).frame(width: 44, height: 48)
                    }
                    .buttonStyle(.plain).glassEffect(recordingPress ? .identity : .regular.interactive(), in: .circle).tint(.primary)
                    .accessibilityLabel("添加").accessibilityIdentifier("assistant.attach")
                    .allowsHitTesting(!recordingPress).disabled(recordingPress).accessibilityHidden(recordingPress)
                    if dictation {
                        HoldToTalkButton(phase: model.session.phase, level: model.audioLevel,
                            showsControl: !recordingPress,
                            editZone: recordingEditFrame, cancelZone: recordingCancelFrame,
                            onStart: startHeldDictation,
                            onRelease: finishHeldDictation, onCancel: { pendingDictation = nil; model.cancel() },
                            onInteraction: { pressed, destination in
                                recordingPress = pressed; recordingDestination = destination; recordingCancel = destination == .cancel
                            })
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        Button {
                            model.cancel(); pendingDictation = nil; recordingPress = false
                            withAnimation(transition) { dictation = false }; focused = true
                        } label: { Image(systemName: "keyboard").font(.system(size: 20)).frame(width: 44, height: 48) }
                        .buttonStyle(.plain).glassEffect(recordingPress ? .identity : .regular.interactive(), in: .circle).tint(.primary)
                        .accessibilityLabel("键盘输入").accessibilityIdentifier("composer.keyboard")
                        .allowsHitTesting(!recordingPress).disabled(recordingPress).accessibilityHidden(recordingPress)
                    } else { textInput }
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
        .opacity(showsHoldOverlay ? 0 : 1).accessibilityHidden(showsHoldOverlay)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showsHoldOverlay)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            composerFrame = $0
            #if DEBUG && targetEnvironment(simulator)
            ChatSendAudit.record("composer", $0)
            #endif
        }
    }

    // CONTEXT MEMORY
    // Updated: 2026-10-26
    // Status: mixed
    // Why: A flexible maxHeight stretched even empty drafts into a tall input well.
    // Debug Goal: Grow with text, then scroll internally without hiding send or the keyboard.
    // Search Tags: multiline composer empty input height long draft line limit
    // Invariants:
    // - The line range owns intrinsic height; do not add a flexible maxHeight frame.
    // - Expanded editing and mode changes keep the same draft binding.
    // Failure Modes:
    // - A maximum-height frame consumes spare space even with a one-line draft.
    // - Unbounded lines push controls above or behind the keyboard.
    private var textInput: some View {
        HStack(alignment: .bottom, spacing: 0) {
          VStack(alignment: .leading, spacing: 0) {
            TextField("发消息给 iTalk", text: $input, axis: .vertical)
                .lineLimit(1...(dynamicTypeSize.isAccessibilitySize || availableHeight < 500 ? 4 : 8))
                .focused($focused).padding(.leading, 16)
                .padding(.top, 13).padding(.bottom, lastContextReport == nil ? 13 : 3).accessibilityIdentifier("assistant.input")
                // An unfocused, empty field is also a press-to-talk surface: tap focuses it, a hold records. Once it has focus or text
                // the overlay is gone, so cursor placement, selection and the edit menu are the system's.
                .overlay {
                    if !focused && input.isEmpty {
                        Color.clear.contentShape(Rectangle())
                            .modifier(PressToTalk(pressed: $composerPressed, delay: 0.22, onTap: { focused = true },
                                                  onHold: { beginMicHold(fromField: true) }, onDrag: updateMicHold, onEnd: finishMicHold))
                            .accessibilityHidden(true)
                    }
                }
            if let report = lastContextReport {
                Text("上下文已用（上次请求）\(report.exact ? "" : "约 ")\(report.promptTokens.formatted()) / \(report.window.formatted())")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    .lineLimit(1).padding(.leading, 16).padding(.bottom, 7)
                    .accessibilityIdentifier("composer.contextUsage")
            }
          }
            // Tap switches to hold-to-talk; pressing and holding records right here (release sends, slide up to edit or cancel).
            // Only this icon owns the gesture, so typing and cursor placement in the field are never affected.
            ComposerMicButton(onTap: {
                dismissKeyboard()
                withAnimation(transition) { dictation = true }
                DispatchQueue.main.async { model.warmDictation() }
            }, onHold: { beginMicHold(fromField: false) }, onDrag: updateMicHold, onEnd: finishMicHold)
                .matchedGeometryEffect(id: "microphoneControl", in: motion, properties: .position)
            if model.session.phase == .thinking || model.session.phase == .synthesizing || model.session.phase == .speaking {
                Button { model.cancel() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(.tint, in: Circle()).frame(width: 48, height: 48)
                }.buttonStyle(.plain).accessibilityLabel(model.readingMessage ? "停止朗读" : "停止回答")
                    .accessibilityIdentifier("assistant.stopResponse")
            } else {
                Button {
                    requestSend()
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold)).foregroundStyle(canSend ? Color.white : .secondary)
                        .frame(width: 34, height: 34).background(canSend ? Color.accentColor : Color.secondary.opacity(0.12), in: Circle()).frame(width: 48, height: 48)
                }.buttonStyle(.plain).accessibilityLabel("发送").accessibilityIdentifier("assistant.send")
                    .disabled(!canSend)
            }
        }.glassEffect(.regular, in: .rect(cornerRadius: 27))
            .scaleEffect(composerPressed ? 0.985 : 1).animation(.snappy(duration: 0.12), value: composerPressed)
    }

    private var lastContextReport: ContextReport? {
        guard let id = library.currentId else { return nil }
        return AgentPlatform.shared.lastContextReport[id]
    }

    private var draftEditor: some View {
        NavigationStack {
            TextEditor(text: $input).font(.body).focused($editorFocused).padding(12)
                .accessibilityIdentifier("draft.editor")
                .scrollDismissesKeyboard(.interactively).scrollEdgeEffectStyle(.soft, for: .vertical)
                .navigationTitle("编辑消息").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { expandedDraft = false }.accessibilityIdentifier("draft.done")
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Text("\(input.count)/3000").font(.caption.monospacedDigit()).foregroundStyle(input.count > 3000 ? Color.red : Color.secondary)
                    }
                }.task { editorFocused = true }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(attachments) { image in
                    AttachmentImage(attachment: image).frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                if let index = attachments.firstIndex(where: { $0.id == image.id }) {
                                    attachments.remove(at: index); if photos.indices.contains(index) { photos.remove(at: index) }
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.7)).frame(width: 44, height: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).offset(x: 10, y: -10).accessibilityLabel("移除图片")
                        }
                }
            }.padding(.horizontal, 8).padding(.vertical, 8)
        }.scrollIndicators(.hidden).transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func switchMode(_ value: Mode) {
        guard value != mode else { return }
        dismissKeyboard()
        recordingPress = false; recordingCancel = false
        pendingDictation = nil
        // A live voice session is part of the same conversation: moving to the transcript keeps it running (the composer becomes the
        // compact VoiceSessionBar) and moving back reveals the same session. Only an idle capture is wound down here.
        if !(voiceLive && !dictation) {
            if model.session.phase == .listening { if dictation { model.cancel() } else { model.finishListening() } }
            if model.session.phase == .preparing { model.cancel() }
        }
        if value == .chat, let message = model.message, Self.isVoiceHint(message) { model.message = nil }
        withAnimation(transition) {
            selectedMode = value.rawValue
            dictation = false
        }
    }
    private func dismissKeyboard() {
        focused = false
        selectedMessage = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    private func openSidebar() {
        dismissKeyboard(); recordingPress = false; recordingCancel = false
        pendingDictation = nil
        if dictation && [.preparing, .listening, .finalizing].contains(model.session.phase) { model.cancel() }
        if voiceLive || model.session.phase == .listening { endVoice() }
        withAnimation(transition) { sidebar = true }
    }
    private func closeSidebar() { withAnimation(transition) { sidebar = false } }
    private func showSettings() { dismissKeyboard(); model.cancel(); closeSidebar(); settings = true }
    private func startNewConversation() {
        endVoice(); dismissKeyboard(); photoTask?.cancel(); photos = []; attachments = []; input = ""; editingMessage = false; model.newConversation()
        closeSidebar(); switchMode(.chat)
    }
    private func send(approvedImages: Bool) {
        let text = input, images = attachments
        guard images.isEmpty || model.localVisionAvailable || model.grants.contains(.cloudAI) else { model.message = "请先在设置中下载本地模型，或开启云端 AI。"; return }
        guard text.count <= 3000 else { model.message = "请将消息控制在 3000 字以内。"; return }
        #if DEBUG && targetEnvironment(simulator)
        ChatSendAudit.record("submit", composerFrame)
        #endif
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            input = ""; attachments = []; photos = []; editingMessage = false
            model.submit(text, images: images, imagesApproved: approvedImages)
        }
    }
    private func requestSend() {
        if attachments.isEmpty || model.localVisionAvailable { send(approvedImages: false) }
        else { dismissKeyboard(); confirmImages = true }
    }
    private func heldDestination(_ drag: DragGesture.Value) -> HoldDestination {
        HoldZones.destination(at: drag.location, cancel: recordingCancelFrame, edit: recordingEditFrame, translation: drag.translation)
    }
    /// The visible recording state is committed first; the microphone work follows on the next run-loop turn so a slow start can
    /// never delay the feedback. Readiness is reported separately (`HoldTalkTrace.microphoneReady`, `ready:` on the overlay).
    private func beginMicHold(fromField: Bool) {
        guard !micHold else { return }
        micHoldFromField = fromField
        micHold = true; micHoldDestination = .send; micHoldStarted = ProcessInfo.processInfo.systemUptime
        recordingDestination = .send; recordingCancel = false
        holdNoticeVisible = true
        Task { @MainActor in try? await Task.sleep(for: .seconds(6)); if !micHold { holdNoticeVisible = false } }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { recordingPress = true }
        HoldTalkTrace.recordingVisible()
        AppFeedback.medium()
        DispatchQueue.main.async {
            guard micHold else { return }
            model.warmDictation(); startHeldDictation()
        }
    }
    private func updateMicHold(_ drag: DragGesture.Value) {
        guard micHold else { return }
        let next = heldDestination(drag)
        if next != micHoldDestination { micHoldDestination = next; recordingDestination = next; recordingCancel = next == .cancel; AppFeedback.medium() }
    }
    private func finishMicHold() {
        guard micHold else { return }
        let destination = micHoldDestination
        let heldFor = ProcessInfo.processInfo.systemUptime - micHoldStarted
        micHold = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { recordingPress = false; recordingCancel = false }
        if destination == .cancel { pendingDictation = nil; model.cancel() }
        else if heldFor < 0.45, model.session.transcript.isEmpty {
            // A slow tap, not a recording. Undo it and do what a tap on that surface does.
            pendingDictation = nil; model.cancel()
            if micHoldFromField { focused = true }
            else { dismissKeyboard(); withAnimation(transition) { dictation = true } }
        } else { finishHeldDictation(destination) }
    }
    private var backdropLevel: Double {
        #if DEBUG && targetEnvironment(simulator)
        if VoicePreview.enabled, VoicePreview.shared.recording != nil { return VoicePreview.shared.level }
        if ProcessInfo.processInfo.arguments.contains("-recordingOverlayPreview") { return 0.75 }   // static look-check only
        #endif
        return model.audioLevel
    }
    private var showsHoldOverlay: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if VoicePreview.enabled, VoicePreview.shared.recording != nil { return true }
        #endif
        return recordingPress
    }
    private var displayedRecordingState: RecordingLightState? {
        #if DEBUG && targetEnvironment(simulator)
        if VoicePreview.enabled, let forced = VoicePreview.shared.recording { return forced }
        #endif
        return recordingLight
    }
    private var recordingLight: RecordingLightState? {
        if recordingPress {
            if recordingCancel { return .cancelling }
            switch model.session.phase { case .listening: return .recording; case .failed: return .failed; default: return .preparing }
        }
        if pendingDictation != nil, model.session.phase == .finalizing { return .sending }
        return nil
    }
    private func startHeldDictation() {
        dismissKeyboard(); pendingDictation = nil
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-dictationGestureFixture") { return }
        #endif
        model.startListening(delivery: .dictation, held: true)
    }
    private var recordingTranscript: String {
        #if DEBUG && targetEnvironment(simulator)
        if VoicePreview.enabled, VoicePreview.shared.recording != nil { return VoicePreview.shared.transcript.isEmpty ? "今天下午帮我整理一下会议记录。" : VoicePreview.shared.transcript }
        if ProcessInfo.processInfo.arguments.contains("-recordingOverlayPreview") { return "今天下午帮我整理一下会议记录。" }
        #endif
        return model.session.transcript
    }
    private func finishHeldDictation(_ destination: HoldDestination) {
        pendingDictation = destination
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-dictationGestureFixture") {
            model.dictationDraft = "按住说话测试"; return
        }
        #endif
        model.releaseDictation()
    }
    private func preparePhotos(_ items: [PhotosPickerItem]) {
        photoTask?.cancel(); preparingPhotos = true
        photoTask = Task {
            var prepared: [ImageAttachment] = []
            do {
                for item in items.prefix(3) {
                    try Task.checkCancellation()
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw AppFailure.message("无法读取所选图片，请重新选择。") }
                    prepared.append(try PhotoPreparation.prepare(data))
                }
                try Task.checkCancellation(); attachments = prepared
            } catch is CancellationError { return }
            catch { guard !Task.isCancelled else { return }; model.message = error.localizedDescription }
            preparingPhotos = false
        }
    }
    private func memoryConfirmation(_ confirmation: Confirmation) -> some View {
        NavigationStack {
            Form {
                Section("需要你批准后才会记住") { Text(confirmation.body) }
                Section { Text("只保存在本机。可以随时查看、修改、关闭或删除。").foregroundStyle(.secondary) }
                Button("确认保存") { model.confirmMemory() }.accessibilityIdentifier("memory.confirm")
            }.navigationTitle("保存记忆")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { model.cancel() } } }
        }.onDisappear { if model.session.phase == .confirming { model.cancel() } }
    }
    private func initialLaunch() async {
        guard !started else { return }; started = true
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-chat") { selectedMode = Mode.chat.rawValue }
        if arguments.contains("-orb") { selectedMode = Mode.orb.rawValue }
        if arguments.contains("-dictation") { selectedMode = Mode.chat.rawValue; dictation = true }
        #if targetEnvironment(simulator)
        if arguments.contains("-chatLayoutFixture") {
            await Task.yield()
            library.setHistoryEnabled(false)
            model.conversationBackend = library
            model.localChat = ChatLayoutFixtureEngine(library: library)
            if arguments.contains("-historyFixture") {
                let extra = arguments.contains("-historyFixtureMany")
                    ? ["周末去杭州的行程", "Swift 并发问题", "牙医预约改期", "读书笔记：置身事内", "家里路由器设置", "跑步计划第 3 周", "妈妈生日礼物",
                       "公司周报模板", "二次方程推导", "上海到苏州的高铁", "番茄炒蛋做法", "猫咪疫苗时间", "英文邮件润色", "年终总结提纲", "露营装备清单"] : []
                for title in ["历史测试一", "历史测试二", "历史测试三"] + extra {
                    if let conversation = try? await library.store.createConversation() {
                        _ = try? await library.store.append(ConversationMessage(conversationId: conversation.id, role: .user, parts: [.text(title)]))
                        _ = try? await library.store.append(ConversationMessage(conversationId: conversation.id, role: .assistant, parts: [.text("可选择、归档和撤销的测试记录。")]))
                    }
                }
                await library.refresh()
            }
            if arguments.contains("-fixtureImage") {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 180)).image { context in
                    UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 180))
                    UIColor.white.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 100, y: 40, width: 100, height: 100))
                }
                if let data = image.jpegData(compressionQuality: 0.7) { attachments = [ImageAttachment(data: data)] }
                input = "请描述这张图片"
            }
            if arguments.contains("-recordingOverlayPreview") { dictation = true; recordingPress = true }
        }
        #endif
        if arguments.contains("-characterPreview") { characterPreview = true; return }
        if arguments.contains("-probeCloudPlayback") {
            do { model.message = try await CloudSpeechPlayback.verifyMeteringAndCancel() ? "语音播放与音量检查通过" : "语音播放与音量检查失败" }
            catch { model.message = error.localizedDescription }; return
        }
        if arguments.contains("-probeAudioCallback") {
            do { model.message = try await SpeechInput.verifyTapIsolation() ? "音频回调检查通过" : "音频回调检查失败" }
            catch { model.message = error.localizedDescription }; return
        }
        if arguments.contains("-showSettings") { settings = true; return }
        #if targetEnvironment(simulator)
        // Real-model checks against the loopback dev gateway (server/tools/dev-sim-gateway.mjs): credentials come from the launch
        // environment only, never from the repo.
        let env = ProcessInfo.processInfo.environment
        if let email = env["ITALK_DEV_EMAIL"], let password = env["ITALK_DEV_PASSWORD"] {
            do { try await accountCenter.signIn(email: email, password: password) } catch { model.message = error.localizedDescription }
            for _ in 0..<40 where localModelCenter.cloudModels.first(where: { $0.id == (env["ITALK_DEV_MODEL"] ?? "deepseek-flash") }) == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if let m = localModelCenter.cloudModels.first(where: { $0.id == (env["ITALK_DEV_MODEL"] ?? "deepseek-flash") }) { localModelCenter.selectCloud(m) }
            else { model.message = "开发网关没有返回云端模型" }
        }
        #endif
        if arguments.contains("-pgScenario") || arguments.contains("-pgContent") { playground = true; return }
        if arguments.contains("-rigPlayground") { rigPlayground = true; return }
        if let index = arguments.firstIndex(of: "-ask"), arguments.count > index + 1 {
            model.archive.preferences.speakResponses = false; model.submit(arguments[index + 1]); return
        }
        if arguments.contains("-noAutoListen") { return }
        #endif
        if mode == .orb && model.archive.preferences.autoListen { model.startListening() }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Deterministic UI stream through the real AppModel/storage path, never an inference benchmark or shipping provider.
@MainActor private final class ChatLayoutFixtureEngine: LocalChatEngine {
    let isAvailable = true, supportsVision = true
    let displayName = "布局测试", modelId = "ui.layout.fixture"
    private let library: ConversationLibrary
    private var run = UUID()
    init(library: ConversationLibrary) { self.library = library }
    func cancel() { run = UUID(); ChatLayoutAudit.save() }
    let usesCloud = false
    func respond(conversationId: UUID, turnId: UUID, voice: Bool, onText: @escaping @MainActor (String) -> Void) async throws -> String {
        let key = UUID(); run = key
        let question = try await library.store.messages(conversationId).last(where: { $0.role == .user })?.text ?? ""
        ChatLayoutAudit.begin(enabled: question.contains("抽动"))
        let answer: String
        if question.contains("卡片") {
            answer = """
            来做一道选择题：
            ```italk-ui
            {"id":"fixture-quiz","state":{"choice":""},"root":{"type":"card","title":"小测验","children":[{"type":"text","value":"太阳从哪个方向升起？"},{"type":"chips","options":["东方","西方","北方"],"bind":"choice"},{"type":"button","label":"提交","action":{"type":"send","text":"我选 {{choice}}"}}]}}
            ```
            """
        } else if question.contains("格式") {
            // Rendering check: Markdown, lists, code, math and a wide table streamed through the real chat path.
            let parts: [MessageScenarioPlayground.Content] = [.markdown, .lists, .swift, .math, .table, .python, .markdown, .math]
            answer = parts.map(\.text).joined(separator: "\n\n")
        } else if question.contains("长流式") {
            answer = (1...48).map { "第\($0)段：这段文字用于检查持续输出、选取和手动滚动。打开侧边栏时回答应继续，返回后不应闪动或丢失内容。" }.joined(separator: "\n\n") + "\n流式检查完成。"
        } else {
            answer = "这是一条用于检查消息位置和文字操作的回答。你可以长按选取文字，或在菜单中复制和朗读。"
        }
        let characters = Array(answer)
        var output = ""
        for start in stride(from: 0, to: characters.count, by: 8) {
            try Task.checkCancellation(); guard run == key else { throw CancellationError() }
            output += String(characters[start..<min(start + 8, characters.count)])
            onText(output)
            try await Task.sleep(for: .milliseconds(question.contains("长流式") || ProcessInfo.processInfo.arguments.contains("-sendLayoutProbe") ? 90 : 25))
        }
        ChatSendAudit.save()
        return output
    }
}

/// QA geometry only: no message contents, no production timing or model benchmark.
@MainActor private enum ChatLayoutAudit {
    struct Sample: Codable {
        let elapsed: Double
        let height: CGFloat
        let offset: CGFloat
        let viewport: CGFloat
    }
    static var samples: [Sample] = []
    static var enabled = false
    static var started = 0.0
    static func begin(enabled value: Bool) {
        enabled = value; samples = []; started = ProcessInfo.processInfo.systemUptime
    }
    static func record(height: CGFloat, offset: CGFloat, viewport: CGFloat) {
        guard enabled, samples.count < 2048 else { return }
        samples.append(Sample(elapsed: ProcessInfo.processInfo.systemUptime - started, height: height, offset: offset, viewport: viewport))
    }
    static func save() {
        guard enabled, let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: URL.documentsDirectory.appending(path: "ui-streaming-layout.json"), options: .atomic)
        enabled = false
    }
}
@MainActor private enum ChatSendAudit {
    static var samples: [[String: Any]] = []
    static func record(_ kind: String, _ frame: CGRect) {
        guard ProcessInfo.processInfo.arguments.contains("-sendLayoutProbe"), samples.count < 2000 else { return }
        samples.append(["time": ProcessInfo.processInfo.systemUptime, "kind": kind,
            "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height])
    }
    static func save() {
        guard !samples.isEmpty, let data = try? JSONSerialization.data(withJSONObject: samples, options: .prettyPrinted) else { return }
        try? data.write(to: URL.documentsDirectory.appending(path: "ui-send-layout.json"), options: .atomic)
    }
}
#endif
