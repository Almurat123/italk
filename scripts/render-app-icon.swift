import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// CONTEXT MEMORY
// Updated: 2026-11-01
// Status: inferred
// Why: The static home-screen icon follows the app's blue and white companion without copying its animation.
// Debug Goal: Preserve the full-bleed square companion and rounded-square white eyes at small icon sizes.
// Search Tags: italk app icon square blue white orb rounded square eyes
// Invariants:
// - The 1024-pixel app icon is opaque; iOS applies its own rounded-square mask.
// - Source artwork and the in-app companion animation stay independent.
// Failure Modes:
// - Transparent icon pixels or baking in a rounded-square mask cause App Store validation issues.
let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("Unable to create icon context") }
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}
func gradient(_ colors: [CGColor], _ stops: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: stops)!
}
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)
context.drawLinearGradient(gradient([color(0.25, 0.65, 0.98), color(0.14, 0.46, 0.95), color(0.50, 0.73, 0.97)], [0, 0.60, 1]),
                           start: CGPoint(x: 370, y: 0), end: CGPoint(x: 690, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
let cloud = CGMutablePath()
cloud.move(to: CGPoint(x: -100, y: 240))
cloud.addCurve(to: CGPoint(x: 510, y: 620), control1: CGPoint(x: 210, y: 385), control2: CGPoint(x: 310, y: 585))
cloud.addCurve(to: CGPoint(x: 1124, y: 480), control1: CGPoint(x: 675, y: 710), control2: CGPoint(x: 900, y: 510))
cloud.addLine(to: CGPoint(x: 1124, y: 1200))
cloud.addLine(to: CGPoint(x: -100, y: 1200))
cloud.closeSubpath()
guard let cloudContext = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                   space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Unable to create cloud context") }
cloudContext.translateBy(x: 0, y: CGFloat(size))
cloudContext.scaleBy(x: 1, y: -1)
cloudContext.addPath(cloud)
cloudContext.clip()
cloudContext.drawLinearGradient(gradient([color(1, 1, 1), color(0.82, 0.91, 1), color(0.72, 0.84, 0.98)], [0, 0.54, 1]),
                                start: CGPoint(x: 180, y: 360), end: CGPoint(x: 720, y: 950), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
guard let cloudImage = cloudContext.makeImage() else { fatalError("Unable to render cloud") }
let extent = CGRect(x: 0, y: 0, width: size, height: size)
let blurredCloud = CIImage(cgImage: cloudImage).clampedToExtent()
    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 35]).cropped(to: extent)
guard let softened = CIContext(options: [.workingColorSpace: colorSpace]).createCGImage(blurredCloud, from: extent) else { fatalError("Unable to soften cloud") }
context.saveGState()
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)
context.draw(softened, in: extent)
context.restoreGState()
context.setFillColor(color(1, 1, 1))
for x in [CGFloat(535), CGFloat(655)] {
    context.addPath(CGPath(roundedRect: CGRect(x: x, y: 365, width: 72, height: 76), cornerWidth: 21, cornerHeight: 21, transform: nil))
    context.fillPath()
}
guard let source = context.makeImage(), (2...3).contains(CommandLine.arguments.count) else { fatalError("Usage: render-app-icon.swift <output.png> [circle]") }
var image = source
if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "circle" {
    guard let circle = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("Unable to create circular icon") }
    circle.setFillColor(color(0.949, 0.973, 1))
    circle.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let bounds = CGRect(x: 80, y: 80, width: 864, height: 864)
    circle.addEllipse(in: bounds)
    circle.clip()
    circle.draw(source, in: bounds)
    guard let roundImage = circle.makeImage() else { fatalError("Unable to render circular icon") }
    image = roundImage
}
guard
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Usage: render-app-icon.swift <output.png>")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Unable to save icon") }
