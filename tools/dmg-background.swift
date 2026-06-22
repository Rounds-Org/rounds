// Draws the Rounds DMG background: a clean off-white canvas with a green arrow pointing from
// the app icon to the Applications folder, plus a one-line instruction. Rendered at 2× (144 dpi)
// so it stays crisp on Retina. Usage: swift tools/dmg-background.swift <output.png>
import AppKit

let W = 540.0, H = 380.0, scale = 2.0
guard CommandLine.arguments.count > 1 else { fputs("usage: dmg-background.swift <out.png>\n", stderr); exit(1) }
let out = CommandLine.arguments[1]

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W*scale), pixelsHigh: Int(H*scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)   // points < pixels → encodes 2× (Retina-crisp)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Canvas — a soft off-white with the faintest green tint.
NSColor(calibratedRed: 0.96, green: 0.972, blue: 0.96, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

let green = NSColor(calibratedRed: 0.337, green: 0.584, blue: 0.404, alpha: 1)

// Arrow shaft + head, centered in the gap between the two icons (icons sit at window y≈190).
green.setStroke()
let shaft = NSBezierPath()
shaft.lineWidth = 7; shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: 212, y: 190))
shaft.line(to: NSPoint(x: 326, y: 190))
shaft.stroke()
let head = NSBezierPath()
head.lineWidth = 7; head.lineCapStyle = .round; head.lineJoinStyle = .round
head.move(to: NSPoint(x: 309, y: 203))
head.line(to: NSPoint(x: 328, y: 190))
head.line(to: NSPoint(x: 309, y: 177))
head.stroke()

// One-line instruction near the top.
let para = NSMutableParagraphStyle(); para.alignment = .center
let title = "Drag Rounds into Applications" as NSString
title.draw(in: NSRect(x: 0, y: 300, width: W, height: 30), withAttributes: [
    .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1),
    .paragraphStyle: para,
])

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fputs("png encode failed\n", stderr); exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
