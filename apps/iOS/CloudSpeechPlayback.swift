import AVFoundation
import Foundation

@MainActor final class CloudSpeechPlayback: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var metering: Task<Void, Never>?
    private var onLevel: ((Double) -> Void)?
    private var completion: ((Bool) -> Void)?

    func play(_ data: Data, onLevel: @escaping (Double) -> Void, completed: @escaping (Bool) -> Void) throws {
        stop()
        do {
            let player = try AVAudioPlayer(data: data)
            self.player = player; self.onLevel = onLevel; completion = completed
            player.delegate = self; player.isMeteringEnabled = true
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            guard player.prepareToPlay(), player.play() else { throw AppFailure.message("语音暂时无法播放。") }
            metering = Task { [weak self, weak player] in
                while !Task.isCancelled {
                    guard let self, let player, self.player === player, player.isPlaying else { return }
                    player.updateMeters()
                    let level = (Double(player.averagePower(forChannel: 0)) + 50) / 44
                    self.onLevel?(min(1, max(0, level)))
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
            }
        } catch { stop(); throw error }
    }
    func stop() {
        let hadPlayer = player != nil
        metering?.cancel(); metering = nil
        completion = nil; onLevel?(0); onLevel = nil
        player?.stop(); player = nil
        if hadPlayer { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    // CONTEXT MEMORY
    // Updated: 2026-10-26
    // Status: inferred
    // Why: Cloud speech uses decoded playback level for mouth motion, independently of microphone capture.
    // Debug Goal: Stop playback, metering, and stale completion together on cancellation.
    // Search Tags: cloud speech playback RMS mouth metering cancel stale AVAudioPlayer
    // Invariants:
    // - Only the current player may publish completion; no microphone is opened here.
    // - Stop clears callbacks before deactivating the audio session.
    // Failure Modes:
    // - A previous player's completion stops the next utterance.
    // - A surviving meter task animates a silent or cancelled reply.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(ObjectIdentifier(player), success: flag)
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish(ObjectIdentifier(player), success: false)
    }
    nonisolated private func finish(_ id: ObjectIdentifier, success: Bool) {
        Task { @MainActor [weak self] in
            guard let self, let player = self.player, ObjectIdentifier(player) == id else { return }
            let callback = self.completion; self.stop(); callback?(success)
        }
    }
    #if DEBUG
    static func verifyMeteringAndCancel() async throws -> Bool {
        // A local tone verifies the real playback meter, not the cloud model's voice quality.
        var data = Data("RIFF".utf8)
        func integer(_ value: UInt32, bytes: Int) {
            for offset in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
        }
        let frames = 16000
        integer(UInt32(36 + frames * 2), bytes: 4); data.append(Data("WAVEfmt ".utf8))
        integer(16, bytes: 4); integer(1, bytes: 2); integer(1, bytes: 2)
        integer(16000, bytes: 4); integer(32000, bytes: 4); integer(2, bytes: 2); integer(16, bytes: 2)
        data.append(Data("data".utf8)); integer(UInt32(frames * 2), bytes: 4)
        for index in 0..<frames {
            let sample = Int16(sin(Double(index) * .pi * 2 * 440 / 16000) * 5000)
            integer(UInt32(UInt16(bitPattern: sample)), bytes: 2)
        }
        let playback = CloudSpeechPlayback()
        var maximum = 0.0, last = 0.0, completed = false
        try playback.play(data, onLevel: { maximum = max(maximum, $0); last = $0 }) { _ in completed = true }
        defer { playback.stop() }
        try await Task.sleep(for: .milliseconds(180))
        playback.stop()
        try await Task.sleep(for: .milliseconds(120))
        return maximum > 0.1 && last == 0 && !completed
    }
    #endif
}
