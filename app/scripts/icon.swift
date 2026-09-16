// Draws the app icon. Run it after changing anything here:
//   cd app && swift scripts/icon.swift
// It writes BDBridge/Assets.xcassets/AppIcon.appiconset/AppIcon.png, which is committed, so this only
// has to run when the drawing changes. AppKit is used rather than a design tool so the icon stays in the
// repository as code.
//
// A recorder on the LAN with the signal reaching it: the bridge, drawn in the graphite of the equipment
// itself, with the red light a recorder shows while recording.
import AppKit

let side: CGFloat = 1024
let out = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("BDBridge/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func rounded(_ c: CGContext, _ rect: CGRect, radius: CGFloat, _ color: CGColor) {
    c.setFillColor(color)
    c.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    c.fillPath()
}

/// Written at 1024 and scaled, so the same drawing serves any size.
func draw(_ c: CGContext, size: CGFloat) {
    let k = size / 1024

    let panel = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [rgb(0x3A3F45), rgb(0x0B0D10)] as CFArray, locations: [0, 1])!
    // the ends have to be drawn as well, or the corner past the end point is left transparent
    c.drawLinearGradient(panel, start: CGPoint(x: 0, y: size), end: CGPoint(x: size * 0.25, y: 0),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // the recorder: a low box with its status light and disc slot
    let box = CGRect(x: 236 * k, y: 232 * k, width: 552 * k, height: 158 * k)
    rounded(c, box, radius: 44 * k, CGColor.white)
    let light = 30 * k
    c.setFillColor(rgb(0xE8402F))
    c.fillEllipse(in: CGRect(x: box.minX + 88 * k - light, y: box.midY - light,
                             width: 2 * light, height: 2 * light))
    rounded(c, CGRect(x: box.minX + 172 * k, y: box.midY - 15 * k, width: 292 * k, height: 30 * k),
            radius: 15 * k, rgb(0x0B0D10, 0.30))

    // three arcs rising from it, fainter as they go out
    c.setLineCap(.round)
    let centre = CGPoint(x: box.midX, y: box.maxY - 26 * k)
    for (i, radius) in [188.0, 300.0, 412.0].enumerated() {
        c.setStrokeColor(CGColor(gray: 1, alpha: 1 - CGFloat(i) * 0.26))
        c.setLineWidth(44 * k)
        c.addArc(center: centre, radius: radius * k,
                 startAngle: .pi * 0.23, endAngle: .pi * 0.77, clockwise: false)
        c.strokePath()
    }
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
draw(context.cgContext, size: side)
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
