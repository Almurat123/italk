import SwiftUI
import OSLog

#if DEBUG
/// Frame pacing while the conversation is being scrolled. Enabled with `-hitchMeter`; results go to the unified log
/// (category `ui.hitch`) and `Documents/ui-hitch.log`. A hitch is a frame later than 1.5× the display interval, severe is later than 3×.
@MainActor final class HitchMeter: NSObject {
    static let shared = HitchMeter()
    static let enabled = ProcessInfo.processInfo.arguments.contains("-hitchMeter")
    private let log = Logger(subsystem: "com.italk.assistant", category: "ui.hitch")
    private var link: CADisplayLink?
    private var last = 0.0
    private var frames = 0, hitches = 0, severe = 0
    private var worst = 0.0, total = 0.0
    private var scrolling = false
    private var sessions = 0

    func note(_ text: String) {
        guard Self.enabled else { return }
        log.info("\(text, privacy: .public)")
    }

    func setScrolling(_ on: Bool) {
        guard Self.enabled, on != scrolling else { return }
        if on { frames = 0; hitches = 0; severe = 0; worst = 0; total = 0; last = 0; start() }
        else { report(); link?.invalidate(); link = nil }
        scrolling = on
    }
    private func start() {
        guard link == nil else { return }
        let display = CADisplayLink(target: self, selector: #selector(tick(_:)))
        display.add(to: .main, forMode: .common); link = display
    }
    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let dt = link.timestamp - last, expected = max(0.004, link.targetTimestamp - link.timestamp)
        frames += 1; total += dt; worst = max(worst, dt)
        if dt > expected * 1.5 { hitches += 1 }
        if dt > expected * 3 { severe += 1 }
    }
    private func report() {
        guard frames > 0 else { return }
        sessions += 1
        let line = String(format: "scroll#%d frames=%d hitches=%d severe=%d worst=%.1fms avg=%.2fms", sessions, frames, hitches, severe, worst * 1000, total / Double(frames) * 1000)
        log.info("\(line, privacy: .public)")
        let url = URL.documentsDirectory.appending(path: "ui-hitch.log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
        else { try? data.write(to: url) }
    }
}
#endif
