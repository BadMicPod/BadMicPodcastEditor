// Draws the DMG window background: film-strip sprocket bands top and bottom, the Editroom wordmark
// and tagline, and an arrow from the app to Applications. Finder draws the icons themselves.
//   swift scripts/dmg/make-background.swift <out dir>
// writes background.png (600×380) and background@2x.png (1200×760).
// The arrow lines up with the icon spots in scripts/make-dmg.sh (160 and 440 across, 220 down).
import AppKit

let W: CGFloat = 600, H: CGFloat = 380
let ink = NSColor(srgbRed: 0x0A / 255, green: 0x0A / 255, blue: 0x0A / 255, alpha: 1)
let band = NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255, alpha: 1)
let title = NSColor(srgbRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF0 / 255, alpha: 1)
let quiet = NSColor(srgbRed: 0x5C / 255, green: 0x5C / 255, blue: 0x59 / 255, alpha: 1)
let arrow = NSColor(srgbRed: 0x9A / 255, green: 0x9A / 255, blue: 0x96 / 255, alpha: 1)

func draw(scale: CGFloat, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    // Flip so y runs down from the top, like Finder's icon positions.
    let t = NSAffineTransform(); t.translateX(by: 0, yBy: H); t.scaleX(by: 1, yBy: -1); t.concat()

    ink.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    band.setFill()
    NSRect(x: 0, y: 0, width: W, height: 34).fill()
    NSRect(x: 0, y: H - 34, width: W, height: 34).fill()
    ink.setFill()
    for x in stride(from: CGFloat(12), to: W, by: 40) {
        NSBezierPath(roundedRect: NSRect(x: x, y: 10, width: 20, height: 14), xRadius: 3, yRadius: 3).fill()
        NSBezierPath(roundedRect: NSRect(x: x, y: H - 24, width: 20, height: 14), xRadius: 3, yRadius: 3).fill()
    }

    func text(_ s: String, font: NSFont, color: NSColor, baseline y: CGFloat, kern: CGFloat = 0) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern])
        let w = a.size().width
        // Text draws upright in a flipped context only when the context says it's flipped.
        NSGraphicsContext.saveGraphicsState()
        let f = NSAffineTransform(); f.translateX(by: (W - w) / 2, yBy: y); f.scaleX(by: 1, yBy: -1); f.concat()
        a.draw(at: NSPoint(x: 0, y: -font.descender))
        NSGraphicsContext.restoreGraphicsState()
    }
    text("Editroom", font: .systemFont(ofSize: 30, weight: .bold), color: title, baseline: 100, kern: -0.5)
    text("Edit by hand, or let Magic make the cut.", font: .systemFont(ofSize: 14), color: quiet, baseline: 126)

    arrow.setStroke()
    let p = NSBezierPath(); p.lineWidth = 2; p.lineCapStyle = .round; p.lineJoinStyle = .round
    p.move(to: NSPoint(x: 275, y: 220)); p.line(to: NSPoint(x: 325, y: 220))
    p.move(to: NSPoint(x: 316, y: 212)); p.line(to: NSPoint(x: 326, y: 220)); p.line(to: NSPoint(x: 316, y: 228))
    p.stroke()

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
draw(scale: 1, to: out.appendingPathComponent("background.png"))
draw(scale: 2, to: out.appendingPathComponent("background@2x.png"))
