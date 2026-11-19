import SwiftUI
import UIKit
import AssistantCore

/// What the hold-to-talk surface is doing. `nil` = idle (nothing drawn).
enum RecordingLightState: Equatable {
    /// Finger is down; the microphone is not capturing yet. Deliberately pale and slow.
    case preparing
    /// Capturing: colour, height and motion follow the real microphone level.
    case recording
    /// The finger is over the cancel zone.
    case cancelling
    /// Released; recognition is finishing.
    case sending
    case failed
}

struct RecordingBackdrop: View {
    var state: RecordingLightState?
    /// Real microphone level, 0…1 (`AppModel.audioLevel`). Never synthesized here.
    var level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        RecordingLightSurface(input: RecordingLightInput(level: level, state: state, dark: colorScheme == .dark,
            quiet: reduceMotion, active: scenePhase == .active))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct RecordingLightInput {
    var level: Double
    var state: RecordingLightState?
    var dark: Bool
    var quiet: Bool
    var active: Bool
}
private struct RecordingLightSurface: UIViewRepresentable {
    var input: RecordingLightInput
    func makeUIView(context: Context) -> RecordingLightView { RecordingLightView(input: input) }
    func updateUIView(_ view: RecordingLightView, context: Context) { view.update(input) }
    static func dismantleUIView(_ view: RecordingLightView, coordinator: ()) { view.stop() }
}
@MainActor private final class RecordingLightClock: NSObject {
    weak var view: RecordingLightView?
    @objc func tick(_ link: CADisplayLink) { view?.advance(at: link.timestamp) }
}

// CONTEXT MEMORY
// Updated: 2026-10-28
// Status: mixed
// Why: A held recording needs a soft, audio-reactive color wash without visual jitter or particle noise.
// Debug Goal: Let smoothed microphone energy gently change the lower-screen glow.
// Search Tags: recording color glow smooth audio level no particles
// Invariants:
// - Only diffuse color gradients are drawn; no particles or sharp waveform paths.
// - Microphone energy uses a smoothed attack and release so the color does not flicker.
// - Silence has faint drift; cancellation changes color from its current blend.
// - Reduce Motion stops spatial movement; inactive/detached/hidden views stop the display link.
// - The renderer never intercepts gestures or changes recognition/delivery state.
// Failure Modes:
// - Driving color directly from each meter sample makes the backdrop pulse erratically.
// - Publishing SwiftUI state on display ticks redraws unrelated chat/gesture layouts.
@MainActor private final class RecordingLightView: UIView {
    private typealias RGB = (r: Double, g: Double, b: Double)
    private var input: RecordingLightInput
    private let light = CALayer(), floor = CAGradientLayer(), fade = CAGradientLayer()
    private let halos = (0..<3).map { _ in CAGradientLayer() }
    private let clock = RecordingLightClock()
    private var link: CADisplayLink?
    private var lastTick = 0.0, flow = 0.0, energy = 0.0, visibility = 0.0, breath = 0.0
    private var colors: [RGB] = RecordingLightView.palette(for: .preparing, energy: 0)
    init(input: RecordingLightInput) {
        self.input = input
        super.init(frame: .zero)
        isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false
        clock.view = self; layer.addSublayer(light); light.mask = fade
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        fade.locations = [0, 0.12, 0.94, 1]
        floor.startPoint = CGPoint(x: 0.5, y: 0); floor.endPoint = CGPoint(x: 0.5, y: 1)
        light.addSublayer(floor)
        for halo in halos {
            let mask = CALayer(); mask.contents = Self.radialMask
            mask.contentsGravity = .resize; mask.magnificationFilter = .linear
            halo.mask = mask; light.addSublayer(halo)
        }
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() { super.didMoveToWindow(); synchronize() }
    override func layoutSubviews() { super.layoutSubviews(); drawLayers() }
    func update(_ next: RecordingLightInput) {
        input = next
        if !next.active { visibility = 0; energy = 0 }
        if next.quiet { visibility = next.state != nil && next.active ? 1 : 0; energy = targetEnergy }
        synchronize(); drawLayers()
    }
    func stop() { link?.invalidate(); link = nil; lastTick = 0 }
    private func synchronize() {
        guard window != nil, input.active, !input.quiet, input.state != nil || visibility > 0.002 else { stop(); return }
        guard link == nil else { return }
        let display = CADisplayLink(target: clock, selector: #selector(RecordingLightClock.tick(_:)))
        display.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        display.add(to: .main, forMode: .common); link = display; lastTick = 0
    }

    /// Speech sits around 0.45–0.85 on the app's level scale and a quiet room under 0.2, so the useful range is stretched.
    private var targetEnergy: Double {
        switch input.state {
        case nil: return 0
        case .preparing: return 0.10 + 0.04 * sin(breath * 2.4)
        case .recording: return Self.stretch(input.level)
        case .cancelling: return max(0.22, Self.stretch(input.level))
        case .sending: return 0.5
        case .failed: return 0.6
        }
    }
    private static func stretch(_ level: Double) -> Double {
        guard level.isFinite else { return 0 }
        return pow(min(1, max(0, (level - 0.14) / 0.74)), 0.75)
    }
    private static func palette(for state: RecordingLightState?, energy: Double) -> [RGB] {
        func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t) }
        switch state {
        case .recording, nil:
            // Calm blue at low energy; cyan, violet and magenta take over as the voice gets louder.
            let calm: [RGB] = [(0.05, 0.52, 1.0), (0.18, 0.36, 0.96), (0.34, 0.30, 0.92)]
            let hot: [RGB] = [(0.0, 0.88, 1.0), (0.66, 0.26, 1.0), (1.0, 0.30, 0.64)]
            return (0..<3).map { mix(calm[$0], hot[$0], min(1, energy * 1.25)) }
        case .preparing: return [(0.52, 0.62, 0.78), (0.58, 0.64, 0.80), (0.64, 0.66, 0.82)]
        case .cancelling: return [(1.0, 0.30, 0.38), (0.92, 0.22, 0.44), (1.0, 0.52, 0.36)]
        case .sending: return [(0.08, 0.80, 0.58), (0.0, 0.74, 0.86), (0.30, 0.86, 0.52)]
        case .failed: return [(1.0, 0.56, 0.12), (1.0, 0.28, 0.24), (0.96, 0.72, 0.18)]
        }
    }

    func advance(at now: Double) {
        let dt = lastTick == 0 ? 1.0 / 60 : min(0.05, max(0, now - lastTick)); lastTick = now
        breath += dt
        let target = targetEnergy
        energy += (target - energy) * (1 - exp(-dt / (target > energy ? 0.07 : 0.38)))
        let shown = input.state == nil ? 0.0 : 1.0
        visibility += (shown - visibility) * (1 - exp(-dt / (shown > visibility ? 0.09 : 0.24)))
        let goal = Self.palette(for: input.state, energy: energy)
        let k = 1 - exp(-dt / 0.16)
        for i in 0..<3 {
            colors[i] = (colors[i].r + (goal[i].r - colors[i].r) * k, colors[i].g + (goal[i].g - colors[i].g) * k, colors[i].b + (goal[i].b - colors[i].b) * k)
        }
        flow += dt * (0.30 + energy * 1.6)
        drawLayers()
        if input.state == nil, visibility <= 0.004 { visibility = 0; layer.opacity = 0; stop() }
    }
    private func color(_ index: Int, alpha: Double) -> CGColor {
        let c = colors[index % 3]
        return UIColor(red: c.r, green: c.g, blue: c.b, alpha: min(1, alpha)).cgColor
    }
    private func drawLayers() {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let p = input.quiet ? targetEnergy : energy, time = input.quiet ? 0 : flow
        let intensity = input.dark ? 1.0 : 0.94
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = Float(visibility); light.frame = bounds; fade.frame = bounds; floor.frame = bounds
        // The lit region climbs the screen with the voice.
        floor.locations = [0, NSNumber(value: 0.62 - p * 0.30), 1]
        floor.colors = [UIColor.clear.cgColor, color(1, alpha: intensity * (0.16 + p * 0.34)), color(0, alpha: intensity * (0.52 + p * 0.40))]
        for index in halos.indices {
            let k = Double(index)
            let width = w * (0.95 + p * 0.45), height = h * (0.62 + p * 0.50)
            halos[index].bounds = CGRect(x: 0, y: 0, width: width, height: height)
            halos[index].position = CGPoint(x: w * (0.16 + k * 0.34 + sin(time * 0.9 + k * 2.1) * (0.03 + p * 0.07)),
                                           y: h * (0.90 - p * 0.16 + cos(time * 0.7 + k * 1.3) * (0.012 + p * 0.03)))
            halos[index].mask?.frame = halos[index].bounds
            halos[index].colors = [color(index, alpha: 0.80), color(index + 1, alpha: 0.42)]
            halos[index].opacity = Float(intensity * (0.46 + p * 0.50))
        }
        CATransaction.commit()
    }
    private static let radialMask: CGImage = {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160), format: format).image { drawing in
            let colors = [UIColor.white.withAlphaComponent(0.9).cgColor, UIColor.white.withAlphaComponent(0.38).cgColor, UIColor.clear.cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.38, 1])!
            drawing.cgContext.drawRadialGradient(gradient, startCenter: CGPoint(x: 80, y: 80), startRadius: 0,
                endCenter: CGPoint(x: 80, y: 80), endRadius: 80, options: [])
        }.cgImage!
    }()
}

