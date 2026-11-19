import Foundation

/// Where the time between "the person asked to talk" and "words are recognized" goes. Reported by the capture pipeline so the
/// voice timeline can show it and the UI can say "正在准备语音识别…" instead of looking frozen.
public enum CaptureStage: Sendable, Equatable {
    case requested
    /// The microphone is delivering audio; everything from here on is kept (pre-roll), even before recognition is ready.
    case micRunning
    case firstBuffer(frames: Int)
    /// Language assets are downloading or the analyzer is loading: speech is being kept, text will catch up.
    case recognizerPreparing(downloading: Bool)
    case recognizerReady
    case firstText
}
