import SwiftUI
import UIKit
import QuartzCore
import AssistantCore
import AgentRuntime

// iTalk companion rig. A procedural character, not a set of swapped images: every visible quantity (body position, squash,
// stretch, lean, silhouette roundness, interior light, each eye's size / roundness / rotation / lids / symbol morph, gaze) is a
// damped spring driven by a behaviour director. Springs give anticipation, overshoot, follow-through and elastic recovery for
// free; the director adds intent (idle life, attention, listening, thinking, tool use, speaking, reactions) with randomized
// timing so nothing loops mechanically. Rendering is Core Animation layers updated from a display link inside one UIView:
// SwiftUI is never invalidated per frame and chat scrolling is unaffected.

// MARK: - Springs

struct RigSpring {
    var value: Double
    var velocity: Double = 0
    var target: Double
    init(_ v: Double) { value = v; target = v }
    /// Semi-implicit Euler on a damped harmonic oscillator; `response` ≈ settle period (s), `damping` 1 = critical.
    mutating func step(_ dt: Double, response: Double, damping: Double) {
        let k = pow(2 * .pi / max(0.02, response), 2), c = 4 * .pi * damping / max(0.02, response)
        velocity += (-k * (value - target) - c * velocity) * dt
        value += velocity * dt
    }
    mutating func kick(_ v: Double) { velocity += v }
}

// MARK: - Model

enum RigEmotion: String, CaseIterable, Identifiable {
    case neutral, happy, excited, love, curious, thinking, focused, sad, surprised, confused, sleepy, dizzy, proud, shy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .neutral: "平静"; case .happy: "开心"; case .excited: "兴奋"; case .love: "喜欢"; case .curious: "好奇"; case .thinking: "思考"
        case .focused: "专注"; case .sad: "难过"; case .surprised: "惊讶"; case .confused: "困惑"; case .sleepy: "困倦"; case .dizzy: "出错"
        case .proud: "得意"; case .shy: "害羞"
        }
    }
}

enum RigMode: String, CaseIterable, Identifiable {
    case idle, attentive, listening, thinking, working, speaking, interrupted, success, error
    var id: String { rawValue }
    var title: String {
        switch self {
        case .idle: "待机"; case .attentive: "注意到你"; case .listening: "在听"; case .thinking: "思考"; case .working: "使用工具"
        case .speaking: "说话"; case .interrupted: "被打断"; case .success: "完成"; case .error: "出错"
        }
    }
}

enum RigEyeShape: String, CaseIterable, Identifiable {
    case normal, big, narrow, smile, wink, star, heart, cross, sad, asymmetric
    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: "正常"; case .big: "放大"; case .narrow: "眯眼"; case .smile: "笑眼"; case .wink: "眨一只"; case .star: "星星"
        case .heart: "爱心"; case .cross: "X"; case .sad: "下垂"; case .asymmetric: "一大一小"
        }
    }
}

enum RigAction: String, CaseIterable, Identifiable {
    case jump, bounce, leanLeft, leanRight, peek, turn, nod, shake, startle, wiggle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .jump: "跳"; case .bounce: "弹跳"; case .leanLeft: "左倾"; case .leanRight: "右倾"; case .peek: "探头"; case .turn: "转身"
        case .nod: "点头"; case .shake: "摇头"; case .startle: "吓一跳"; case .wiggle: "扭动"
        }
    }
}

/// Everything the outside world tells the rig. Set from SwiftUI (playground) or from runtime signals; read once per frame.
@MainActor final class CompanionRigController {
    var mode: RigMode = .idle
    var emotion: RigEmotion = .neutral
    /// Explicit eye pose for the playground; nil = the director chooses from mode and emotion.
    var eyeOverride: (left: RigEyeShape, right: RigEyeShape)?
    /// Manual gaze on the unit disk; nil = the director looks around.
    var gazeOverride: CGPoint?
    var autoGazeSweep = false
    /// Real microphone level while listening and playback level while speaking (0…1).
    var inputLevel: Double = 0
    var outputLevel: Double = 0
    var amplitude: Double = 1
    var springResponse: Double = 0.42
    var springDamping: Double = 0.55
    var speed: Double = 1
    var hueShift: Double = 0
    var glow: Double = 1
    var compact = false
    /// Production: follow `CompanionSignalHub` cues (runtime truth first) when it has any; the fields above are the fallback.
    var followsSignals = false
    fileprivate var lastCueSequence = 0
    fileprivate var pending: [RigAction] = []
    func perform(_ action: RigAction) { pending.append(action) }
}

// MARK: - SwiftUI surface

struct CompanionRigSurface: UIViewRepresentable {
    let controller: CompanionRigController
    func makeUIView(context: Context) -> CompanionRigView { CompanionRigView(controller: controller) }
    func updateUIView(_ view: CompanionRigView, context: Context) { view.controller = controller }
    static func dismantleUIView(_ view: CompanionRigView, coordinator: ()) { view.stop() }
}

@MainActor private final class RigTicker: NSObject {
    weak var view: CompanionRigView?
    @objc func tick(_ link: CADisplayLink) { view?.advance(link) }
}

// MARK: - Eye geometry

/// Every eye shape is a radius function sampled at the same angles, so any two shapes (and weighted blends of several)
/// interpolate point-for-point: smooth morphs between ellipse, rounded square, star, heart and cross.
private enum EyeGeometry {
    static let samples = 72
    static let angles: [Double] = (0..<samples).map { Double($0) / Double(samples) * 2 * .pi - .pi / 2 }

    static func superellipse(_ a: Double, w: Double, h: Double, n: Double) -> Double {
        let c = abs(cos(a)) / w, s = abs(sin(a)) / h
        return pow(pow(c, n) + pow(s, n), -1 / n)
    }

    static func polygonRadius(_ a: Double, _ poly: [CGPoint]) -> Double {
        // Ray from the origin at angle a intersected with the polygon; returns the farthest hit.
        let dx = cos(a), dy = sin(a)
        var best = 0.0
        for i in poly.indices {
            let p = poly[i], q = poly[(i + 1) % poly.count]
            let ex = Double(q.x - p.x), ey = Double(q.y - p.y)
            let det = dx * (-ey) - dy * (-ex)
            guard abs(det) > 1e-9 else { continue }
            let px = Double(p.x), py = Double(p.y)
            let t = (px * (-ey) - py * (-ex)) / det
            let u = (dx * py - dy * px) / det
            if t > 0, u >= 0, u <= 1 { best = max(best, t) }
        }
        return best
    }

    static let star: [Double] = {
        let poly: [CGPoint] = (0..<10).map { k in
            let r = k % 2 == 0 ? 1.0 : 0.45, a = Double(k) / 10 * 2 * .pi - .pi / 2
            return CGPoint(x: cos(a) * r, y: sin(a) * r)
        }
        return angles.map { polygonRadius($0, poly) }
    }()
    static let heart: [Double] = {
        var poly: [CGPoint] = []
        for k in 0..<120 {
            let t = Double(k) / 120 * 2 * .pi
            let x = 16 * pow(sin(t), 3), y = -(13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t))
            poly.append(CGPoint(x: x / 17, y: (y + 2) / 17))
        }
        return angles.map { polygonRadius($0, poly) }
    }()
    static let cross: [Double] = {
        let a = 1.0, b = 0.26
        let base: [CGPoint] = [(-b, -a), (b, -a), (b, -b), (a, -b), (a, b), (b, b), (b, a), (-b, a), (-b, b), (-a, b), (-a, -b), (-b, -b)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        let r = Double.pi / 4
        let poly = base.map { CGPoint(x: Double($0.x) * cos(r) - Double($0.y) * sin(r), y: Double($0.x) * sin(r) + Double($0.y) * cos(r)) }
        return angles.map { polygonRadius($0, poly) }
    }()
}

/// The animated state of one eye. All channels are springs.
private struct EyeRig {
    var width = RigSpring(1), height = RigSpring(1), roundness = RigSpring(3.4), rotation = RigSpring(0)
    var star = RigSpring(0), heart = RigSpring(0), cross = RigSpring(0)
    var lidTop = RigSpring(0), lidTilt = RigSpring(0), smile = RigSpring(0)
    var x = RigSpring(0), y = RigSpring(0)

    mutating func step(_ dt: Double, response: Double, damping: Double) {
        for kp in [\EyeRig.width, \EyeRig.height, \EyeRig.roundness, \EyeRig.rotation, \EyeRig.lidTop, \EyeRig.lidTilt, \EyeRig.smile, \EyeRig.x, \EyeRig.y] {
            self[keyPath: kp].step(dt, response: response * 0.8, damping: damping + 0.1)
        }
        for kp in [\EyeRig.star, \EyeRig.heart, \EyeRig.cross] { self[keyPath: kp].step(dt, response: response * 0.9, damping: 0.75) }
    }

    /// Points of the eye outline, centred at the origin, in units of the eye's base size.
    func points(blink: Double, gazeSquash: CGPoint) -> [CGPoint] {
        let sw = max(0, star.value), hw = max(0, heart.value), cw = max(0, cross.value)
        let symbol = min(1, sw + hw + cw)
        let w = max(0.05, width.value), h = max(0.05, height.value)
        let n = min(12, max(1.6, roundness.value))
        var pts: [CGPoint] = []
        pts.reserveCapacity(EyeGeometry.samples)
        let lid = min(0.95, max(0, lidTop.value)), tilt = lidTilt.value, sm = min(1, max(0, smile.value))
        let rot = rotation.value
        for (i, a) in EyeGeometry.angles.enumerated() {
            let base = EyeGeometry.superellipse(a, w: w * 0.5, h: h * 0.5, n: n)
            var r = base * (1 - symbol)
            if symbol > 0 {
                let s = max(w, h) * 0.62
                r += (EyeGeometry.star[i] * sw + EyeGeometry.heart[i] * hw + EyeGeometry.cross[i] * cw) / max(0.0001, sw + hw + cw) * s * symbol
            }
            var x = cos(a) * r, y = sin(a) * r
            // Upper lid: a (tiltable) line coming down from the top flattens and narrows the eye.
            let lidY = -h * 0.5 + lid * h * (1 - symbol * 0.8) + x * tilt
            if y < lidY { y = lidY + (y - lidY) * 0.12 }
            // Smile: the lower lid pushes up in an arch, turning the eye into a happy crescent.
            if sm > 0.01 {
                let arch = h * 0.5 - sm * h * 0.85 * (1 - pow(x / max(0.01, w * 0.55), 2) * 0.55)
                if y > arch { y = arch + (y - arch) * 0.1 }
            }
            y *= max(0.04, 1 - blink)
            let rx = x * cos(rot) - y * sin(rot), ry = x * sin(rot) + y * cos(rot)
            pts.append(CGPoint(x: rx * (1 - gazeSquash.x), y: ry * (1 - gazeSquash.y)))
        }
        return pts
    }
}

// MARK: - The rig view

final class CompanionRigView: UIView {
    var controller: CompanionRigController
    private let ticker = RigTicker()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var time: Double = 0

    // Layers
    private let body = CALayer()
    private let bodyMask = CAShapeLayer()
    private let base = CAGradientLayer()
    private let mist = CAGradientLayer()
    private let deep = CAGradientLayer()
    private let accent = CAGradientLayer()
    private let highlight = CAGradientLayer()
    private let rim = CAShapeLayer()
    private let eyeLayers = [CAShapeLayer(), CAShapeLayer()]
    /// The middle dot of the thinking/waiting expression ("等待中"): grows out of nothing while the two eyes become dots.
    private let middleDot = CAShapeLayer()
    private var dots = RigSpring(0)

    // Body springs (units of body radius unless noted)
    private var bx = RigSpring(0), by = RigSpring(0), squashX = RigSpring(1), squashY = RigSpring(1), lean = RigSpring(0)
    private var roundness = RigSpring(2), turn = RigSpring(0), breath = RigSpring(0)
    private var jumpY = 0.0, jumpV = 0.0, airborne = false, launched = false, bounces = 0
    private var gazeX = RigSpring(0), gazeY = RigSpring(0)
    private var light = RigSpring(0), accentAmount = RigSpring(0), hue = RigSpring(0)
    private var eyes = [EyeRig(), EyeRig()]
    private var eyeSpacing = RigSpring(1)
    private var blink = 0.0, blinkPhase = -1.0, nextBlink = 2.0, doubleBlink = false
    private var nextSaccade = 1.0, saccadeTarget = CGPoint.zero
    private var actionQueue: [(start: Double, action: RigAction)] = []
    private var activeAction: (action: RigAction, start: Double)?
    private var lastMode: RigMode = .idle
    private var modeStart = 0.0
    private var accentColor = UIColor.clear
    private var rng = SystemRandomNumberGenerator()
    private var prevBx = 0.0, prevBy = 0.0

    init(controller: CompanionRigController) {
        self.controller = controller
        super.init(frame: .zero)
        isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false
        ticker.view = self
        layer.addSublayer(body)
        body.mask = bodyMask
        base.startPoint = CGPoint(x: 0.3, y: 0); base.endPoint = CGPoint(x: 0.7, y: 1)
        for g in [mist, deep, accent, highlight] { g.type = .radial; g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 1, y: 1) }
        mist.colors = [UIColor(white: 1, alpha: 1).cgColor, UIColor(white: 1, alpha: 0.8).cgColor, UIColor(white: 1, alpha: 0).cgColor]
        mist.locations = [0, 0.45, 1]
        highlight.colors = [UIColor(white: 1, alpha: 0.75).cgColor, UIColor(white: 1, alpha: 0).cgColor]
        for l in [base, deep, mist, accent] as [CALayer] { body.addSublayer(l) }
        rim.fillColor = UIColor.clear.cgColor; rim.lineWidth = 1
        for e in eyeLayers {
            e.fillColor = UIColor.white.cgColor
            e.shadowColor = UIColor(red: 0.05, green: 0.25, blue: 0.7, alpha: 1).cgColor
            e.shadowOpacity = 0.25; e.shadowRadius = 2; e.shadowOffset = CGSize(width: 0, height: 1)
            layer.addSublayer(e)
        }
        middleDot.fillColor = UIColor.white.cgColor
        middleDot.shadowColor = eyeLayers[0].shadowColor; middleDot.shadowOpacity = 0.25; middleDot.shadowRadius = 2; middleDot.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(middleDot)
    }
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else if link == nil {
            let l = CADisplayLink(target: ticker, selector: #selector(RigTicker.tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
            l.add(to: .main, forMode: .common); link = l; last = 0
        }
    }
    func stop() { link?.invalidate(); link = nil }

    // MARK: frame

    func advance(_ l: CADisplayLink) {
        let now = l.timestamp
        let raw = last == 0 ? 1.0 / 60 : min(1.0 / 20, now - last)
        last = now
        let c = controller
        if c.followsSignals { applyCue(c) }
        let dt = raw * c.speed
        time += dt
        direct(dt, c)
        integrate(dt, c)
        draw(c)
    }

    /// Maps the runtime cue onto the rig. Phase decides posture; levels drive listening/speaking; one-shot events trigger
    /// actions; the model's declared intent (only when it really came from the model) colours the face.
    private func applyCue(_ c: CompanionRigController) {
        let cue = CompanionSignalHub.shared.cue
        guard cue.sequence > 0 else { return }
        c.inputLevel = cue.mic.level ?? 0
        c.outputLevel = cue.speech.level ?? 0
        guard cue.sequence > c.lastCueSequence else { return }
        c.lastCueSequence = cue.sequence
        c.mode = switch cue.phase {
        case .idle, .cancelled: .idle
        case .preparing, .awaitingApproval: .attentive
        case .listening, .transcribing: .listening
        case .thinking: .thinking
        case .working: .working
        case .speaking: .speaking
        case .completed: .idle
        case .interrupted: .interrupted
        case .failed: .error
        }
        var emotion: RigEmotion = .neutral
        if cue.intentSource == .model {
            emotion = switch cue.intent {
            case .neutral, .explaining: .neutral
            case .curious: .curious
            case .focused, .cautious: .focused
            case .encouraging, .comforting: .happy
            case .playful: .proud
            case .celebrating: .excited
            case .apologetic: .sad
            case .uncertain: .confused
            }
        }
        if cue.phase == .awaitingApproval { emotion = .focused }
        if cue.connectivity == .reconnecting { emotion = .confused } else if cue.connectivity == .paused { emotion = .sleepy }
        c.emotion = emotion
        switch cue.event {
        case .toolSucceeded: c.perform(.nod)
        case .toolFailed: c.perform(.shake)
        case .modelSwitched: c.perform(.turn)
        case .completed where cue.intent == .celebrating && cue.intentSource == .model: c.perform(.bounce)
        default: break
        }
    }

    private func rand(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &rng) }

    /// The behaviour director: sets spring targets from mode, emotion, actions, audio and idle life.
    private func direct(_ dt: Double, _ c: CompanionRigController) {
        let amp = c.amplitude
        if c.mode != lastMode { onModeChange(from: lastMode, to: c.mode); lastMode = c.mode; modeStart = time }
        while let a = c.pending.first { c.pending.removeFirst(); actionQueue.append((time, a)) }
        if activeAction == nil, !actionQueue.isEmpty { let a = actionQueue.removeFirst(); activeAction = (a.action, time) }
        let modeAge = time - modeStart

        // Defaults (rest pose); each block below adjusts.
        var targetX = 0.0, targetY = 0.0, sx = 1.0, sy = 1.0, leanT = 0.0, round = 2.0, turnT = 0.0, lightT = 0.0
        var eyeSize = 1.0, spacing = 1.0
        let breathe = sin(time * 2 * .pi / 3.6 + sin(time * 0.37) * 0.8)
        sy += breathe * 0.012 * amp; sx -= breathe * 0.008 * amp

        // Gaze: manual, sweep, or a living saccade pattern with holds (biased to the person, i.e. forward).
        var gaze = CGPoint.zero
        if let g = c.gazeOverride { gaze = g }
        else if c.autoGazeSweep {
            let a = time * 2 * .pi / 6
            gaze = CGPoint(x: cos(a), y: sin(a))
        } else {
            if time >= nextSaccade {
                let attention: Double = [.listening, .speaking, .attentive].contains(c.mode) ? 0.75 : 0.45
                if rand(0...1) < attention { saccadeTarget = CGPoint(x: rand(-0.12...0.12), y: rand(-0.08...0.1)) }
                else {
                    let a = rand(0...(2 * .pi)), r = rand(0.45...1)
                    saccadeTarget = CGPoint(x: cos(a) * r, y: sin(a) * r * 0.85)
                }
                nextSaccade = time + rand(0.9...3.6) * (c.mode == .thinking ? 1.6 : 1)
            }
            gaze = saccadeTarget
        }

        switch c.mode {
        case .idle: break
        case .attentive:
            sy += 0.03; leanT = 0; eyeSize = 1.08
        case .listening:
            let lvl = min(1, c.inputLevel)
            eyeSize = 1.1 + lvl * 0.12; sy += 0.02 + lvl * 0.06 * amp; sx -= lvl * 0.03 * amp
            targetY = -0.02 - lvl * 0.04; leanT = sin(time * 1.3) * 0.02
            lightT = lvl * 0.6
        case .thinking:
            // 等待中: the eyes become three dots; the body floats and breathes, the light drifts slowly inside.
            if c.gazeOverride == nil && !c.autoGazeSweep { gaze = CGPoint(x: sin(time * 0.45) * 0.12, y: -0.1 + cos(time * 0.38) * 0.06) }
            targetY = -0.04 + sin(time * 2 * .pi / 2.6) * 0.035 * amp
            sy += sin(time * 2 * .pi / 2.6 + 0.6) * 0.018 * amp; sx -= sin(time * 2 * .pi / 2.6 + 0.6) * 0.012 * amp
            leanT = sin(time * 0.8) * 0.025; lightT = 0.25 + 0.2 * sin(time * 1.3)
        case .working:
            gaze = c.gazeOverride ?? CGPoint(x: 0.35 + sin(time * 3.1) * 0.35, y: 0.55)
            sy += sin(time * 6.2) * 0.02 * amp; leanT = 0.06; round = 3.2; lightT = 0.3 + 0.2 * sin(time * 4)
        case .speaking:
            let lvl = min(1, c.outputLevel)
            sy += lvl * 0.10 * amp; sx -= lvl * 0.06 * amp; targetY = -lvl * 0.05 * amp
            leanT = sin(time * 1.7) * 0.03; lightT = lvl * 0.8; eyeSize = 1 + lvl * 0.08
        case .interrupted:
            if modeAge < 0.6 { eyeSize = 1.35; sy += 0.1 }
        case .success:
            lightT = 0.8
        case .error:
            leanT = sin(modeAge * 18) * 0.06 * exp(-modeAge * 2.5)
        }

        // Emotion layer.
        var shapes: (RigEyeShape, RigEyeShape)
        switch c.emotion {
        case .neutral: shapes = (.normal, .normal)
        case .happy: shapes = (.smile, .smile); targetY -= 0.02; sy += 0.02
        case .excited: shapes = (.star, .star); sy += 0.03 + max(0, sin(time * 9)) * 0.05 * amp
        case .love: shapes = (.heart, .heart)
        case .curious: shapes = (.big, .normal); leanT += 0.08; turnT = 0.25
        case .thinking: shapes = (.narrow, .normal); leanT -= 0.05
        case .focused: shapes = (.narrow, .narrow); round = max(round, 2.8)
        case .sad: shapes = (.sad, .sad); targetY += 0.05; sy -= 0.04; sx += 0.03; gaze.y = max(gaze.y, 0.45)
        case .surprised: shapes = (.big, .big); sy += 0.06; sx -= 0.04
        case .confused: shapes = (.asymmetric, .normal); leanT += 0.12
        case .sleepy: shapes = (.narrow, .narrow); targetY += 0.03; leanT += sin(time * 0.6) * 0.05
        case .dizzy: shapes = (.cross, .cross); leanT += sin(time * 5) * 0.05
        case .proud: shapes = (.smile, .smile); sy += 0.04; leanT -= 0.04
        case .shy: shapes = (.smile, .smile); gaze = CGPoint(x: gaze.x * 0.3 + 0.5, y: 0.6)
        }
        if c.mode == .error { shapes = (.cross, .cross) }
        if c.mode == .success, c.emotion == .neutral { shapes = (.star, .star) }
        if let o = c.eyeOverride { shapes = (o.left, o.right) }
        dots.target = c.mode == .thinking && c.eyeOverride == nil ? 1 : 0

        // Gaze moves eyes across the face, turns the body a little and shifts the light (a 3D read, not a 2D slide).
        gazeX.target = Double(gaze.x); gazeY.target = Double(gaze.y)
        turnT += Double(gaze.x) * 0.35
        targetX += Double(gaze.x) * 0.05 * amp
        targetY += Double(gaze.y) * 0.03 * amp
        leanT += Double(gaze.x) * 0.05 * amp

        // Actions (anticipation → action → follow-through), layered on top.
        if let act = activeAction {
            let t = time - act.start
            var done = false
            switch act.action {
            case .jump, .bounce:
                let height = act.action == .jump ? 3.6 : 2.6
                if t < 0.16 { sy -= 0.24 * amp; sx += 0.17 * amp }                         // anticipation: crouch
                else if !launched { launched = true; bounces = 0; airborne = true; jumpV = -height * amp }
                else if !airborne {
                    if act.action == .bounce, bounces < 2 { bounces += 1; airborne = true; jumpV = -height * amp * (bounces == 1 ? 0.65 : 0.4) }
                    else if t > 0.5 { done = true }
                }
            case .leanLeft: leanT -= 0.35 * amp * envelope(t, 1.4); targetX -= 0.15 * amp * envelope(t, 1.4); done = t > 1.4
            case .leanRight: leanT += 0.35 * amp * envelope(t, 1.4); targetX += 0.15 * amp * envelope(t, 1.4); done = t > 1.4
            case .peek:
                let e = envelope(t, 2.2)
                targetX += 0.55 * amp * e; leanT += 0.45 * amp * e; gazeX.target = -0.9 * e + gazeX.target * (1 - e); eyeSize += 0.15 * e
                done = t > 2.2
            case .turn:
                turnT += sin(min(1, t / 1.2) * .pi * 2) * 1.0 * amp; done = t > 1.2
            case .nod:
                gazeY.target = 0.6 * sin(min(1, t / 0.9) * .pi * 2); targetY += 0.05 * sin(min(1, t / 0.9) * .pi * 2) * amp; done = t > 0.9
            case .shake:
                turnT += 0.6 * sin(t * 18) * exp(-t * 2.4) * amp; gazeX.target = 0.7 * sin(t * 18) * exp(-t * 2.4); done = t > 1.3
            case .startle:
                if t < 0.08 { sy -= 0.15 } else if t < 0.4 { sy += 0.18 * amp; sx -= 0.12 * amp; eyeSize += 0.35 }
                if t > 0.08 && t < 0.1 { squashY.kick(3 * amp) }
                done = t > 0.9
            case .wiggle:
                leanT += sin(t * 14) * 0.2 * amp * exp(-t * 1.5); sx += sin(t * 14 + 1) * 0.05 * amp; done = t > 1.6
            }
            if done { activeAction = nil; launched = false }
        }

        bx.target = targetX; by.target = targetY
        squashX.target = sx; squashY.target = sy; lean.target = leanT; roundness.target = round; turn.target = turnT
        light.target = lightT
        eyeSpacing.target = spacing
        applyEyes(shapes, size: eyeSize)

        // Accent colour and hue by emotion (on top of the brand blue-white).
        let (accentT, color): (Double, UIColor) = {
            switch (c.mode, c.emotion) {
            case (.error, _), (_, .dizzy): return (0.55, UIColor(red: 1, green: 0.35, blue: 0.35, alpha: 1))
            case (.success, _), (_, .excited), (_, .proud): return (0.5, UIColor(red: 1, green: 0.82, blue: 0.3, alpha: 1))
            case (_, .love), (_, .shy): return (0.5, UIColor(red: 1, green: 0.45, blue: 0.65, alpha: 1))
            case (_, .happy): return (0.35, UIColor(red: 1, green: 0.75, blue: 0.45, alpha: 1))
            case (_, .sad): return (0.35, UIColor(red: 0.45, green: 0.5, blue: 0.75, alpha: 1))
            case (_, .curious), (_, .confused): return (0.35, UIColor(red: 0.65, green: 0.45, blue: 1, alpha: 1))
            case (.working, _): return (0.3, UIColor(red: 0.3, green: 0.95, blue: 0.85, alpha: 1))
            default: return (0, UIColor.clear)
            }
        }()
        accentAmount.target = accentT * c.glow
        if accentT > 0 { accentColor = color }
        hue.target = c.hueShift

        // Blinks: random intervals, sometimes double; none while eyes are symbols.
        if blinkPhase < 0, time >= nextBlink {
            blinkPhase = 0; doubleBlink = rand(0...1) < 0.2
            nextBlink = time + rand(1.8...5.5) * (c.mode == .listening ? 1.4 : 1)
        }
        if blinkPhase >= 0 {
            blinkPhase += dt / 0.18
            blink = sin(min(1, blinkPhase) * .pi)
            if blinkPhase >= 1 { if doubleBlink { doubleBlink = false; blinkPhase = 0 } else { blinkPhase = -1; blink = 0 } }
        }
    }

    private func envelope(_ t: Double, _ total: Double) -> Double {
        // Ease in, hold, ease out: anticipation and release are left to the springs.
        let a = min(1, t / 0.25), b = min(1, max(0, (total - t) / 0.35))
        return min(a, b)
    }

    private func onModeChange(from: RigMode, to: RigMode) {
        switch to {
        case .attentive: controller.perform(.startle); squashY.kick(1.5)
        case .interrupted: controller.perform(.startle)
        case .success: controller.perform(.jump)
        case .error: controller.perform(.shake)
        case .listening: squashY.kick(1.2); lean.kick(-0.6)
        case .speaking: squashX.kick(0.8)
        case .thinking: gazeY.kick(-2)
        case .working: turn.kick(1.5)
        case .idle: break
        }
    }

    private func applyEyes(_ shapes: (RigEyeShape, RigEyeShape), size: Double) {
        for (i, shape) in [shapes.0, shapes.1].enumerated() {
            var e = eyes[i]
            var w = 1.0, h = 1.35, n = 3.4, rot = 0.0, star = 0.0, heart = 0.0, cross = 0.0, lid = 0.0, tilt = 0.0, smile = 0.0
            switch shape {
            case .normal: break
            case .big: w = 1.25; h = 1.65; n = 2.4
            case .narrow: lid = 0.55; w = 1.1
            case .smile: smile = 0.55; w = 1.2; h = 1.3; n = 2.2
            case .wink: if i == 1 { smile = 0.62; lid = 0.3; h = 1.1 } else { w = 1.05 }
            case .star: star = 1; w = 1.5; h = 1.5
            case .heart: heart = 1; w = 1.45; h = 1.45
            case .cross: cross = 1; w = 1.2; h = 1.2
            case .sad: lid = 0.35; tilt = i == 0 ? 0.32 : -0.32; h = 1.2; rot = i == 0 ? -0.15 : 0.15
            case .asymmetric: if i == 0 { w = 1.3; h = 1.75; n = 2.3 } else { lid = 0.45; w = 0.9; h = 1.0 }
            }
            e.width.target = w * size; e.height.target = h * size; e.roundness.target = n; e.rotation.target = rot
            e.star.target = star; e.heart.target = heart; e.cross.target = cross
            e.lidTop.target = lid; e.lidTilt.target = tilt; e.smile.target = smile
            eyes[i] = e
        }
    }

    private func integrate(_ dt: Double, _ c: CompanionRigController) {
        let r = c.springResponse, d = c.springDamping
        // Several substeps keep stiff springs stable at low frame rates.
        let steps = max(1, Int(ceil(dt / (1.0 / 120))))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            bx.step(h, response: r * 1.1, damping: d + 0.15); by.step(h, response: r * 1.1, damping: d + 0.15)
            squashX.step(h, response: r * 0.55, damping: d * 0.6); squashY.step(h, response: r * 0.55, damping: d * 0.6)
            lean.step(h, response: r, damping: d); roundness.step(h, response: r * 1.4, damping: 1)
            turn.step(h, response: r * 0.9, damping: d + 0.1)
            gazeX.step(h, response: r * 0.45, damping: 0.85); gazeY.step(h, response: r * 0.45, damping: 0.85)
            light.step(h, response: r * 1.2, damping: 1); accentAmount.step(h, response: 0.6, damping: 1); hue.step(h, response: 0.5, damping: 1)
            eyeSpacing.step(h, response: r, damping: d)
            dots.step(h, response: r * 1.1, damping: 0.8)
            for i in eyes.indices { eyes[i].step(h, response: r, damping: d) }
            // Jump physics: gravity in the air, a squash impulse on landing (elastic recovery comes from the springs).
            if airborne {
                jumpV += 14 * h
                jumpY += jumpV * h
                if jumpY >= 0 {
                    jumpY = 0; airborne = false
                    squashY.kick(-min(6, abs(jumpV) * 1.4)); squashX.kick(min(5, abs(jumpV) * 1.1))
                    jumpV = 0
                }
            }
        }
    }

    // MARK: draw

    override func layoutSubviews() { super.layoutSubviews() }

    private func draw(_ c: CompanionRigController) {
        let side = min(bounds.width, bounds.height)
        guard side > 1 else { return }
        let R = side * (c.compact ? 0.42 : 0.33)
        let ground = CGPoint(x: bounds.midX, y: bounds.midY + (c.compact ? 0 : R * 0.15))
        // Velocity-driven stretch: the body elongates along its motion (inertia) and recovers through the springs.
        let vx = (bx.value - prevBx) * 60, vy = (by.value - prevBy) * 60 + jumpV * (airborne ? 0.6 : 0)
        prevBx = bx.value; prevBy = by.value
        let speedStretch = min(0.18, sqrt(vx * vx + vy * vy) * 0.05) * c.amplitude
        let motionAngle = atan2(vy, vx)
        let sx = max(0.6, squashX.value), sy = max(0.6, squashY.value)
        let rot = lean.value
        let tilt = turn.value
        let center = CGPoint(x: ground.x + CGFloat(bx.value) * R, y: ground.y + CGFloat(by.value + jumpY) * R)

        func transform(_ p: CGPoint) -> CGPoint {
            // p in units of R around the body centre (y down). Squash anchored at the bottom when grounded.
            var x = Double(p.x), y = Double(p.y)
            let anchor = airborne ? 0.0 : 1.0
            x *= sx; y = (y - anchor) * sy + anchor
            // turn: the side facing away compresses (fake 3D yaw)
            x *= 1 - abs(tilt) * 0.08 + (x * tilt > 0 ? 0 : 0) ; x += tilt * 0.06 * (1 - y * y)
            if speedStretch > 0.001 {
                let ca = cos(motionAngle), sa = sin(motionAngle)
                let along = x * ca + y * sa, across = -x * sa + y * ca
                let a2 = along * (1 + speedStretch), c2 = across / (1 + speedStretch)
                x = a2 * ca - c2 * sa; y = a2 * sa + c2 * ca
            }
            let rx = x * cos(rot) - y * sin(rot), ry = x * sin(rot) + y * cos(rot)
            return CGPoint(x: center.x + CGFloat(rx) * R, y: center.y + CGFloat(ry) * R)
        }

        // Silhouette: superellipse (circle ↔ soft rounded square) with a slight organic wobble.
        let path = CGMutablePath()
        let n = roundness.value
        let samples = 96
        for k in 0..<samples {
            let a = Double(k) / Double(samples) * 2 * .pi
            var r = EyeGeometry.superellipse(a, w: 1, h: 1, n: n)
            r *= 1 + sin(a * 3 + time * 1.3) * 0.006 * c.amplitude + sin(a * 2 - time * 0.9) * 0.005 * c.amplitude
            let p = transform(CGPoint(x: cos(a) * r, y: sin(a) * r))
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()

        CATransaction.begin(); CATransaction.setDisableActions(true)
        let box = path.boundingBoxOfPath.insetBy(dx: -2, dy: -2)
        body.frame = bounds
        bodyMask.frame = bounds; bodyMask.path = path
        rim.path = path
        rim.strokeColor = UIColor(white: 1, alpha: 0.35).cgColor

        // Brand palette (sky / depth / mist), hue-shiftable, with the accent mixed in as a moving inner glow.
        let sky = Self.shift(UIColor(red: 0.26, green: 0.66, blue: 0.99, alpha: 1), hue.value)
        let depth = Self.shift(UIColor(red: 0.13, green: 0.43, blue: 0.93, alpha: 1), hue.value)
        let lightness = light.value
        base.frame = box
        base.colors = [sky.cgColor, depth.cgColor, UIColor(red: 0.62 + lightness * 0.1, green: 0.84, blue: 1, alpha: 1).cgColor]
        base.locations = [0, 0.55, 1]
        // Interior lights move with the body: they lag behind motion (parallax), follow the lean and the gaze.
        let w = box.width, hgt = box.height
        let lagX = CGFloat(-vx * 0.04 - tilt * 0.12 + gazeX.value * 0.05) * w
        let lagY = CGFloat(-vy * 0.04) * hgt
        mist.frame = CGRect(x: box.minX - w * 0.45 + lagX, y: box.minY + hgt * (0.55 - lightness * 0.05) + lagY, width: w * 1.5, height: hgt * 0.9)
        mist.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(rot * 0.8 - 0.35)))
        deep.colors = [depth.withAlphaComponent(0.55).cgColor, depth.withAlphaComponent(0).cgColor]
        deep.frame = CGRect(x: box.maxX - w * 0.7 - lagX * 0.6, y: box.minY - hgt * 0.15, width: w * 0.9, height: hgt * 0.8)
        accent.colors = [accentColor.withAlphaComponent(CGFloat(min(0.85, accentAmount.value))).cgColor, accentColor.withAlphaComponent(0).cgColor]
        accent.frame = CGRect(x: box.midX - w * 0.55 + lagX * 1.2, y: box.minY + hgt * 0.25 + lagY, width: w * 1.1, height: hgt * 0.95)
        let hx = box.minX + w * (0.18 + gazeX.value * 0.06) - lagX * 0.5
        let hy = box.minY + hgt * (0.08 + gazeY.value * 0.04) - lagY * 0.5
        highlight.frame = CGRect(x: hx, y: hy, width: w * 0.42, height: hgt * 0.3)
        highlight.opacity = 0

        // Eyes: positioned on the face plane, which moves further than the body (parallax) in the gaze direction.
        let gx = gazeX.value, gy = gazeY.value
        let faceCenter = transform(CGPoint(x: gx * 0.34 + tilt * 0.18, y: -0.1 + gy * 0.3))
        let spacing = R * 0.27 * CGFloat(eyeSpacing.value) * CGFloat(1 - abs(tilt) * 0.12 - abs(gx) * 0.06)
        let eyeUnit = R * 0.2
        let dot = min(1, max(0, dots.value))
        let dotGap = R * 0.24
        // Sequential pulse: each dot swells and brightens in turn (left → middle → right), then all rest briefly.
        func pulse(_ index: Int) -> Double {
            let phase = (time - Double(index) * 0.22).truncatingRemainder(dividingBy: 1.35) / 1.35
            return phase < 0 ? 0 : (phase < 0.4 ? sin(phase / 0.4 * .pi) : 0)
        }
        let dotRadius = eyeUnit * 0.34
        let dotOrder = [0, 2]   // left eye = first dot, right eye = third dot
        for i in 0..<2 {
            let side: CGFloat = i == 0 ? -1 : 1
            // Perspective: the eye on the side we look toward gets slightly narrower.
            let squash = CGPoint(x: max(0, Double(side) * gx) * 0.18 + abs(tilt) * 0.05, y: max(0, gy) * 0.08)
            let symbolic = eyes[i].star.value + eyes[i].heart.value + eyes[i].cross.value
            let pts = eyes[i].points(blink: symbolic > 0.5 || dot > 0.5 ? 0 : blink, gazeSquash: squash)
            let eyeSpan = spacing * CGFloat(1 - dot) + dotGap * CGFloat(dot)
            let c0 = CGPoint(x: faceCenter.x + side * eyeSpan * CGFloat(cos(rot)) + CGFloat(eyes[i].x.value) * eyeUnit,
                             y: faceCenter.y + side * eyeSpan * CGFloat(sin(rot)) + CGFloat(eyes[i].y.value) * eyeUnit + CGFloat(dot) * R * 0.06)
            let p = pulse(dotOrder[i])
            let circleR = Double(dotRadius) * (1 + 0.28 * p)
            let eye = CGMutablePath()
            for (k, pt) in pts.enumerated() {
                // Morph point-for-point from the eye outline to a round dot (same sample angles).
                let a = EyeGeometry.angles[k]
                let ex = Double(pt.x) * Double(eyeUnit) * Double(sx), ey = Double(pt.y) * Double(eyeUnit) * Double(sy)
                let mx = ex * (1 - dot) + cos(a) * circleR * dot, my = ey * (1 - dot) + sin(a) * circleR * dot
                let rx = mx * cos(rot) - my * sin(rot), ry = mx * sin(rot) + my * cos(rot)
                let q = CGPoint(x: c0.x + CGFloat(rx), y: c0.y + CGFloat(ry))
                if k == 0 { eye.move(to: q) } else { eye.addLine(to: q) }
            }
            eye.closeSubpath()
            eyeLayers[i].path = eye
            let tint = eyes[i].heart.value
            eyeLayers[i].fillColor = UIColor(red: 1, green: 1 - 0.45 * tint, blue: 1 - 0.3 * tint, alpha: 1).cgColor
            eyeLayers[i].opacity = Float(1 - dot * (0.32 - 0.32 * p))
        }
        // Middle dot.
        let pm = pulse(1)
        let mr = dotRadius * CGFloat(dot) * CGFloat(1 + 0.28 * pm)
        let mc = CGPoint(x: faceCenter.x, y: faceCenter.y + CGFloat(dot) * R * 0.06)
        middleDot.path = mr > 0.2 ? CGPath(ellipseIn: CGRect(x: mc.x - mr, y: mc.y - mr, width: mr * 2, height: mr * 2), transform: nil) : nil
        middleDot.opacity = Float(dot * (0.68 + 0.32 * pm))
        CATransaction.commit()
    }

    private static func shift(_ color: UIColor, _ amount: Double) -> UIColor {
        guard amount != 0 else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        var nh = h + CGFloat(amount)
        nh -= floor(nh)
        return UIColor(hue: nh, saturation: s, brightness: b, alpha: a)
    }
}

// MARK: - Production host

/// Feeds the rig from real runtime state. Runtime truth decides the mode (what the character is doing); the reply's
/// expression and any explicit performance only colour it. Levels are the real microphone / playback meters.
struct CompanionRigHost: UIViewRepresentable {
    var phase: VoicePhase
    var level: Double
    var speechLevel: Double
    var emotion: VoiceEmotion
    var performance: CharacterPerformance?
    var active: Bool

    func makeCoordinator() -> CompanionRigController { CompanionRigController() }
    func makeUIView(context: Context) -> CompanionRigView { CompanionRigView(controller: context.coordinator) }
    func updateUIView(_ view: CompanionRigView, context: Context) {
        let c = context.coordinator
        c.compact = view.bounds.width > 0 && view.bounds.width < 90
        c.amplitude = c.compact ? 0.55 : 1
        c.speed = active ? 1 : 0
        c.inputLevel = phase == .listening ? level : 0
        c.outputLevel = phase == .speaking ? speechLevel : 0
        c.mode = switch phase {
        case .idle: .idle
        case .preparing: .attentive
        case .listening: .listening
        case .finalizing, .thinking, .confirming: .thinking
        case .synthesizing: .thinking
        case .speaking: .speaking
        case .interrupted: .interrupted
        case .failed: .error
        }
        var e: RigEmotion = switch emotion {
        case .neutral: .neutral
        case .happy: .happy
        case .calm: .neutral
        case .sad: .sad
        case .curious: .curious
        case .serious: .focused
        }
        if let performance {
            e = switch performance {
            case .delight, .laugh, .amazed: .excited
            case .reassure, .encourage: .happy
            case .puzzled, .question, .skeptical: .confused
            case .surprise: .surprised
            case .disappointed: .sad
            case .drowsy: .sleepy
            case .blocked: .dizzy
            case .think, .ponder: .thinking
            case .focus, .confident: .focused
            case .playful: .proud
            case .shy: .shy
            default: e
            }
        }
        c.emotion = e
        c.gazeOverride = nil
        c.followsSignals = true
    }
    static func dismantleUIView(_ view: CompanionRigView, coordinator: CompanionRigController) { view.stop() }
}
