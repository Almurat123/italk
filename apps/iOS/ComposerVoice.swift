import SwiftUI
import OSLog
import AssistantCore

/// Scroll progress of the conversation, read only by the header. A separate observable keeps scrolling from re-evaluating the whole
/// conversation view, and the header changes opacity/scale only (never its height), so the safe-area inset the scroll view sees is constant.
@MainActor @Observable final class ChatScrollState {
    /// True once the first lines have scrolled away (with hysteresis). Written only when a threshold is crossed.
    var collapsed = false
}

/// Touch-to-feedback timing for press-to-talk. Three separate moments are logged so "the UI reacted" is never mistaken for
/// "the microphone is ready": touch-down, visible recording state, and the session reporting `.listening`.
@MainActor enum HoldTalkTrace {
    private static let log = Logger(subsystem: "com.italk.assistant", category: "ui.holdtalk")
    private static var down = 0.0
    private static var visible = 0.0
    static func touchDown() { down = ProcessInfo.processInfo.systemUptime; visible = 0; log.info("touch_down") }
    static func recordingVisible() {
        visible = ProcessInfo.processInfo.systemUptime
        log.info("recording_visible +\(Int((visible - down) * 1000), privacy: .public)ms")
        FramePresentProbe.arm(since: down, log: log)
    }
    static func microphoneReady() {
        guard down > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        log.info("microphone_ready +\(Int((now - down) * 1000), privacy: .public)ms")
        down = 0
    }
}

/// Immediate-feedback press recognizer for the microphone and the empty composer. A single zero-distance drag reports touch-down at once
/// (so there is no tap/long-press arbitration delay before anything moves), arms the hold after `delay`, and reports a tap on a short release.
struct PressToTalk: ViewModifier {
    @Binding var pressed: Bool
    var delay: Double = 0.2
    var onTap: () -> Void = {}
    var onHold: () -> Void
    var onDrag: (DragGesture.Value) -> Void
    var onEnd: () -> Void
    @State private var armed = false
    @State private var moved = false
    @State private var down = false
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !down {
                    down = true; moved = false; armed = false; pressed = true
                    HoldTalkTrace.touchDown(); AppFeedback.light()
                    task = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                        guard !Task.isCancelled, down, !moved else { return }
                        armed = true; onHold()
                    }
                } else if armed { onDrag(value) }
                else if hypot(value.translation.width, value.translation.height) > 16 { moved = true; task?.cancel(); pressed = false }
            }
            .onEnded { _ in
                task?.cancel()
                let wasArmed = armed, wasTap = !armed && !moved
                down = false; armed = false; pressed = false
                if wasArmed { onEnd() } else if wasTap { onTap() }
            })
    }
}

/// The microphone icon inside the text composer: instant pressed feedback, tap = hold-to-talk bar, hold = record in place.
struct ComposerMicButton: View {
    var holdDelay = 0.12
    var onTap: () -> Void
    var onHold: () -> Void
    var onDrag: (DragGesture.Value) -> Void
    var onEnd: () -> Void
    @State private var pressed = false
    var body: some View {
        Image(systemName: "mic").font(.system(size: 20)).frame(width: 44, height: 48).offset(x: 5)
            .foregroundStyle(pressed ? Color.accentColor : .primary)
            .background { Circle().fill(Color.accentColor.opacity(pressed ? 0.16 : 0)).frame(width: 40, height: 40).offset(x: 5) }
            .scaleEffect(pressed ? 1.16 : 1)
            .animation(.snappy(duration: 0.12), value: pressed)
            .contentShape(Rectangle())
            .modifier(PressToTalk(pressed: $pressed, delay: holdDelay, onTap: onTap, onHold: onHold, onDrag: onDrag, onEnd: onEnd))
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
            .accessibilityLabel("切换为按住说话").accessibilityIdentifier("assistant.dictation")
            .accessibilityAction(.default, onTap)
    }
}

/// Slides the avatar a short distance down when the model name has faded out. Offset only: no layout change, and the state it reads lives in
/// its own observable, so only this modifier re-evaluates when the threshold is crossed.
struct HeaderDrop: ViewModifier {
    var scroll: ChatScrollState?
    var distance: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        let down = scroll?.collapsed ?? false
        content.offset(y: down ? distance : 0).animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: down)
    }
}

/// Original hold-to-talk drop zones: cancel is the target above the transcript (or anything above it), edit is the target below it,
/// everything else sends. Without measured frames the vertical drag distance decides.
enum HoldZones {
    static func destination(at point: CGPoint, cancel: CGRect, edit: CGRect, translation: CGSize) -> HoldDestination {
        if !cancel.isEmpty, cancel.insetBy(dx: -12, dy: -10).contains(point) || point.y < cancel.minY { return .cancel }
        if !edit.isEmpty, edit.insetBy(dx: -12, dy: -10).contains(point) { return .edit }
        return edit.isEmpty ? HoldDestination.at(vertical: translation.height) : .send
    }
}

/// Replaces the text composer while a voice session is still running and the person is looking at the transcript.
/// One capsule with the composer's shape: the small brand orb with a restrained ring that follows the real level, the live state,
/// then keyboard and end. Tapping the orb/state area returns to the voice screen. Nothing animates without a real signal.
struct VoiceSessionBar: View {
    var phase: VoicePhase
    var title: String
    var hint: String?
    var micLevel: Double
    var speechLevel: Double
    var returnToVoice: () -> Void
    var typeInstead: () -> Void
    var end: () -> Void

    /// 0…1, only while the microphone or the speaker is really producing signal.
    private var pulse: Double {
        let raw = phase == .speaking ? speechLevel : phase == .listening ? micLevel : 0
        return raw.isFinite ? min(1, max(0, raw)) : 0
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: returnToVoice) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().strokeBorder(Color.accentColor.opacity(0.55 * pulse), lineWidth: 2).frame(width: 40, height: 40)
                            .scaleEffect(1 + 0.16 * pulse)
                        BrandAvatar(size: 32)
                    }
                    .frame(width: 44, height: 44).animation(.easeOut(duration: 0.12), value: pulse)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(hint ?? "轻点返回语音界面").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, 8).frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回语音界面").accessibilityValue(title).accessibilityIdentifier("voicebar.return")
            Button(action: typeInstead) { Image(systemName: "keyboard").font(.system(size: 20)).frame(width: 46, height: 52) }
                .buttonStyle(.plain).accessibilityLabel("改用键盘输入").accessibilityIdentifier("voicebar.keyboard")
            Button(action: end) { Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary).frame(width: 46, height: 52) }
                .buttonStyle(.plain).accessibilityLabel("结束语音对话").accessibilityIdentifier("voicebar.end")
        }
        .padding(.trailing, 4).tint(.primary)
        .glassEffect(.regular, in: .rect(cornerRadius: 27))
    }
}

/// Logs when the first display frame after the recording state was committed is actually produced: the honest "it is on screen" time.
@MainActor final class FramePresentProbe: NSObject {
    private static var current: FramePresentProbe?
    private var link: CADisplayLink?
    private var since = 0.0
    private var log: Logger?
    static func arm(since: Double, log: Logger) {
        let probe = FramePresentProbe(); probe.since = since; probe.log = log; current = probe
        let display = CADisplayLink(target: probe, selector: #selector(tick(_:)))
        display.add(to: .main, forMode: .common); probe.link = display
    }
    @objc private func tick(_ link: CADisplayLink) {
        link.invalidate()
        let now = ProcessInfo.processInfo.systemUptime
        log?.info("first_frame_after_state +\(Int((now - self.since) * 1000), privacy: .public)ms (frame target \(Int((link.targetTimestamp - link.timestamp) * 1000), privacy: .public)ms)")
        Self.current = nil
    }
}
