#!/usr/bin/env swift
//
// generate_icon.swift: Programmatically render JeepNet's macOS app icon —
// a cartoon off-road RC jeep (side profile, no face) climbing a dirt mound —
// filling the squircle edge-to-edge for Tahoe and later.
//
// Usage: xcrun swift JeepNetApp/Scripts/generate_icon.swift [preview.png]
//

import AppKit

let canvas: CGFloat = 1024
let squircleRadius: CGFloat = canvas * 0.2237

func color(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// Palette
let skyTop = color(0x2FA9E8)
let skyBottom = color(0xBFE9FB)
let hillFar = color(0x7CB342)
let hillNear = color(0x558B2F)
let dirtDark = color(0x6D4C41)
let dirt = color(0x8D6E63)
let dirtLight = color(0xA1887F)
let dust = color(0xD7CCC8)
let bodyColor = color(0xFF6D2D)
let bodyShade = color(0xD84315)
let bodyHighlight = color(0xFF9E66)
let cage = color(0x263238)
let tire = color(0x1E1E1E)
let tread = color(0x3A3A3A)
let hub = color(0xECEFF1)
let hubShade = color(0x90A4AE)
let glass = color(0xB3E5FC, 0.85)
let antennaBall = color(0xFFD600)
let white = color(0xFFFFFF)

func rounded(_ rect: NSRect, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
}

func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
}

func drawWheel(at cx: CGFloat, _ cy: CGFloat, radius: CGFloat, rotation: CGFloat) {
    // Tire with chunky tread blocks
    tire.setFill()
    circle(cx, cy, radius).fill()
    let blockCount = 14
    for i in 0..<blockCount {
        let angle = rotation + CGFloat(i) / CGFloat(blockCount) * 2 * .pi
        let block = NSBezierPath(roundedRect: NSRect(x: -radius * 0.14, y: radius * 0.72, width: radius * 0.28, height: radius * 0.30), xRadius: 8, yRadius: 8)
        var t = AffineTransform(translationByX: cx, byY: cy)
        t.rotate(byRadians: angle)
        block.transform(using: t)
        tread.setFill()
        block.fill()
    }
    // Rim and hub
    hubShade.setFill()
    circle(cx, cy, radius * 0.52).fill()
    hub.setFill()
    circle(cx, cy, radius * 0.44).fill()
    // Five spokes
    for i in 0..<5 {
        let angle = rotation + CGFloat(i) / 5 * 2 * .pi
        let spoke = NSBezierPath(roundedRect: NSRect(x: -radius * 0.07, y: 0, width: radius * 0.14, height: radius * 0.40), xRadius: 6, yRadius: 6)
        var t = AffineTransform(translationByX: cx, byY: cy)
        t.rotate(byRadians: angle)
        spoke.transform(using: t)
        hubShade.setFill()
        spoke.fill()
    }
    cage.setFill()
    circle(cx, cy, radius * 0.10).fill()
}

func drawJeep(in context: CGContext) {
    // Local coordinates: origin at the jeep's centre; the whole jeep is
    // rotated nose-up to read as climbing.
    context.saveGState()
    context.translateBy(x: canvas * 0.50, y: canvas * 0.44)
    context.rotate(by: 13 * .pi / 180)

    let wheelR: CGFloat = 108
    let rearWheel = NSPoint(x: -185, y: -60)
    let frontWheel = NSPoint(x: 195, y: -60)

    // Drop shadow under the body
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x000000, 0.35).cgColor)
    bodyColor.setFill()
    rounded(NSRect(x: -300, y: -30, width: 600, height: 150), 34).fill()
    context.restoreGState()

    // Spare tire on the tailgate (behind the body)
    tire.setFill()
    circle(-318, 62, 62).fill()
    hubShade.setFill()
    circle(-318, 62, 28).fill()
    cage.setFill()
    circle(-318, 62, 9).fill()

    // Suspension links
    cage.setStroke()
    for wheel in [rearWheel, frontWheel] {
        let link = NSBezierPath()
        link.move(to: NSPoint(x: wheel.x - 40, y: 10))
        link.line(to: NSPoint(x: wheel.x, y: wheel.y))
        link.line(to: NSPoint(x: wheel.x + 40, y: 10))
        link.lineWidth = 16
        link.lineCapStyle = .round
        link.stroke()
    }

    // Main body (tub)
    bodyColor.setFill()
    rounded(NSRect(x: -300, y: -30, width: 600, height: 150), 34).fill()
    // Lower body shade
    bodyShade.setFill()
    rounded(NSRect(x: -300, y: -30, width: 600, height: 44), 22).fill()
    // Hood highlight
    bodyHighlight.setFill()
    rounded(NSRect(x: 60, y: 92, width: 220, height: 20), 10).fill()

    // Wheel arches (cut-outs drawn in sky-ish dark to suggest openings)
    for wheel in [rearWheel, frontWheel] {
        cage.setFill()
        let arch = NSBezierPath()
        arch.appendArc(withCenter: NSPoint(x: wheel.x, y: 10), radius: wheelR * 0.98, startAngle: 0, endAngle: 180)
        arch.close()
        arch.fill()
        // Fender lip
        bodyShade.setFill()
        let lip = NSBezierPath()
        lip.appendArc(withCenter: NSPoint(x: wheel.x, y: 10), radius: wheelR * 1.10, startAngle: 0, endAngle: 180)
        lip.appendArc(withCenter: NSPoint(x: wheel.x, y: 10), radius: wheelR * 0.98, startAngle: 180, endAngle: 0, clockwise: true)
        lip.close()
        lip.fill()
    }

    // Front bumper and winch
    cage.setFill()
    rounded(NSRect(x: 292, y: -12, width: 46, height: 60), 12).fill()
    rounded(NSRect(x: -336, y: -12, width: 46, height: 60), 12).fill()
    hubShade.setFill()
    rounded(NSRect(x: 306, y: 4, width: 22, height: 28), 8).fill()

    // Cab: roll cage with windshield
    cage.setStroke()
    let bar = NSBezierPath()
    bar.move(to: NSPoint(x: -230, y: 110))
    bar.line(to: NSPoint(x: -210, y: 250))
    bar.line(to: NSPoint(x: 20, y: 250))
    bar.line(to: NSPoint(x: 70, y: 110))
    bar.lineWidth = 26
    bar.lineJoinStyle = .round
    bar.lineCapStyle = .round
    bar.stroke()
    // Cross bar
    let cross = NSBezierPath()
    cross.move(to: NSPoint(x: -100, y: 118))
    cross.line(to: NSPoint(x: -95, y: 250))
    cross.lineWidth = 18
    cross.lineCapStyle = .round
    cross.stroke()

    // Windshield
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 70, y: 115))
    shield.line(to: NSPoint(x: 20, y: 240))
    shield.line(to: NSPoint(x: 120, y: 240))
    shield.line(to: NSPoint(x: 150, y: 115))
    shield.close()
    glass.setFill()
    shield.fill()
    cage.setStroke()
    shield.lineWidth = 22
    shield.lineJoinStyle = .round
    shield.stroke()
    // Glare on the glass
    white.withAlphaComponent(0.55).setStroke()
    let glare = NSBezierPath()
    glare.move(to: NSPoint(x: 62, y: 150))
    glare.line(to: NSPoint(x: 48, y: 200))
    glare.lineWidth = 10
    glare.lineCapStyle = .round
    glare.stroke()

    // Seats (headrests peeking above the tub)
    cage.setFill()
    rounded(NSRect(x: -190, y: 110, width: 60, height: 60), 18).fill()
    rounded(NSRect(x: -60, y: 110, width: 60, height: 60), 18).fill()

    // RC whip antenna with a ball on top
    cage.setStroke()
    let antenna = NSBezierPath()
    antenna.move(to: NSPoint(x: -150, y: 250))
    antenna.curve(to: NSPoint(x: -90, y: 470), controlPoint1: NSPoint(x: -160, y: 340), controlPoint2: NSPoint(x: -120, y: 420))
    antenna.lineWidth = 9
    antenna.lineCapStyle = .round
    antenna.stroke()
    antennaBall.setFill()
    circle(-88, 476, 24).fill()
    bodyShade.setFill()
    circle(-150, 250, 14).fill()

    // Wheels last so they overlap the arches
    drawWheel(at: rearWheel.x, rearWheel.y, radius: wheelR, rotation: 0.3)
    drawWheel(at: frontWheel.x, frontWheel.y, radius: wheelR, rotation: 1.1)

    context.restoreGState()
}

func drawIcon(in context: CGContext) {
    let rect = NSRect(x: 0, y: 0, width: canvas, height: canvas)

    // Squircle filling the canvas edge-to-edge (Tahoe style)
    NSBezierPath(roundedRect: rect, xRadius: squircleRadius, yRadius: squircleRadius).addClip()

    // Sky
    NSGradient(colors: [skyBottom, skyTop])?.draw(in: rect, angle: 90)

    // Sun
    white.withAlphaComponent(0.85).setFill()
    circle(canvas * 0.80, canvas * 0.80, 70).fill()

    // Distant hills
    hillFar.setFill()
    let far = NSBezierPath()
    far.move(to: NSPoint(x: -50, y: 300))
    far.curve(to: NSPoint(x: 420, y: 420), controlPoint1: NSPoint(x: 120, y: 470), controlPoint2: NSPoint(x: 260, y: 470))
    far.curve(to: NSPoint(x: 1080, y: 330), controlPoint1: NSPoint(x: 620, y: 360), controlPoint2: NSPoint(x: 860, y: 520))
    far.line(to: NSPoint(x: 1080, y: -10))
    far.line(to: NSPoint(x: -50, y: -10))
    far.close()
    far.fill()

    hillNear.setFill()
    let near = NSBezierPath()
    near.move(to: NSPoint(x: -50, y: 240))
    near.curve(to: NSPoint(x: 560, y: 300), controlPoint1: NSPoint(x: 200, y: 380), controlPoint2: NSPoint(x: 380, y: 380))
    near.curve(to: NSPoint(x: 1080, y: 250), controlPoint1: NSPoint(x: 760, y: 220), controlPoint2: NSPoint(x: 920, y: 350))
    near.line(to: NSPoint(x: 1080, y: -10))
    near.line(to: NSPoint(x: -50, y: -10))
    near.close()
    near.fill()

    // Dirt mound the jeep is climbing
    dirt.setFill()
    let mound = NSBezierPath()
    mound.move(to: NSPoint(x: -50, y: 150))
    mound.curve(to: NSPoint(x: 560, y: 400), controlPoint1: NSPoint(x: 150, y: 190), controlPoint2: NSPoint(x: 380, y: 370))
    mound.curve(to: NSPoint(x: 1080, y: 230), controlPoint1: NSPoint(x: 760, y: 430), controlPoint2: NSPoint(x: 940, y: 280))
    mound.line(to: NSPoint(x: 1080, y: -10))
    mound.line(to: NSPoint(x: -50, y: -10))
    mound.close()
    mound.fill()
    // Lighter crest
    dirtLight.setFill()
    let crest = NSBezierPath()
    crest.move(to: NSPoint(x: 140, y: 200))
    crest.curve(to: NSPoint(x: 560, y: 400), controlPoint1: NSPoint(x: 320, y: 250), controlPoint2: NSPoint(x: 430, y: 370))
    crest.curve(to: NSPoint(x: 940, y: 290), controlPoint1: NSPoint(x: 720, y: 420), controlPoint2: NSPoint(x: 840, y: 310))
    crest.curve(to: NSPoint(x: 140, y: 200), controlPoint1: NSPoint(x: 740, y: 350), controlPoint2: NSPoint(x: 330, y: 300))
    crest.close()
    crest.fill()
    // Dark ground base
    dirtDark.setFill()
    NSBezierPath(rect: NSRect(x: -50, y: -10, width: 1130, height: 90)).fill()

    // Dust kicked up behind the rear wheel
    for (i, puff) in [(200.0, 330.0, 72.0), (130.0, 380.0, 54.0), (110.0, 290.0, 46.0), (270.0, 290.0, 42.0)].enumerated() {
        dust.withAlphaComponent(0.85 - CGFloat(i) * 0.12).setFill()
        circle(CGFloat(puff.0), CGFloat(puff.1), CGFloat(puff.2)).fill()
    }

    drawJeep(in: context)

    // Dust in front of the rear wheel (drawn over the jeep for depth)
    dust.withAlphaComponent(0.6).setFill()
    circle(250, 250, 46).fill()
    circle(320, 225, 30).fill()
}

func renderImage(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.scaleBy(x: size / canvas, y: size / canvas)
        drawIcon(in: ctx)
    }
    img.unlockFocus()
    return img
}

func savePNG(image: NSImage, path: String) throws {
    guard let tiffData = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiffData),
          let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to render PNG"])
    }
    try pngData.write(to: URL(fileURLWithPath: path))
}

let fileManager = FileManager.default
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
let rootDir = (scriptDir as NSString).deletingLastPathComponent
let resourcesDir = (rootDir as NSString).appendingPathComponent("Sources/JeepNet/Resources")
try? fileManager.createDirectory(atPath: resourcesDir, withIntermediateDirectories: true)

if CommandLine.arguments.count > 1 {
    let previewPath = CommandLine.arguments[1]
    let img = renderImage(size: 1024)
    try savePNG(image: img, path: previewPath)
    print("✓ Saved icon preview to \(previewPath)")
} else {
    let iconsetDir = (resourcesDir as NSString).appendingPathComponent("AppIcon.iconset")
    try? fileManager.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

    let sizes: [(Int, Int, String)] = [
        (16, 1, "icon_16x16.png"),
        (16, 2, "icon_16x16@2x.png"),
        (32, 1, "icon_32x32.png"),
        (32, 2, "icon_32x32@2x.png"),
        (128, 1, "icon_128x128.png"),
        (128, 2, "icon_128x128@2x.png"),
        (256, 1, "icon_256x256.png"),
        (256, 2, "icon_256x256@2x.png"),
        (512, 1, "icon_512x512.png"),
        (512, 2, "icon_512x512@2x.png")
    ]

    for (pt, scale, filename) in sizes {
        let px = pt * scale
        let img = renderImage(size: CGFloat(px))
        let path = (iconsetDir as NSString).appendingPathComponent(filename)
        try savePNG(image: img, path: path)
    }

    let icnsPath = (resourcesDir as NSString).appendingPathComponent("AppIcon.icns")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
    try process.run()
    process.waitUntilExit()

    try? fileManager.removeItem(atPath: iconsetDir)
    print("✓ Generated \(icnsPath) filling squircle for Tahoe and later")
}
