// Applies candidate Looks to frames: looks <srcDir> <outDir>
import AppKit
import CoreGraphics

typealias RGB = (r: Double, g: Double, b: Double)

func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
func luma(_ c: RGB) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
func map(_ c: RGB, _ f: (Double) -> Double) -> RGB { (f(c.r), f(c.g), f(c.b)) }
/// Positive adds an S-curve, negative flattens.
func contrast(_ c: RGB, _ k: Double) -> RGB { map(c) { x in let s = x * x * (3 - 2 * x); return clamp(x + k * (s - x) * 2) } }
func fade(_ c: RGB, _ f: Double) -> RGB { map(c) { f + (1 - f) * $0 } }
func saturate(_ c: RGB, _ s: Double) -> RGB { let l = luma(c); return map(c) { clamp(l + s * ($0 - l)) } }
func add(_ c: RGB, _ t: RGB, _ w: Double = 1) -> RGB { (clamp(c.r + t.r * w), clamp(c.g + t.g * w), clamp(c.b + t.b * w)) }
func split(_ c: RGB, shadows: RGB, highlights: RGB) -> RGB {
    let l = luma(c)
    return add(add(c, shadows, (1 - l) * (1 - l)), highlights, l * l)
}
func toHSV(_ c: RGB) -> (h: Double, s: Double, v: Double) {
    let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
    var h = 0.0
    if d > 1e-6 {
        if mx == c.r { h = 60 * (((c.g - c.b) / d).truncatingRemainder(dividingBy: 6)) }
        else if mx == c.g { h = 60 * ((c.b - c.r) / d + 2) }
        else { h = 60 * ((c.r - c.g) / d + 4) }
    }
    if h < 0 { h += 360 }
    return (h, mx > 0 ? d / mx : 0, mx)
}
func fromHSV(_ h: Double, _ s: Double, _ v: Double) -> RGB {
    let c = v * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
    let (r, g, b): (Double, Double, Double)
    switch h { case ..<60: (r, g, b) = (c, x, 0); case ..<120: (r, g, b) = (x, c, 0); case ..<180: (r, g, b) = (0, c, x)
    case ..<240: (r, g, b) = (0, x, c); case ..<300: (r, g, b) = (x, 0, c); default: (r, g, b) = (c, 0, x) }
    return (r + m, g + m, b + m)
}
/// Shifts hue and scales saturation for colours near `center`, fading out over `width` degrees.
func hueBand(_ c: RGB, center: Double, width: Double, shift: Double, sat: Double) -> RGB {
    var (h, s, v) = toHSV(c)
    var d = abs(h - center); if d > 180 { d = 360 - d }
    guard d < width else { return c }
    let w = 0.5 + 0.5 * cos(d / width * .pi)
    h = (h + shift * w + 360).truncatingRemainder(dividingBy: 360)
    s = clamp(s * (1 + (sat - 1) * w))
    return fromHSV(h, s, v)
}

/// The app's existing Teal and orange recipe, for comparison.
func tealOrange(_ c: RGB) -> RGB {
    var (r, g, b) = c
    let l = min(1, max(0, 0.2126 * r + 0.7152 * g + 0.0722 * b)), sh = 1 - l
    r += -0.05 * sh + 0.06 * l; g += 0.01 * sh + 0.01 * l; b += 0.05 * sh - 0.05 * l
    let k = 1 + 12.0 / 50 * 0.6
    r = (r - 0.5) * k + 0.5; g = (g - 0.5) * k + 0.5; b = (b - 0.5) * k + 0.5
    let l2 = 0.2126 * r + 0.7152 * g + 0.0722 * b, s = 1.1
    return (clamp(l2 + (r - l2) * s), clamp(l2 + (g - l2) * s), clamp(l2 + (b - l2) * s))
}

/// Warm skin, teal-olive shadows and greens, milky blacks, soft highlight roll-off.
func cinematic(_ c: RGB) -> RGB {
    var c = add(c, (0.04, 0.015, -0.035))
    c = hueBand(c, center: 25, width: 30, shift: 3, sat: 1.14)
    c = hueBand(c, center: 110, width: 60, shift: 22, sat: 0.68)
    c = hueBand(c, center: 210, width: 45, shift: -12, sat: 0.82)
    c = split(c, shadows: (-0.06, 0.04, 0.065), highlights: (0.045, 0.024, -0.03))
    c = contrast(c, -0.1)
    c = map(c) { x in x <= 0.72 ? x : 0.72 + (1 - 0.72) * (1 - exp(-(x - 0.72) / (1 - 0.72) * 1.2)) / (1 - exp(-1.2)) }
    c = fade(c, 0.05)
    return saturate(c, 0.88)
}

let looks: [(String, (RGB) -> RGB)] = [
    ("Original", { $0 }),
    ("Film green", { c in
        var c = hueBand(c, center: 115, width: 60, shift: 22, sat: 0.75)
        c = hueBand(c, center: 5, width: 35, shift: 4, sat: 0.72)
        c = contrast(c, -0.2); c = fade(c, 0.05)
        c = split(c, shadows: (-0.02, 0.045, 0.05), highlights: (0.02, 0.02, -0.012))
        return saturate(c, 0.85) }),
    ("Portrait", { c in
        var c = add(c, (0.045, 0.015, -0.035))
        c = hueBand(c, center: 28, width: 25, shift: 3, sat: 1.06)
        c = contrast(c, -0.24); c = fade(c, 0.045)
        c = split(c, shadows: (0.005, 0, 0.01), highlights: (0.025, 0.018, -0.012))
        return saturate(c, 0.88) }),
    ("Golden hour", { c in
        var c = split(c, shadows: (-0.012, 0, 0.03), highlights: (0.085, 0.04, -0.06))
        c = contrast(c, 0.08)
        return saturate(c, 1.08) }),
    ("Bleach bypass", { c in
        var c = saturate(c, 0.42)
        c = contrast(c, 0.42)
        return add(c, (-0.01, 0, 0.008)) }),
    ("Noir", { c in
        let m = 0.45 * c.r + 0.45 * c.g + 0.1 * c.b
        var v = contrast((m, m, m), 0.55)
        v = map(v) { clamp(($0 - 0.04) / 0.96) }
        return v }),
    ("Pastel", { c in
        var c = map(c) { pow($0, 0.8) }
        c = contrast(c, -0.36); c = fade(c, 0.14)
        c = split(c, shadows: (0.03, 0, 0.05), highlights: (0.01, 0, 0.012))
        return saturate(c, 0.8) }),
    ("70s", { c in
        var c = hueBand(c, center: 110, width: 65, shift: -28, sat: 0.62)
        c = hueBand(c, center: 220, width: 50, shift: -10, sat: 0.7)
        c = add(c, (0.075, 0.035, -0.07))
        c = contrast(c, -0.1); c = fade(c, 0.1)
        return saturate(c, 0.8) }),
]

let only = ProcessInfo.processInfo.environment["ONLY"] != nil
let run: [(String, (RGB) -> RGB)] = only ? [("Original", { $0 }), ("Teal and orange", tealOrange), ("Cinematic", cinematic)] : looks
let src = URL(fileURLWithPath: CommandLine.arguments[1]), out = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
for file in try! FileManager.default.contentsOfDirectory(atPath: src.path) where file.hasSuffix(".png") {
    let img = NSImage(contentsOf: src.appendingPathComponent(file))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let w = img.width, h = img.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let base = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let original = Array(UnsafeBufferPointer(start: base, count: w * h * 4))
    for (i, look) in run.enumerated() {
        for p in 0..<(w * h) {
            let c = look.1((Double(original[p * 4]) / 255, Double(original[p * 4 + 1]) / 255, Double(original[p * 4 + 2]) / 255))
            base[p * 4] = UInt8(clamp(c.r) * 255 + 0.5); base[p * 4 + 1] = UInt8(clamp(c.g) * 255 + 0.5); base[p * 4 + 2] = UInt8(clamp(c.b) * 255 + 0.5)
        }
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(i)_" + file))
    }
}
print(run.map(\.0).joined(separator: "|"))
