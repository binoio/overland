#!/usr/bin/env swift
//
// generate_icon.swift: Programmatically render GlobalProtect's macOS app icon
// filling the squircle edge-to-edge for Tahoe and later.
//
// Usage: xcrun swift GlobalProtectApp/Scripts/generate_icon.swift [preview.png]
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

let bgTop = color(0x0F172A)
let bgBottom = color(0x020617)
let ringColor = color(0x38BDF8, 0.25)
let shieldLight = color(0xF8FAFC)
let shieldDark = color(0x94A3B8)
let accentGreen = color(0x10B981)
let lockBody = color(0x0F172A)

func drawIcon(in context: CGContext) {
    let rect = NSRect(x: 0, y: 0, width: canvas, height: canvas)

    // Squircle filling canvas edge-to-edge (Tahoe style)
    let squircle = NSBezierPath(
        roundedRect: rect,
        xRadius: squircleRadius,
        yRadius: squircleRadius
    )
    squircle.addClip()

    // Background gradient
    if let gradient = NSGradient(colors: [bgTop, bgBottom]) {
        gradient.draw(in: rect, angle: -90)
    }

    // Concentric globe network rings
    let center = NSPoint(x: canvas / 2, y: canvas / 2)
    for radius: CGFloat in [180, 280, 380, 460] {
        let ringPath = NSBezierPath(
            ovalIn: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        ringPath.lineWidth = 2.0
        ringColor.setStroke()
        ringPath.stroke()
    }

    // Subtle latitude ellipses
    for yOffset: CGFloat in [-160, 0, 160] {
        let latPath = NSBezierPath(
            ovalIn: NSRect(
                x: center.x - 360,
                y: center.y + yOffset - 70,
                width: 720,
                height: 140
            )
        )
        latPath.lineWidth = 1.5
        color(0x38BDF8, 0.15).setStroke()
        latPath.stroke()
    }

    // Shield path
    let shieldPath = NSBezierPath()
    let topY: CGFloat = 800
    let shoulderY: CGFloat = 580
    let bottomY: CGFloat = 200
    let leftX: CGFloat = 260
    let rightX: CGFloat = 764
    let centerX: CGFloat = canvas / 2

    shieldPath.move(to: NSPoint(x: centerX, y: topY))
    shieldPath.curve(
        to: NSPoint(x: rightX, y: shoulderY),
        controlPoint1: NSPoint(x: centerX + 160, y: topY - 10),
        controlPoint2: NSPoint(x: rightX, y: shoulderY + 80)
    )
    shieldPath.curve(
        to: NSPoint(x: centerX, y: bottomY),
        controlPoint1: NSPoint(x: rightX, y: shoulderY - 180),
        controlPoint2: NSPoint(x: centerX + 120, y: bottomY + 100)
    )
    shieldPath.curve(
        to: NSPoint(x: leftX, y: shoulderY),
        controlPoint1: NSPoint(x: centerX - 120, y: bottomY + 100),
        controlPoint2: NSPoint(x: leftX, y: shoulderY - 180)
    )
    shieldPath.curve(
        to: NSPoint(x: centerX, y: topY),
        controlPoint1: NSPoint(x: leftX, y: shoulderY + 80),
        controlPoint2: NSPoint(x: centerX - 160, y: topY - 10)
    )
    shieldPath.close()

    // Outer glow / shadow
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: color(0x0284C7, 0.45).cgColor)
    color(0x0284C7, 0.4).setStroke()
    shieldPath.lineWidth = 14
    shieldPath.stroke()
    context.restoreGState()

    // Shield gradient fill
    context.saveGState()
    shieldPath.addClip()
    if let shieldGrad = NSGradient(colors: [shieldLight, shieldDark]) {
        shieldGrad.draw(in: rect, angle: -60)
    }
    context.restoreGState()

    // Inner shield border
    color(0xFFFFFF, 0.8).setStroke()
    shieldPath.lineWidth = 6
    shieldPath.stroke()

    // Center lock / checkmark emblem in emerald
    let lockWidth: CGFloat = 170
    let lockHeight: CGFloat = 140
    let lockX = centerX - (lockWidth / 2)
    let lockY: CGFloat = 430

    // Shackle
    let shacklePath = NSBezierPath()
    let shackleR: CGFloat = 52
    shacklePath.move(to: NSPoint(x: centerX - shackleR, y: lockY + lockHeight - 10))
    shacklePath.line(to: NSPoint(x: centerX - shackleR, y: lockY + lockHeight + 60))
    shacklePath.curve(
        to: NSPoint(x: centerX + shackleR, y: lockY + lockHeight + 60),
        controlPoint1: NSPoint(x: centerX - shackleR, y: lockY + lockHeight + 120),
        controlPoint2: NSPoint(x: centerX + shackleR, y: lockY + lockHeight + 120)
    )
    shacklePath.line(to: NSPoint(x: centerX + shackleR, y: lockY + lockHeight - 10))
    shacklePath.lineWidth = 26
    color(0x334155).setStroke()
    shacklePath.stroke()

    // Lock body
    let lockBodyPath = NSBezierPath(
        roundedRect: NSRect(x: lockX, y: lockY, width: lockWidth, height: lockHeight),
        xRadius: 28,
        yRadius: 28
    )
    accentGreen.setFill()
    lockBodyPath.fill()

    // Keyhole
    let keyCircle = NSBezierPath(
        ovalIn: NSRect(x: centerX - 18, y: lockY + 70, width: 36, height: 36)
    )
    lockBody.setFill()
    keyCircle.fill()

    let keySlot = NSBezierPath()
    keySlot.move(to: NSPoint(x: centerX - 10, y: lockY + 75))
    keySlot.line(to: NSPoint(x: centerX + 10, y: lockY + 75))
    keySlot.line(to: NSPoint(x: centerX + 6, y: lockY + 32))
    keySlot.line(to: NSPoint(x: centerX - 6, y: lockY + 32))
    keySlot.close()
    keySlot.fill()
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
let resourcesDir = (rootDir as NSString).appendingPathComponent("Sources/GlobalProtect/Resources")
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
