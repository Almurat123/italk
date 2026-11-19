import Foundation
import AssistantCore

/// The app's only view of on-device chat. The MLX-backed implementation lives in the iOS target (`LocalModelCenter`);
/// Shared code and watchOS never link the inference engine.
@MainActor protocol LocalChatEngine: AnyObject {
    /// A model is installed and may be used for plain conversation (it may still need loading).
    var isAvailable: Bool { get }
    /// The installed local model accepts images (verified per model, not assumed).
    var supportsVision: Bool { get }
    /// Answers the latest user message of `conversationId`. Context (history, images, summaries) is built from the
    /// conversation database, so the user message must already be recorded. Streams cumulative text through `onText`.
    /// `turnId`: the user message this answers (the run's tag; the result is written there even if nobody is waiting).
    /// `voice`: a spoken turn — shorter history and spoken style.
    func respond(conversationId: UUID, turnId: UUID, voice: Bool, onText: @escaping @MainActor (String) -> Void) async throws -> String
    /// Explicit stop of every run started from this engine.
    func cancel()
    /// The cloud model is selected (same agent, billed per use).
    var usesCloud: Bool { get }
    var displayName: String { get }
    var modelId: String { get }
}

/// Conversation persistence as seen from `AppModel`. Implemented by `ConversationLibrary` (iOS).
@MainActor protocol ConversationBackend: AnyObject {
    /// Conversation the next message goes to; created lazily on the first message so empty chats are never stored.
    var currentId: UUID? { get }
    func beginNew()
    /// Records the user turn (text + images as authorized local copies). Returns the conversation id.
    @discardableResult
    func recordUser(turnId: UUID, text: String, images: [Data], sessionOnly: Bool, inputMode: String) async -> UUID?
    func recordAssistant(turnId: UUID, text: String, final: Bool, failed: Bool, modelId: String?, sessionOnly: Bool) async
    /// Loads a stored conversation as UI turns and makes it current.
    func open(_ id: UUID) async -> [ConversationTurn]
}

/// Neural speech output with a single playback queue (iOS: MOSS-TTS-Nano). Text arrives in stable chunks while the answer is still
/// being generated; `completed` fires once after `finishInput()` when every chunk has finished playing.
@MainActor protocol StreamingSpeechEngine: AnyObject {
    /// Installed and selected by the user.
    var isReady: Bool { get }
    func begin(onLevel: @escaping @MainActor (Double) -> Void, onFirstAudio: @escaping @MainActor () -> Void, completed: @escaping @MainActor (Bool) -> Void)
    func enqueue(_ chunks: [String])
    func finishInput()
    func stop()
    /// Text of the chunks that have actually finished playing in the current answer (what the user really heard).
    var playedText: String { get }
    /// Developer timeline hooks (tts_synthesis_started, first_pcm_ready). Numbers only.
    var onMetric: (@MainActor (VoiceTimeline.Event) -> Void)? { get set }
    /// Load models ahead of the first answer (session start), so the first sentence is not delayed by Core ML loading.
    func warmUp()
}
