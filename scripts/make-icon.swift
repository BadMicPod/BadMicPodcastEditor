import AppKit
import SwiftUI
let args = CommandLine.arguments
guard let src = NSImage(contentsOfFile: args[1]), let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("no image") }
let canvas = 1024
let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Apple's macOS icon grid: an 824pt rounded square centred in a 1024pt canvas, with a soft drop shadow.
let box = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = Path(roundedRect: box, cornerRadius: 185.4, style: .continuous).cgPath
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(CGColor(gray: 0.055, alpha: 1))
ctx.fillPath()
ctx.restoreGState()
ctx.addPath(shape)
ctx.clip()
ctx.interpolationQuality = .high
// The artwork sits small in its frame, so enlarge it a little inside the tile.
let scale: CGFloat = 1.15
let side = box.width * scale
ctx.draw(cg, in: CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side))
let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
