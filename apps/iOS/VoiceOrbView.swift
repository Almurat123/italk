import SwiftUI
import AssistantCore
import CoreImage

enum CharacterPerformance: String, CaseIterable {
    case rest, listen, think, puzzled, surprise, delight, reassure, disappointed, speak, playful, drowsy, confident, blocked
    case explain, question, laugh, encourage, attentive, ponder, amazed, focus, shy, skeptical
    var title: String {
        switch self {
        case .rest: "自然回看"
        case .listen: "专注倾听"
        case .think: "思考中"
        case .puzzled: "疑惑"
        case .surprise: "惊讶"
        case .delight: "开心"
        case .reassure: "安慰"
        case .disappointed: "低落"
        case .speak: "讲述"
        case .playful: "俏皮"
        case .drowsy: "困倦"
        case .confident: "认真"
        case .blocked: "受阻"
        case .explain: "展开讲述"
        case .question: "追问"
        case .laugh: "开怀"
        case .encourage: "鼓励"
        case .attentive: "侧耳听"
        case .ponder: "斟酌"
        case .amazed: "惊喜"
        case .focus: "专注"
        case .shy: "含蓄"
        case .skeptical: "将信将疑"
        }
    }
    var previewPhase: VoicePhase {
        switch self {
        case .rest, .drowsy: .idle
        case .listen, .attentive: .listening
        case .think, .puzzled, .ponder: .thinking
        case .blocked: .failed
        default: .speaking
        }
    }
    var note: String {
        switch self {
        case .rest: "轻轻呼吸，目光短暂游移后回到你这里。"
        case .listen: "微微侧转，眼睛抬起，随声音轻轻回应。"
        case .think: "目光稍稍抬起，球内云流缓慢回旋。"
        case .puzzled: "两只眼睛不对称地倾斜，停下来等你。"
        case .surprise: "眼睛伸长，球内云流轻轻涌起。"
        case .delight: "眼睛弯起，球内流动变得轻快。"
        case .reassure: "眼睛放松，球内流动慢下来。"
        case .disappointed: "眼睛低垂，球内流动变得低缓。"
        case .speak: "白色眼睛保留，蓝白液体随实际语音轻轻涌动。"
        case .playful: "一只眼睛眨起，目光轻轻侧倾。"
        case .drowsy: "眼睛慢慢合起，呼吸放缓。"
        case .confident: "目光平稳，轮廓变成柔和方圆形。"
        case .blocked: "眼神停下来，球内流动放缓，等待你处理。"
        case .explain: "变成柔和长方形，侧身展开讲述。"
        case .question: "变成圆角菱形，一只眼睛抬起等待回答。"
        case .laugh: "笑眼展开，轮廓变成轻盈云朵。"
        case .encourage: "眼睛明亮，五角星轮廓舒展开来。"
        case .attentive: "明显侧倾靠近，目光跟随你的声音。"
        case .ponder: "轮廓收成圆角三角形，抬眼斟酌。"
        case .amazed: "五角星轮廓与睁大的眼睛一起表达惊喜。"
        case .focus: "轮廓变成圆角长方形，目光保持专注。"
        case .shy: "水滴轮廓微微侧转，眼神柔和。"
        case .skeptical: "一大一小的眼睛和倾斜轮廓表达疑问。"
        }
    }
    var previewEmotion: VoiceEmotion {
        switch self {
        case .delight, .playful, .laugh, .encourage, .amazed: .happy
        case .reassure, .shy: .calm
        case .disappointed: .sad
        case .puzzled, .surprise, .question, .skeptical: .curious
        case .confident, .focus: .serious
        default: .neutral
        }
    }
    static func resolve(_ phase: VoicePhase, _ emotion: VoiceEmotion) -> Self {
        switch phase {
        case .idle, .interrupted: .rest
        case .preparing, .listening: .listen
        case .thinking, .finalizing, .synthesizing: .think
        case .confirming: .puzzled
        case .failed: .blocked
        case .speaking:
            switch emotion {
            case .neutral: .speak
            case .happy: .delight
            case .calm: .reassure
            case .sad: .disappointed
            case .curious: .surprise
            case .serious: .confident
            }
        }
    }
}

struct VoiceOrbView: View {
    var phase: VoicePhase
    var level: Double
    var speechBeat = 0
    var speechLevel = 0.0
    var emotion = VoiceEmotion.neutral
    var emphasis = 0.35
    var epoch = Date.now
    var isStatic = false
    var performanceOverride: CharacterPerformance?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private var quiet: Bool { reduceMotion || isStatic }
    private var performance: CharacterPerformance { performanceOverride ?? .resolve(phase, emotion) }

    // CONTEXT MEMORY
    // Updated: 2026-10-27
    // Status: mixed
    // Why: The Canvas loop was capped at 24/30 Hz and rebuilt five blurred layers per frame.
    // Debug Goal: Keep larger geometric acting fluid without invalidating SwiftUI every frame.
    // Search Tags: orb circle square listening thinking speaking phase transition
    // Invariants:
    // - Only circle and rounded square are active; phase changes interpolate the same native layers.
    // - Clouds are clipped to the body; the upper blue field stays clear for the eyes.
    // - Liquid textures are cached once; eyes and masks use native vector layers.
    // - Compact avatars enlarge eyes continuously; expression widths and eye spacing scale together.
    // - Flow speed is integrated, never calculated as elapsed time times a changing rate.
    // - Meters drive a damped envelope; sentence emotion sets the acting pose.
    // - Listening and thinking hold their pose; speaking expressions follow phrase emotion, not a timer deck.
    // - Header and full-screen presentation share the renderer and clock.
    // Failure Modes:
    // - Resetting time on a phase change makes the liquid jump backwards.
    // - Reduced Motion and inactive scenes must not advance the flow or blinking.
    var body: some View {
        Group {
            // The spring-driven companion rig (CompanionRig.swift) is the live character; the layer orb stays for static icons
            // and Reduce Motion.
            if quiet {
                OrbLayerSurface(input: OrbRenderInput(phase: phase, level: level, speechBeat: speechBeat,
                    speechLevel: speechLevel, emotion: emotion, emphasis: emphasis, epoch: epoch,
                    quiet: quiet, active: scenePhase == .active, performanceOverride: performanceOverride))
            } else {
                CompanionRigHost(phase: phase, level: level, speechLevel: speechLevel, emotion: emotion, performance: performanceOverride,
                                 active: scenePhase == .active)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("iTalk 语音角色")
        .accessibilityValue("\(phase.label)，\(emotion.label)，\(performance.title)")
        .accessibilityIdentifier("assistant.orb")
    }
}

private struct OrbPose {
    var rotation = 0.0, scaleX = 1.0, scaleY = 1.0
    var faceX = 0.10, faceY = -0.14, spacing = 0.11
    var leftHeight = 0.055, rightHeight = 0.055, leftAngle = 0.0, rightAngle = 0.0
    var leftCurve = 0.0, rightCurve = 0.0
    var roundness = 0.0, taper = 0.0
    var offsetX = 0.0, offsetY = 0.0
    var leftWidth = 0.052, rightWidth = 0.052
    var shapes = OrbShape.circle.weights

    static func make(_ state: CharacterPerformance, time t: Double, audio: Double, speech: Double, emphasis: Double, quiet: Bool) -> Self {
        var p = Self()
        let gaze = quiet ? CharacterGaze.Point(x: 0, y: 0) : CharacterGaze.sample(at: t)
        let accent = emphasis.isFinite ? min(1, max(0, emphasis)) : 0.35
        p.faceX += gaze.x * 0.035; p.faceY += gaze.y * 0.025
        switch state {
        case .rest: break
        case .listen:
            p.roundness = 0.16; p.taper = 0.025; p.rotation = -2
            p.faceX = 0.11 + gaze.x * 0.04; p.faceY = -0.16
            p.leftHeight = 0.065 + audio * 0.008; p.rightHeight = 0.058 + audio * 0.006
            p.scaleX = 1 - audio * 0.012; p.scaleY = 1 + audio * 0.012
        case .think:
            p.roundness = 0.38; p.rotation = -3
            p.faceX = 0.14; p.faceY = -0.18
            p.leftHeight = 0.05; p.rightHeight = 0.035
        case .puzzled:
            p.roundness = 0.30; p.taper = 0.075; p.rotation = 5
            p.faceX = 0.09; p.faceY = -0.16
            p.leftAngle = 7; p.rightAngle = -5
            p.leftHeight = 0.040; p.rightHeight = 0.073
        case .surprise:
            p.roundness = 0.24; p.taper = 0.08; p.rotation = 4
            p.faceX = 0.10; p.faceY = -0.17; p.leftAngle = -5; p.rightAngle = 4
            p.leftHeight = 0.065 + accent * 0.018; p.rightHeight = 0.054
            p.scaleX = 0.98; p.scaleY = 1.025
        case .delight:
            p.roundness = 0.55 + accent * 0.15; p.taper = 0.015; p.rotation = -3
            p.faceX = 0.10; p.faceY = -0.14
            p.leftHeight = 0.025; p.rightHeight = 0.025; p.leftCurve = -0.04; p.rightCurve = -0.04
            p.scaleX = 1.035; p.scaleY = 0.975
        case .reassure:
            p.roundness = 0.10; p.rotation = -2
            p.faceX = 0.10; p.faceY = -0.14
            p.leftHeight = 0.036; p.rightHeight = 0.038
            p.scaleX = 1.02; p.scaleY = 0.99
        case .disappointed:
            p.roundness = 0.18; p.taper = -0.08
            p.faceX = 0.08; p.faceY = -0.12
            p.leftHeight = 0.03; p.rightHeight = 0.03; p.leftAngle = -7; p.rightAngle = 7
            p.scaleX = 0.98; p.scaleY = 1.02
        case .speak:
            p.roundness = 0.22 + accent * 0.12
            p.faceX = 0.10 + gaze.x * 0.025; p.faceY = -0.14
            p.leftHeight = 0.055 + accent * 0.007; p.rightHeight = 0.05
            p.scaleX = 1 + speech * 0.012; p.scaleY = 1 - speech * 0.008
        case .playful:
            p.roundness = 0.65; p.taper = 0.04; p.rotation = -6
            p.faceX = 0.10; p.faceY = -0.14
            p.leftHeight = 0.012; p.rightAngle = -4
        case .drowsy:
            p.faceX = 0.10; p.faceY = -0.13
            p.leftHeight = 0.015; p.rightHeight = 0.015; p.leftAngle = 0; p.rightAngle = 0
        case .confident:
            p.roundness = 0.90; p.faceX = 0.10; p.faceY = -0.14
            p.leftHeight = 0.037; p.rightHeight = 0.037
        case .blocked:
            p.roundness = 0.40; p.faceX = 0.10; p.faceY = -0.14
            p.leftHeight = 0.025; p.rightHeight = 0.045; p.leftAngle = 4; p.rightAngle = -4
        case .explain:
            p.rotation = -10; p.scaleX = 1.08; p.scaleY = 1.03
            p.faceX = 0.08; p.faceY = -0.09; p.leftHeight = 0.068; p.rightHeight = 0.048
            p.offsetX = -0.022
        case .question:
            p.rotation = 12; p.faceX = 0.04; p.faceY = -0.12
            p.leftHeight = 0.082; p.rightHeight = 0.035; p.rightAngle = -12
        case .laugh:
            p.rotation = -8; p.scaleX = 1.06; p.scaleY = 0.98
            p.faceX = 0.04; p.faceY = -0.07; p.spacing = 0.14
            p.leftCurve = -0.06; p.rightCurve = -0.06; p.leftHeight = 0.02; p.rightHeight = 0.02
        case .encourage:
            p.rotation = -9; p.faceX = 0.025; p.faceY = -0.07
            p.leftHeight = 0.066; p.rightHeight = 0.066; p.leftWidth = 0.065; p.rightWidth = 0.065
        case .attentive:
            p.rotation = -14; p.offsetX = -0.028; p.faceX = 0.02; p.faceY = -0.12
            p.scaleX = 0.95; p.scaleY = 1.08; p.leftHeight = 0.083; p.rightHeight = 0.062
        case .ponder:
            p.rotation = 9; p.faceX = 0.025; p.faceY = -0.07
            p.leftHeight = 0.035; p.rightHeight = 0.057; p.leftAngle = 12
        case .amazed:
            p.rotation = 8; p.faceX = 0.02; p.faceY = -0.07
            p.leftHeight = 0.085; p.rightHeight = 0.085; p.leftWidth = 0.064; p.rightWidth = 0.064
        case .focus:
            p.scaleX = 1.10; p.faceX = 0.08; p.faceY = -0.09
            p.leftHeight = 0.027; p.rightHeight = 0.027; p.leftWidth = 0.069; p.rightWidth = 0.069
        case .shy:
            p.rotation = 13; p.offsetX = 0.025; p.faceX = 0.015; p.faceY = -0.08
            p.leftHeight = 0.035; p.rightHeight = 0.035; p.spacing = 0.09
        case .skeptical:
            p.rotation = -12; p.faceX = 0.025; p.faceY = -0.09
            p.leftHeight = 0.025; p.rightHeight = 0.077; p.leftAngle = -14; p.rightAngle = 5
        }
        let shape: OrbShape = switch state {
        case .rest, .listen, .attentive, .drowsy, .reassure: .circle
        default: .squircle
        }
        p.shapes = shape.weights
        if shape == .star { p.faceX *= 0.4; p.faceY *= 0.5; p.rotation += 6 }
        if shape == .triangle { p.faceX *= 0.3; p.faceY *= 0.3; p.spacing *= 0.9 }
        return p
    }

    func blended(_ n: Self, fraction f: Double) -> Self {
        func m(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
        return Self(rotation: m(rotation,n.rotation), scaleX: m(scaleX,n.scaleX), scaleY: m(scaleY,n.scaleY),
                    faceX: m(faceX,n.faceX), faceY: m(faceY,n.faceY), spacing: m(spacing,n.spacing),
                    leftHeight: m(leftHeight,n.leftHeight), rightHeight: m(rightHeight,n.rightHeight),
                    leftAngle: m(leftAngle,n.leftAngle), rightAngle: m(rightAngle,n.rightAngle),
                    leftCurve: m(leftCurve,n.leftCurve), rightCurve: m(rightCurve,n.rightCurve),
                    roundness: m(roundness,n.roundness), taper: m(taper,n.taper),
                    offsetX: m(offsetX,n.offsetX), offsetY: m(offsetY,n.offsetY),
                    leftWidth: m(leftWidth,n.leftWidth), rightWidth: m(rightWidth,n.rightWidth),
                    shapes: shapes + (n.shapes - shapes) * f)
    }
}

private enum OrbShape: Int, CaseIterable {
    case circle, squircle, rectangle, star, triangle, diamond, drop, cloud
    var weights: SIMD8<Double> { var value = SIMD8<Double>(repeating: 0); value[rawValue] = 1; return value }
}

private enum OrbActingDirector {
    static func performance(_ input: OrbRenderInput, elapsed: Double) -> CharacterPerformance {
        if let override = input.performanceOverride { return override }
        switch input.phase {
        case .preparing, .listening: return .listen
        case .thinking, .synthesizing, .finalizing: return .think
        case .speaking: return .resolve(.speaking, input.emotion)
        default: return .resolve(input.phase, input.emotion)
        }
    }
}

private enum LiquidCharacter {
    static func draw(context: inout GraphicsContext, size: CGSize, pose p: OrbPose, palette: LiquidPalette,
                     flow: Double, drive: Double, time: Double, quiet: Bool) {
        let side = min(size.width, size.height)
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: .degrees(p.rotation))
        context.scaleBy(x: p.scaleX, y: p.scaleY)
        let diameter = side * 0.8814
        let body = bodyPath(diameter: diameter, shapes: p.shapes)
        context.clip(to: body)
        LiquidField.draw(context: &context, diameter: diameter, palette: palette, time: flow, drive: drive)

        context.scaleBy(x: side * 1.13, y: side * 1.13)
        let opening = quiet ? 1 : blinkOpening(time)
        for index in 0..<2 {
            var eye = context
            let left = index == 0
            eye.translateBy(x: p.faceX + (left ? -p.spacing / 2 : p.spacing / 2), y: p.faceY)
            eye.rotate(by: .degrees(left ? p.leftAngle : p.rightAngle))
            eye.scaleBy(x: 1, y: max(0.06, opening))
            let height = left ? p.leftHeight : p.rightHeight
            let curve = left ? p.leftCurve : p.rightCurve
            let bend = min(1, abs(curve) / 0.04)
            var capsule = eye; capsule.opacity *= 1 - bend
            capsule.fill(Path(roundedRect: CGRect(x: -0.026, y: -height / 2, width: 0.052, height: height),
                              cornerRadius: min(0.014, height * 0.28)), with: .color(.white))
            var curved = eye; curved.opacity *= bend
            var path = Path()
            path.move(to: CGPoint(x: -0.028, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0.028, y: 0), control: CGPoint(x: 0, y: curve))
            curved.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 0.018, lineCap: .round))
        }
    }
    private static let contours: [[CGPoint]] = OrbShape.allCases.map { shape in
        (0..<80).map { index in
            let angle = Double(index) / 80 * .pi * 2 - .pi / 2
            let c = cos(angle), s = sin(angle)
            func power(_ value: Double, _ exponent: Double) -> Double { (value < 0 ? -1 : 1) * pow(abs(value), exponent) }
            switch shape {
            case .circle: return CGPoint(x: c * 0.5, y: s * 0.5)
            case .squircle: return CGPoint(x: power(c, 0.52) * 0.49, y: power(s, 0.52) * 0.49)
            case .rectangle: return CGPoint(x: power(c, 0.42) * 0.5, y: power(s, 0.42) * 0.34)
            case .diamond: return CGPoint(x: power(c, 1.6) * 0.54, y: power(s, 1.6) * 0.54)
            case .drop: return CGPoint(x: c * 0.46 * (1 + 0.30 * s), y: s * 0.52)
            case .cloud:
                let radius = 0.45 + 0.045 * cos(angle * 5) + 0.016 * sin(angle * 3)
                return CGPoint(x: c * radius, y: s * radius * 0.94)
            case .star, .triangle:
                let count = shape == .star ? 10 : 3
                var radius = 0.5
                for edge in 0..<count {
                    func vertex(_ k: Int) -> (Double, Double) {
                        let a = Double(k) / Double(count) * .pi * 2 - .pi / 2
                        let r = shape == .star && k % 2 == 1 ? 0.27 : 0.53
                        return (cos(a) * r, sin(a) * r)
                    }
                    let a = vertex(edge), b = vertex((edge + 1) % count)
                    let ex = b.0 - a.0, ey = b.1 - a.1, cross = c * ey - s * ex
                    guard abs(cross) > 0.00001 else { continue }
                    let r = (a.0 * ey - a.1 * ex) / cross
                    let u = (a.0 * s - a.1 * c) / cross
                    if r >= 0, u >= -0.00001, u <= 1.00001 { radius = r; break }
                }
                return CGPoint(x: c * radius, y: s * radius)
            }
        }
    }
    static func bodyPath(diameter: Double, shapes: SIMD8<Double>) -> Path {
        let count = 80
        let points: [CGPoint] = (0..<count).map { index in
            var x = 0.0, y = 0.0
            for shape in OrbShape.allCases where shapes[shape.rawValue] > 0.00001 {
                let point = contours[shape.rawValue][index], weight = shapes[shape.rawValue]
                x += point.x * weight; y += point.y * weight
            }
            return CGPoint(x: x * diameter, y: y * diameter)
        }
        var path = Path(); path.move(to: points[0])
        for index in 0..<count {
            let a = points[(index + count - 1) % count], b = points[index]
            let c = points[(index + 1) % count], d = points[(index + 2) % count]
            path.addCurve(to: c, control1: CGPoint(x: b.x + (c.x - a.x) / 6, y: b.y + (c.y - a.y) / 6),
                          control2: CGPoint(x: c.x - (d.x - b.x) / 6, y: c.y - (d.y - b.y) / 6))
        }
        path.closeSubpath(); return path
    }
    static func blinkOpening(_ time: Double) -> Double {
        let t = time.truncatingRemainder(dividingBy: 13.7)
        let a = max(0, 1 - abs(t - 3.3) / 0.11)
        let b = max(0, 1 - abs(t - 9.1) / 0.10)
        let c = max(0, 1 - abs(t - 9.36) / 0.085) * 0.88
        return 1 - max(a, max(b, c)) * 0.97
    }
}

private struct LiquidPalette {
    var skyRGB: SIMD3<Double>
    var depthRGB: SIMD3<Double>
    var mistRGB: SIMD3<Double>
    var sky: Color { Self.color(skyRGB) }
    var depth: Color { Self.color(depthRGB) }
    var mist: Color { Self.color(mistRGB) }
    private static func color(_ rgb: SIMD3<Double>) -> Color { Color(red: rgb.x, green: rgb.y, blue: rgb.z) }
    func blended(_ other: Self, fraction f: Double) -> Self {
        Self(skyRGB: skyRGB + (other.skyRGB - skyRGB) * f,
             depthRGB: depthRGB + (other.depthRGB - depthRGB) * f,
             mistRGB: mistRGB + (other.mistRGB - mistRGB) * f)
    }

    private static func tones(_ emotion: VoiceEmotion) -> [(Double, Double, Double)] {
        switch emotion {
        case .neutral: [(0.26, 0.66, 0.99), (0.17, 0.49, 0.95), (0.82, 0.94, 1)]
        case .happy: [(0.91, 0.34, 0.28), (0.85, 0.25, 0.40), (1, 0.89, 0.83)]
        case .calm: [(0.08, 0.60, 0.56), (0.06, 0.48, 0.55), (0.82, 0.97, 0.92)]
        case .sad: [(0.40, 0.48, 0.68), (0.29, 0.35, 0.58), (0.86, 0.90, 0.98)]
        case .curious: [(0.59, 0.40, 0.90), (0.43, 0.29, 0.79), (0.94, 0.88, 1)]
        case .serious: [(0.14, 0.38, 0.68), (0.10, 0.27, 0.56), (0.81, 0.90, 0.99)]
        }
    }
    static func mix(_ old: VoiceEmotion, _ new: VoiceEmotion, fraction f: Double) -> Self {
        let a = tones(old), b = tones(new)
        func channels(_ index: Int) -> SIMD3<Double> {
            let x = a[index], y = b[index]
            return SIMD3(x.0 + (y.0 - x.0) * f, x.1 + (y.1 - x.1) * f, x.2 + (y.2 - x.2) * f)
        }
        return Self(skyRGB: channels(0), depthRGB: channels(1), mistRGB: channels(2))
    }
}

private enum LiquidField {
    static func draw(context: inout GraphicsContext, diameter d: Double, palette: LiquidPalette, time t: Double, drive: Double) {
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * d, y: y * d) }
        let bounds = Path(CGRect(x: -d * 0.66, y: -d * 0.66, width: d * 1.32, height: d * 1.32))
        context.fill(bounds, with: .linearGradient(Gradient(stops: [
            .init(color: palette.sky, location: 0), .init(color: palette.depth, location: 0.48),
            .init(color: palette.sky, location: 1)
        ]), startPoint: point(-0.15, -0.5), endPoint: point(0.25, 0.5)))

        let swell = 0.035 + drive * 0.045
        let left = sin(t * 0.83) * swell
        let center = sin(t * 1.07 + 1.1) * swell
        let right = cos(t * 0.71 + 0.7) * swell
        // Three broad feathered currents preserve the large blue area behind the eyes.
        for index in 0..<3 {
            let shift = Double(index) * 0.054
            var cloud = Path()
            cloud.move(to: point(-0.66, -0.22 + left + shift))
            cloud.addCurve(to: point(-0.04 + sin(t * 0.6) * 0.055, 0.14 + center + shift),
                           control1: point(-0.37, -0.34 + left + shift),
                           control2: point(-0.27, 0.06 + center + shift))
            cloud.addCurve(to: point(0.64, -0.01 + right + shift),
                           control1: point(0.25, 0.39 + center + shift),
                           control2: point(0.44, 0.01 + right + shift))
            cloud.addLine(to: point(0.66, 0.65)); cloud.addLine(to: point(-0.66, 0.65)); cloud.closeSubpath()
            context.drawLayer { liquid in
                liquid.addFilter(.blur(radius: d * (index == 0 ? 0.04 : 0.022)))
                liquid.opacity = index == 0 ? 0.7 : (index == 1 ? 0.65 : 0.45)
                liquid.fill(cloud, with: .linearGradient(Gradient(stops: [
                    .init(color: .white, location: 0), .init(color: .white, location: 0.4),
                    .init(color: palette.mist, location: 0.72), .init(color: palette.sky.opacity(0.25), location: 1)
                ]), startPoint: point(-0.23, -0.18 + shift), endPoint: point(0.09, 0.58)))
            }
        }
        var fold = Path()
        fold.move(to: point(-0.59, -0.035 + left))
        fold.addCurve(to: point(0.025, 0.23 + center), control1: point(-0.36, -0.17 + left), control2: point(-0.23, 0.10 + right))
        fold.addCurve(to: point(0.56, -0.005 + right), control1: point(0.23, 0.34 + center), control2: point(0.43, 0.16 + left))
        fold.addCurve(to: point(0.06, 0.31 + center), control1: point(0.43, 0.25 + right), control2: point(0.27, 0.42 + center))
        fold.addCurve(to: point(-0.59, 0.04 + left), control1: point(-0.18, 0.24 + right), control2: point(-0.32, -0.005 + left))
        fold.closeSubpath()
        context.drawLayer { liquid in
            liquid.addFilter(.blur(radius: d * 0.014))
            liquid.fill(fold, with: .linearGradient(Gradient(colors: [.white.opacity(0.12), .white.opacity(0.66), .white.opacity(0)]),
                startPoint: point(-0.40, -0.03), endPoint: point(0.52, 0.19)))
        }
        // A faint return current gives depth without adding filaments or a glass rim.
        var undertow = Path()
        undertow.move(to: point(-0.65, 0.29 + right))
        undertow.addCurve(to: point(0.65, 0.33 + left), control1: point(-0.11, 0.60 + center), control2: point(0.20, 0.16 + right))
        undertow.addLine(to: point(0.65, 0.65)); undertow.addLine(to: point(-0.65, 0.65)); undertow.closeSubpath()
        context.drawLayer { liquid in
            liquid.addFilter(.blur(radius: d * 0.03))
            liquid.fill(undertow, with: .linearGradient(Gradient(colors: [palette.sky.opacity(0.18), palette.mist.opacity(0.7)]),
                startPoint: point(-0.2, 0.28), endPoint: point(0.2, 0.55)))
        }
    }
}

struct BrandAvatar: View {
    var size: CGFloat = 38
    var animates = false
    var body: some View {
        VoiceOrbView(phase: .idle, level: 0, isStatic: !animates).frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct OrbRenderInput {
    var phase: VoicePhase
    var level: Double
    var speechBeat: Int
    var speechLevel: Double
    var emotion: VoiceEmotion
    var emphasis: Double
    var epoch: Date
    var quiet: Bool
    var active: Bool
    var performanceOverride: CharacterPerformance?
}

private struct OrbLayerSurface: UIViewRepresentable {
    var input: OrbRenderInput
    func makeUIView(context: Context) -> OrbLayerView { OrbLayerView(input: input) }
    func updateUIView(_ view: OrbLayerView, context: Context) { view.update(input) }
    static func dismantleUIView(_ view: OrbLayerView, coordinator: ()) { view.stop() }
}

@MainActor private final class OrbDisplayTarget: NSObject {
    weak var view: OrbLayerView?
    @objc func tick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        view.advance(at: link.timestamp)
    }
}

@MainActor private final class OrbLayerView: UIView {
    private var input: OrbRenderInput
    private let art = CALayer(), base = CAGradientLayer(), bodyMask = CAShapeLayer()
    private let clouds = [CALayer(), CALayer(), CALayer()]
    private let eyes = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private let target = OrbDisplayTarget()
    private var link: CADisplayLink?
    private var lastTick = 0.0, actingStarted = CACurrentMediaTime(), wordSpoken = -1000.0
    private var flow = 0.0, drive = 0.0
    private var pose = OrbPose()
    private var palette = LiquidPalette.mix(.neutral, .neutral, fraction: 1)
    #if DEBUG
    private let metrics = OrbFrameMetrics(renderer: "layers-v10")
    #endif

    init(input: OrbRenderInput) {
        self.input = input
        super.init(frame: .zero)
        isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false
        target.view = self
        layer.addSublayer(art); art.mask = bodyMask; art.addSublayer(base)
        base.startPoint = CGPoint(x: 0.35, y: 0); base.endPoint = CGPoint(x: 0.75, y: 1)
        base.locations = [0, 0.48, 1]
        for (index, cloud) in clouds.enumerated() {
            let texture = index == 0 ? 0 : 1
            cloud.contents = OrbCloudTextures.images.indices.contains(texture) ? OrbCloudTextures.images[texture] : nil
            cloud.contentsGravity = .resize; art.addSublayer(cloud)
        }
        for eye in eyes { eye.fillColor = UIColor.white.cgColor; art.addSublayer(eye) }
    }
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() { super.didMoveToWindow(); synchronizeLoop() }
    override func layoutSubviews() { super.layoutSubviews(); drawLayers() }
    func update(_ next: OrbRenderInput) {
        if next.phase != input.phase || next.emotion != input.emotion || next.performanceOverride != input.performanceOverride {
            actingStarted = CACurrentMediaTime()
        }
        if next.speechBeat != input.speechBeat { wordSpoken = CACurrentMediaTime() }
        input = next
        if input.quiet {
            pose = OrbPose.make(input.performanceOverride ?? .resolve(input.phase, input.emotion),
                                time: 0, audio: 0, speech: 0, emphasis: input.emphasis, quiet: true)
            palette = .mix(input.emotion, input.emotion, fraction: 1)
        }
        synchronizeLoop(); drawLayers()
    }
    func stop() { link?.invalidate(); link = nil; lastTick = 0 }
    private func synchronizeLoop() {
        guard window != nil, input.active, !input.quiet else { stop(); return }
        guard link == nil else { return }
        let display = CADisplayLink(target: target, selector: #selector(OrbDisplayTarget.tick(_:)))
        display.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        display.add(to: .main, forMode: .common); link = display; lastTick = 0
    }
    func advance(at now: Double) {
        let dt = lastTick == 0 ? 1.0 / 60 : min(0.05, max(0, now - lastTick)); lastTick = now
        func bounded(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
        let speech = input.phase == .speaking ? max(bounded(input.speechLevel), exp(-max(0, now - wordSpoken) * 8)) : 0
        let audio = input.phase == .listening ? bounded(input.level) : 0
        drive += (max(audio, speech) - drive) * (1 - exp(-dt * 7))
        let acting = OrbActingDirector.performance(input, elapsed: now - actingStarted)
        let time = max(0, Date.now.timeIntervalSince(input.epoch))
        let wanted = OrbPose.make(acting, time: time, audio: audio, speech: drive, emphasis: input.emphasis, quiet: false)
        pose = pose.blended(wanted, fraction: 1 - exp(-dt * 4.5))
        palette = palette.blended(.mix(input.emotion, input.emotion, fraction: 1), fraction: 1 - exp(-dt * 3.5))
        flow += dt * (input.phase == .idle ? 0.34 : 0.78 + drive * 0.65)
        drawLayers()
        #if DEBUG
        if min(bounds.width, bounds.height) > 100 { metrics.sample(at: CACurrentMediaTime()) }
        #endif
    }

    private func drawLayers() {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let d = side * (0.78 + pose.shapes[OrbShape.circle.rawValue] * 0.08), unit = d / 0.78
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        art.bounds = bounds; art.position = CGPoint(x: center.x + pose.offsetX * side, y: center.y + pose.offsetY * side)
        var acting = CATransform3DMakeRotation(pose.rotation * .pi / 180, 0, 0, 1)
        acting = CATransform3DScale(acting, pose.scaleX, pose.scaleY, 1); art.transform = acting
        var translation = CGAffineTransform(translationX: center.x, y: center.y)
        bodyMask.frame = bounds
        bodyMask.path = LiquidCharacter.bodyPath(diameter: d, shapes: pose.shapes).cgPath.copy(using: &translation)
        base.frame = bounds
        base.colors = [Self.cgColor(palette.skyRGB), Self.cgColor(palette.depthRGB), Self.cgColor(palette.mistRGB)]
        let amplitudes = [0.055, 0.09, 0.065]
        for (index, cloud) in clouds.enumerated() {
            cloud.bounds = CGRect(x: 0, y: 0, width: d * 1.5, height: d * 1.5)
            let k = Double(index), direction = index == 1 ? -1.0 : 1.0
            cloud.position = CGPoint(x: center.x + sin(flow * (0.73 + k * 0.17) + k) * d * amplitudes[index],
                                     y: center.y + cos(flow * (0.62 + k * 0.11) + k * 1.4) * d * (0.035 + drive * 0.025))
            var transform = CATransform3DMakeRotation(sin(flow * 0.58 + k) * 0.15 * direction, 0, 0, 1)
            transform = CATransform3DScale(transform, 1.04 + sin(flow * 0.69 + k) * 0.10,
                                          1.0 + cos(flow * 0.57 + k) * 0.10, 1)
            cloud.transform = transform; cloud.opacity = index == 0 ? 0.90 : (index == 1 ? 0.47 : 0.25)
        }
        let time = input.quiet ? 0 : max(0, Date.now.timeIntervalSince(input.epoch))
        let opening = input.quiet ? 1 : LiquidCharacter.blinkOpening(time)
        let shapeGain = 1.12 + pose.shapes[OrbShape.star.rawValue] * 0.20
            + pose.shapes[OrbShape.triangle.rawValue] * 0.14 + pose.shapes[OrbShape.rectangle.rawValue] * 0.08
        // Preserve a readable eye size in small avatars without a threshold jump during resizing.
        let eyeScale = max(shapeGain, min(2.25, 3.6 / (unit * 0.052)))
        let eyeSpacing = pose.spacing * max(1, 0.55 + eyeScale * 0.45)
        for index in 0..<2 {
            eyes[index].frame = bounds; eyes[index + 2].frame = bounds
            let left = index == 0, height = left ? pose.leftHeight : pose.rightHeight
            let width = left ? pose.leftWidth : pose.rightWidth
            let curve = left ? pose.leftCurve : pose.rightCurve
            var transform = CGAffineTransform(translationX: center.x + (pose.faceX + (left ? -eyeSpacing / 2 : eyeSpacing / 2)) * unit,
                                              y: center.y + pose.faceY * unit)
            transform = transform.rotated(by: (left ? pose.leftAngle : pose.rightAngle) * .pi / 180)
                .scaledBy(x: unit * eyeScale, y: unit * eyeScale * max(0.06, opening))
            let rect = UIBezierPath(roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
                                    cornerRadius: min(width * 0.27, height * 0.28))
            eyes[index].path = rect.cgPath.copy(using: &transform)
            let bend = min(1, abs(curve) / 0.04); eyes[index].opacity = Float(1 - bend)
            let arch = UIBezierPath(); arch.move(to: CGPoint(x: -0.032, y: 0))
            arch.addQuadCurve(to: CGPoint(x: 0.032, y: 0), controlPoint: CGPoint(x: 0, y: curve))
            eyes[index + 2].path = arch.cgPath.copy(using: &transform)
            eyes[index + 2].fillColor = nil; eyes[index + 2].strokeColor = UIColor.white.cgColor
            eyes[index + 2].lineWidth = max(1, unit * 0.019 * eyeScale); eyes[index + 2].lineCap = .round
            eyes[index + 2].opacity = Float(bend)
        }
        CATransaction.commit()
    }
    private static func cgColor(_ rgb: SIMD3<Double>) -> CGColor { UIColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1).cgColor }
}

@MainActor private enum OrbCloudTextures {
    // The expensive feathering happens once, never in the display-link loop.
    static let images: [CGImage] = {
        let ci = CIContext(options: [.cacheIntermediates: false])
        return (0..<2).compactMap { index in
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
            let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { renderer in
                let c = renderer.cgContext
                func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (x + 0.75) / 1.5 * 512, y: (y + 0.75) / 1.5 * 512) }
                let path = UIBezierPath(); path.move(to: point(-0.85, index == 0 ? -0.22 : -0.04))
                path.addCurve(to: point(0.02, index == 0 ? 0.14 : 0.24), controlPoint1: point(-0.40, -0.34), controlPoint2: point(-0.24, 0.08))
                path.addCurve(to: point(0.85, -0.06), controlPoint1: point(0.29, 0.38), controlPoint2: point(0.52, 0.03))
                if index == 0 {
                    path.addLine(to: point(0.85, 0.85)); path.addLine(to: point(-0.85, 0.85))
                } else {
                    path.addCurve(to: point(0.08, 0.36), controlPoint1: point(0.63, 0.23), controlPoint2: point(0.32, 0.43))
                    path.addCurve(to: point(-0.85, 0.03), controlPoint1: point(-0.20, 0.23), controlPoint2: point(-0.42, -0.04))
                }
                path.close(); path.addClip()
                let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0.94).cgColor,
                              UIColor.white.withAlphaComponent(0.38).cgColor, UIColor.white.withAlphaComponent(0.02).cgColor]
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.4, 0.75, 1]) {
                    c.drawLinearGradient(gradient, start: point(-0.22, -0.18), end: point(0.12, 0.64), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
            }
            guard let source = CIImage(image: image) else { return image.cgImage }
            return ci.createCGImage(source.applyingGaussianBlur(sigma: index == 0 ? 11 : 6), from: source.extent) ?? image.cgImage
        }
    }()
}

#if DEBUG
@MainActor private final class OrbFrameMetrics {
    private let renderer: String
    private var started = 0.0, last = 0.0
    private var intervals: [Double] = []
    private var reported = false
    init(renderer: String) { self.renderer = renderer }
    func sample(at now: Double) {
        guard ProcessInfo.processInfo.arguments.contains("-orbPerformanceProbe"), !reported else { return }
        if started == 0 { started = now; last = now; return }
        intervals.append(now - last); last = now
        guard now - started >= 10 else { return }
        reported = true
        let sorted = intervals.sorted(), duration = now - started
        let report: [String: Any] = ["renderer": renderer, "durationSeconds": duration,
            "updates": intervals.count, "updateFPS": Double(intervals.count) / duration,
            "p50IntervalMS": sorted[sorted.count / 2] * 1000,
            "p95IntervalMS": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000,
            "intervalsAbove25MS": intervals.filter { $0 > 0.025 }.count,
            "scope": "renderer callback cadence; not displayed-frame or concurrent inference measurement"]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
              let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: directory.appendingPathComponent("orb-metrics-\(renderer).json"), options: .atomic)
    }
}
#endif
