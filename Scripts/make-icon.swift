#!/usr/bin/env swift
import AppKit
import Foundation

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    let s = CGFloat(size)

    let pad = s * 0.08
    let rect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    cg.saveGState()
    cg.addPath(path)
    cg.clip()

    let bgColors = [
        CGColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 1.0),
        CGColor(red: 0.04, green: 0.06, blue: 0.09, alpha: 1.0)
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: [0.0, 1.0])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // Cryo aperture ring
    let center = CGPoint(x: s * 0.5, y: s * 0.54)
    let outerR = s * 0.25
    cg.setStrokeColor(CGColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 0.95))
    cg.setLineWidth(s * 0.055)
    cg.strokeEllipse(in: CGRect(x: center.x - outerR, y: center.y - outerR, width: outerR * 2, height: outerR * 2))

    // Hexagonal cryo crystal spokes inside the lens
    cg.setLineWidth(s * 0.028)
    cg.setLineCap(.round)
    for idx in 0..<3 {
        let angle = CGFloat(idx) * (.pi / 3.0)
        let r = outerR * 0.62
        cg.move(to: CGPoint(x: center.x - cos(angle) * r, y: center.y - sin(angle) * r))
        cg.addLine(to: CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r))
        cg.strokePath()
    }

    // Bottom segmented RSS memory allocation bar
    let barY = s * 0.18
    let barH = s * 0.065
    let segs: [(CGFloat, CGFloat, CGColor)] = [
        (0.20, 0.28, CGColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1.0)),
        (0.50, 0.16, CGColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1.0)),
        (0.68, 0.12, CGColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1.0))
    ]
    for (xFrac, wFrac, col) in segs {
        let r = CGRect(x: s * xFrac, y: barY, width: s * wFrac, height: barH)
        let p = CGPath(roundedRect: r, cornerWidth: barH * 0.45, cornerHeight: barH * 0.45, transform: nil)
        cg.setFillColor(col)
        cg.addPath(p)
        cg.fillPath()
    }

    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in specs {
    try drawIcon(size: px).write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
}
