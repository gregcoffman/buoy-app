// Draws Buoy's app icon: a life ring floating on calm water.
// Usage: swift scripts/make-icon.swift <output.png>   (1024×1024)
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// macOS icon grid: 824pt rounded square centred in 1024.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// Soft drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
color(0x0E3A5C).setFill()
tilePath.fill()
ctx.restoreGState()

// Sky-to-sea gradient.
tilePath.addClip()
NSGradient(colors: [color(0x8FD3F4), color(0x3E9ACB), color(0x145C8A)], atLocations: [0, 0.55, 1],
           colorSpace: .sRGB)!.draw(in: tile, angle: -90)

// The ring.
let center = CGPoint(x: 512, y: 540)
let outer: CGFloat = 250, inner: CGFloat = 132
let ringShadow = NSShadow()
ringShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
ringShadow.shadowOffset = NSSize(width: 0, height: -10)
ringShadow.shadowBlurRadius = 20

func ringSegment(from start: CGFloat, to end: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.appendArc(withCenter: center, radius: outer, startAngle: start, endAngle: end)
    p.appendArc(withCenter: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
    p.close()
    return p
}

NSGraphicsContext.saveGraphicsState()
ringShadow.set()
color(0xFFFFFF).setFill()
ringSegment(from: 0, to: 360).fill()
NSGraphicsContext.restoreGraphicsState()

for i in 0..<4 {
    let start = CGFloat(i) * 90 + 22.5
    color(0xE8483B).setFill()
    ringSegment(from: start, to: start + 45).fill()
}
// Rope
let rope = NSBezierPath()
rope.appendArc(withCenter: center, radius: (outer + inner) / 2, startAngle: 0, endAngle: 360)
rope.lineWidth = 7
color(0xF4E6C8, 0.9).setStroke()
let dash: [CGFloat] = [34, 20]
rope.setLineDash(dash, count: 2, phase: 0)
rope.stroke()
// Highlight
let shine = NSBezierPath()
shine.appendArc(withCenter: center, radius: outer - 24, startAngle: 110, endAngle: 160)
shine.lineWidth = 16
shine.lineCapStyle = .round
color(0xFFFFFF, 0.55).setStroke()
shine.stroke()

// Water in front of the ring's lower edge.
func wave(baseline: CGFloat, amplitude: CGFloat, phase: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: tile.minX, y: tile.minY))
    p.line(to: CGPoint(x: tile.minX, y: baseline))
    var x = tile.minX
    while x <= tile.maxX {
        p.line(to: CGPoint(x: x, y: baseline + amplitude * sin((x / tile.width) * 2 * .pi * 1.5 + phase)))
        x += 4
    }
    p.line(to: CGPoint(x: tile.maxX, y: tile.minY))
    p.close()
    return p
}
color(0x1B6FA3, 0.92).setFill()
wave(baseline: 350, amplitude: 22, phase: 0.6).fill()
color(0x0F4E7A, 0.95).setFill()
wave(baseline: 270, amplitude: 18, phase: 2.2).fill()

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
