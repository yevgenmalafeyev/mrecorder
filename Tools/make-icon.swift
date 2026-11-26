// Draws the MacRecorder app icon at 1024x1024 and writes a PNG.
// Usage: swift Tools/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a,
    ])!
}

func linear(_ c1: CGColor, _ c2: CGColor, from p1: CGPoint, to p2: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: [c1, c2] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: p1, end: p2, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Canvas: macOS icon grid, 824 pt body centered with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = squircle(body, radius: 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0x15183A))
ctx.fillPath()
ctx.restoreGState()

// Background gradient
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
linear(color(0x3B3FA8), color(0x0E1030), from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.minY))
// subtle top sheen
linear(color(0xFFFFFF, 0.10), color(0xFFFFFF, 0.0), from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.midY + 120))
ctx.restoreGState()

// Screen (monitor) panel
let screen = CGRect(x: 190, y: 330, width: 600, height: 420)
let screenPath = squircle(screen, radius: 54)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.45))
ctx.addPath(screenPath)
ctx.setFillColor(color(0x1B1E4D))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(screenPath)
ctx.clip()
linear(color(0x5A62E6), color(0x262A78), from: CGPoint(x: screen.minX, y: screen.maxY), to: CGPoint(x: screen.maxX, y: screen.minY))
// faint content lines on the screen
ctx.setFillColor(color(0xFFFFFF, 0.16))
for (i, w) in [CGFloat(300), 380, 240].enumerated() {
    let y = screen.maxY - 210 - CGFloat(i) * 52
    ctx.addPath(squircle(CGRect(x: screen.minX + 70, y: y, width: w, height: 22), radius: 11))
    ctx.fillPath()
}
ctx.restoreGState()
ctx.addPath(screenPath)
ctx.setStrokeColor(color(0xFFFFFF, 0.22))
ctx.setLineWidth(4)
ctx.strokePath()

// Monitor stand
ctx.setFillColor(color(0xFFFFFF, 0.28))
ctx.addPath(squircle(CGRect(x: 445, y: 262, width: 90, height: 64), radius: 10))
ctx.fillPath()
ctx.addPath(squircle(CGRect(x: 365, y: 236, width: 250, height: 30), radius: 15))
ctx.fillPath()

// Record dot with glow, top-left of the screen
let dotCenter = CGPoint(x: screen.minX + 92, y: screen.maxY - 92)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: color(0xFF3B30, 0.9))
ctx.addEllipse(in: CGRect(x: dotCenter.x - 42, y: dotCenter.y - 42, width: 84, height: 84))
ctx.setFillColor(color(0xFF3B30))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: dotCenter.x - 42, y: dotCenter.y - 42, width: 84, height: 84))
ctx.clip()
linear(color(0xFF6A5C), color(0xD91E14), from: CGPoint(x: 0, y: dotCenter.y + 42), to: CGPoint(x: 0, y: dotCenter.y - 42))
ctx.restoreGState()

// Camera bubble, bottom-right, overlapping the screen corner
let bubble = CGRect(x: 600, y: 190, width: 250, height: 250)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.5))
ctx.addEllipse(in: bubble)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()
let inner = bubble.insetBy(dx: 14, dy: 14)
ctx.saveGState()
ctx.addEllipse(in: inner)
ctx.clip()
linear(color(0xFFC46B), color(0xFF6B4A), from: CGPoint(x: inner.minX, y: inner.maxY), to: CGPoint(x: inner.maxX, y: inner.minY))
// person silhouette
ctx.setFillColor(color(0xFFFFFF, 0.92))
let headR: CGFloat = 46
ctx.addEllipse(in: CGRect(x: inner.midX - headR, y: inner.midY + 2, width: headR * 2, height: headR * 2))
ctx.fillPath()
ctx.addEllipse(in: CGRect(x: inner.midX - 92, y: inner.minY - 70, width: 184, height: 170))
ctx.fillPath()
ctx.restoreGState()

// Thin highlight on the body edge
ctx.addPath(squircle(body.insetBy(dx: 2, dy: 2), radius: 183))
ctx.setStrokeColor(color(0xFFFFFF, 0.10))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
