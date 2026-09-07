#!/usr/bin/env swift
import AppKit
import Foundation

// Hot Mic's artwork is drawn natively so every raster derivative comes from the
// same geometry. Run with: swift scripts/generate_brand_assets.swift

private let iconCanvas: CGFloat = 1024

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 255) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha / 255)
}

private func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Unable to create bitmap")
    }
    representation.size = NSSize(width: width, height: height)
    return representation
}

private func renderPNG(width: Int, height: Int, pointSize: NSSize? = nil, draw: (CGContext) -> Void) -> Data {
    let representation = bitmap(width: width, height: height)
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
        fatalError("Unable to create graphics context")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }

    let context = graphicsContext.cgContext
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    draw(context)
    // Draw in native pixel coordinates, then encode the intended logical size
    // as 144 DPI for Finder's 2× 660×420 background.
    representation.size = pointSize ?? NSSize(width: width, height: height)

    guard let data = representation.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode PNG")
    }
    return data
}

private func fill(_ context: CGContext, _ path: CGPath, _ paint: NSColor) {
    context.addPath(path)
    context.setFillColor(paint.cgColor)
    context.fillPath()
}

private func stroke(_ context: CGContext, _ path: CGPath, _ paint: NSColor, width: CGFloat, lineCap: CGLineCap = .round) {
    context.addPath(path)
    context.setStrokeColor(paint.cgColor)
    context.setLineWidth(width)
    context.setLineCap(lineCap)
    context.setLineJoin(.round)
    context.strokePath()
}

private func fillGradient(_ context: CGContext, path: CGPath, from: NSColor, to: NSColor, start: CGPoint, end: CGPoint) {
    guard let gradient = CGGradient(
        colorsSpace: NSColorSpace.sRGB.cgColorSpace,
        colors: [from.cgColor, to.cgColor] as CFArray,
        locations: [0, 1]
    ) else {
        fatalError("Unable to create gradient")
    }
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
    context.restoreGState()
}

private func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

private func ellipse(_ rect: CGRect) -> CGPath {
    CGPath(ellipseIn: rect, transform: nil)
}

private func drawIcon(in context: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / iconCanvas
    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    defer { context.restoreGState() }

    let frame = CGRect(x: 26, y: 26, width: 972, height: 972)
    let framePath = roundedRect(frame, 214)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0, 0, 0, 75).cgColor)
    fillGradient(context, path: framePath, from: color(34, 37, 42), to: color(12, 14, 17), start: CGPoint(x: 124, y: 1000), end: CGPoint(x: 920, y: 0))
    context.restoreGState()

    // Warm inset creates an unmistakable, readable silhouette at 16 px.
    let inset = CGRect(x: 90, y: 90, width: 844, height: 844)
    let insetPath = roundedRect(inset, 174)
    fillGradient(context, path: insetPath, from: color(255, 246, 227), to: color(235, 218, 185), start: CGPoint(x: 280, y: 900), end: CGPoint(x: 760, y: 100))

    let ring = roundedRect(CGRect(x: 118, y: 118, width: 788, height: 788), 148)
    stroke(context, ring, color(255, 255, 255, 135), width: 14)

    // An isolated record-light badge remains distinct from the microphone body
    // at 16–64 px, making the companion mark feel intentional rather than busy.
    fill(context, ellipse(CGRect(x: 700, y: 684, width: 92, height: 92)), color(194, 36, 46))
    fill(context, ellipse(CGRect(x: 728, y: 712, width: 36, height: 36)), color(255, 246, 227))

    let micBody = roundedRect(CGRect(x: 432, y: 424, width: 210, height: 300), 105)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 14, color: color(83, 12, 18, 100).cgColor)
    fillGradient(context, path: micBody, from: color(244, 84, 76), to: color(174, 21, 35), start: CGPoint(x: 462, y: 736), end: CGPoint(x: 620, y: 396))
    context.restoreGState()

    let micHighlight = roundedRect(CGRect(x: 466, y: 464, width: 28, height: 190), 14)
    fill(context, micHighlight, color(255, 219, 194, 110))

    let cradle = CGMutablePath()
    cradle.move(to: CGPoint(x: 382, y: 546))
    cradle.addCurve(to: CGPoint(x: 537, y: 342), control1: CGPoint(x: 382, y: 410), control2: CGPoint(x: 450, y: 342))
    cradle.addCurve(to: CGPoint(x: 692, y: 546), control1: CGPoint(x: 624, y: 342), control2: CGPoint(x: 692, y: 410))
    stroke(context, cradle, color(35, 38, 43), width: 38)

    let stem = CGMutablePath()
    stem.move(to: CGPoint(x: 537, y: 342))
    stem.addLine(to: CGPoint(x: 537, y: 263))
    stroke(context, stem, color(35, 38, 43), width: 38)
    stroke(context, CGPath(roundedRect: CGRect(x: 414, y: 232, width: 246, height: 40), cornerWidth: 20, cornerHeight: 20, transform: nil), color(35, 38, 43), width: 26)
}

private func drawText(_ value: String, in rect: CGRect, font: NSFont, color textColor: NSColor, alignment: NSTextAlignment = .left, kern: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineBreakMode = .byClipping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: textColor,
        .paragraphStyle: style,
        .kern: kern
    ]
    NSString(string: value).draw(in: rect, withAttributes: attributes)
}

private func drawInstallerBackground(in context: CGContext) {
    let width: CGFloat = 1320
    let height: CGFloat = 840
    let background = CGRect(x: 0, y: 0, width: width, height: height)
    fillGradient(context, path: CGPath(rect: background, transform: nil), from: color(27, 29, 33), to: color(13, 15, 18), start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0))

    // A restrained warm glow keeps the drag target legible on both light and dark desktops.
    let glow = CGGradient(
        colorsSpace: NSColorSpace.sRGB.cgColorSpace,
        colors: [color(209, 56, 60, 58).cgColor, color(209, 56, 60, 0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 650, y: 440), startRadius: 0, endCenter: CGPoint(x: 650, y: 440), endRadius: 450, options: [])

    // Header and rule.
    drawText("Hot Mic", in: CGRect(x: 92, y: 650, width: 700, height: 112), font: NSFont.systemFont(ofSize: 76, weight: .bold), color: color(255, 246, 229), kern: -2)
    drawText("FOR THE RECORD", in: CGRect(x: 98, y: 614, width: 430, height: 32), font: NSFont.systemFont(ofSize: 18, weight: .semibold), color: color(243, 97, 91), kern: 4)
    context.setFillColor(color(255, 246, 229, 38).cgColor)
    context.fill(CGRect(x: 96, y: 578, width: 1128, height: 2))

    // The arrow aligns with Finder's two 96-point icon centers (y=210 in a
    // 660×420 logical window); keeping the field open avoids visual collisions.
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 556, y: 420))
    arrow.addLine(to: CGPoint(x: 756, y: 420))
    stroke(context, arrow, color(249, 243, 231, 235), width: 12)
    let arrowhead = CGMutablePath()
    arrowhead.move(to: CGPoint(x: 724, y: 460))
    arrowhead.addLine(to: CGPoint(x: 764, y: 420))
    arrowhead.addLine(to: CGPoint(x: 724, y: 380))
    stroke(context, arrowhead, color(249, 243, 231, 235), width: 12)

    drawText("Drag Hot Mic to Applications", in: CGRect(x: 200, y: 104, width: 920, height: 42), font: NSFont.systemFont(ofSize: 26, weight: .semibold), color: color(255, 246, 229), alignment: .center)
    drawText("macOS 14.0+", in: CGRect(x: 200, y: 66, width: 920, height: 28), font: NSFont.systemFont(ofSize: 17, weight: .regular), color: color(255, 246, 229, 112), alignment: .center, kern: 1)
}

private func rootURL() -> URL {
    let arguments = CommandLine.arguments.dropFirst()
    if arguments.count == 2, arguments.first == "--root" {
        return URL(fileURLWithPath: arguments[arguments.index(after: arguments.startIndex)], isDirectory: true)
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
}

private func removeGeneratedAppleDouble(in directory: URL) throws {
    let manager = FileManager.default
    let contents = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
    for item in contents where item.lastPathComponent.hasPrefix("._") {
        try manager.removeItem(at: item)
    }
}

private func clearExtendedAttributes(from outputs: [URL]) throws {
    for output in outputs {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-c", output.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "HotMicArtwork", code: Int(task.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Unable to clear extended attributes from generated output \(output.path)"
            ])
        }
    }
}

private func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
}

let root = rootURL()
let appIcon = root.appendingPathComponent("Dictation/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let installerBackground = root.appendingPathComponent("Resources/InstallerBackground.png")
let manager = FileManager.default
try manager.createDirectory(at: appIcon, withIntermediateDirectories: true)

let iconImages: [(name: String, pixels: Int, idiom: String, size: String, scale: String)] = [
    ("HotMic_16.png", 16, "mac", "16x16", "1x"),
    ("HotMic_16@2x.png", 32, "mac", "16x16", "2x"),
    ("HotMic_32.png", 32, "mac", "32x32", "1x"),
    ("HotMic_32@2x.png", 64, "mac", "32x32", "2x"),
    ("HotMic_128.png", 128, "mac", "128x128", "1x"),
    ("HotMic_128@2x.png", 256, "mac", "128x128", "2x"),
    ("HotMic_256.png", 256, "mac", "256x256", "1x"),
    ("HotMic_256@2x.png", 512, "mac", "256x256", "2x"),
    ("HotMic_512.png", 512, "mac", "512x512", "1x"),
    ("HotMic_512@2x.png", 1024, "mac", "512x512", "2x")
]
let iconOutputs = iconImages.map { appIcon.appendingPathComponent($0.name) }


for image in iconImages {
    try write(renderPNG(width: image.pixels, height: image.pixels) { context in
        drawIcon(in: context, pixels: image.pixels)
    }, to: appIcon.appendingPathComponent(image.name))
}

let imageEntries = iconImages.map { image in
    """
        {\n          \"filename\" : \"\(image.name)\",\n          \"idiom\" : \"\(image.idiom)\",\n          \"scale\" : \"\(image.scale)\",\n          \"size\" : \"\(image.size)\"\n        }
    """
}.joined(separator: ",\n")
let contents = """
{
  \"images\" : [
\(imageEntries)
  ],
  \"info\" : {
    \"author\" : \"xcode\",
    \"version\" : 1
  }
}
"""
try write(contents.data(using: .utf8)!, to: appIcon.appendingPathComponent("Contents.json"))

try write(renderPNG(width: 1320, height: 840, pointSize: NSSize(width: 660, height: 420), draw: drawInstallerBackground), to: installerBackground)
let generatedOutputs = iconOutputs + [appIcon.appendingPathComponent("Contents.json"), installerBackground]
try clearExtendedAttributes(from: generatedOutputs)
try removeGeneratedAppleDouble(in: appIcon)
for output in generatedOutputs {
    let sidecar = output.deletingLastPathComponent().appendingPathComponent("._\(output.lastPathComponent)")
    if manager.fileExists(atPath: sidecar.path) {
        try manager.removeItem(at: sidecar)
    }
}

print("Generated \(appIcon.path) and \(installerBackground.path)")
