import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AgentRuntime
import MLX
import MLXProvider

/// Writes a 1600×1200 JPEG: white background, a red circle on the left, a blue square on the right.
func makeShapesImage() throws -> URL {
    let w = 1600, h = 1200
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 150, y: 300, width: 600, height: 600))
    ctx.setFillColor(CGColor(red: 0.05, green: 0.2, blue: 0.95, alpha: 1)); ctx.fill(CGRect(x: 950, y: 350, width: 500, height: 500))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("italk-shapes-\(UUID()).jpg")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    return url
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["ITALK_MODEL_DIR"] != nil))
func realLocalVisionUnderstandsAnImage() async throws {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ITALK_MODEL_DIR"]!)
    let art = ModelArtifact(id: dir.lastPathComponent, displayName: "", version: "t", license: "", baseModelLicense: "", files: [],
                            residentBytes: 0, kvBytesPerToken: 0, contextTokens: 4096, maxAutonomy: .chatOnly, autonomySource: "test")
    let provider = MLXModelProvider(artifact: art, directory: dir, vision: true)
    let t0 = ContinuousClock.now
    try await provider.prepare { _ in }
    let load = (ContinuousClock.now - t0).secs
    let img = try makeShapesImage()
    let prompt = ProcessInfo.processInfo.environment["ITALK_VISION_PROMPT"] ?? "描述这张图片。"
    let pixels = Int(ProcessInfo.processInfo.environment["ITALK_VISION_PX"] ?? "1600") ?? 1600
    let msg = ModelMessage(role: .user, text: prompt, images: [ModelImage(attachmentId: UUID(), filePath: img.path, pixelWidth: pixels, pixelHeight: pixels * 3 / 4)])
    var text = "", usage: Usage?
    let t1 = ContinuousClock.now
    for try await e in provider.generate(GenerationRequest(messages: [msg], maxTokens: 80, temperature: 0.2)) {
        switch e { case .textDelta(let d): text += d; if ProcessInfo.processInfo.environment["ITALK_VISION_RAW"] != nil { print("CHUNK:", d.debugDescription) }; case .usage(let u): usage = u; default: break }
    }
    let total = (ContinuousClock.now - t1).secs
    // Text-only follow-up through the same VLM-loaded model must still work.
    var plain = ""
    for try await e in provider.generate(GenerationRequest(messages: [.init(role: .user, text: "用一句话介绍上海。")], maxTokens: 40)) { if case .textDelta(let d) = e { plain += d } }
    print("VISION:", ["model": dir.lastPathComponent, "loadSeconds": String(format: "%.2f", load), "answer": text,
                      "firstTokenSeconds": String(format: "%.2f", usage?.firstTokenLatency ?? -1), "totalSeconds": String(format: "%.2f", total),
                      "promptTokens": "\(usage?.promptTokens ?? -1)", "peakMB": String(format: "%.0f", Double(Memory.peakMemory) / 1e6), "textAfter": plain])
    #expect(text.contains("红") && (text.contains("蓝") || text.contains("藍")), "answer: \(text)")
    #expect(text.contains("圆") || text.contains("圓"))
    #expect(text != prompt, "model echoed the prompt")
    #expect(!plain.isEmpty)
    await provider.unload()
}
