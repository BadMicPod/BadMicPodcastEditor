import SwiftUI
import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }
}

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }
}

/// One palette shared by SwiftUI and the AppKit timeline.
enum Theme {
    enum NS {
        // Neutral blacks and greys, off-white type, and one red-orange for the few things that must stand out.
        static let bg = NSColor(hex: 0x0A0A0A)
        static let panel = NSColor(hex: 0x111111)
        static let lane = NSColor(hex: 0x0D0D0D)
        static let laneAlt = NSColor(hex: 0x0A0A0A)
        static let raised = NSColor(hex: 0x1A1A1A)
        static let stroke = NSColor(white: 1, alpha: 0.085)
        static let text = NSColor(hex: 0xF2F2F0)
        static let textDim = NSColor(hex: 0x9A9A96)
        static let textFaint = NSColor(hex: 0x5C5C59)
        static let accent = NSColor(hex: 0xFF4A1C)
        /// Meter yellow.
        static let snap = NSColor(hex: 0xF2C14E)

        // Clips are neutral; their pictures and waveforms carry the colour.
        static let video = NSColor(hex: 0x1E1E1E)
        static let audio = NSColor(hex: 0x151515)
        static let image = NSColor(hex: 0x1E1E1E)
        static let textClip = NSColor(hex: 0x1B1B1B)
        static let solid = NSColor(hex: 0x1B1B1B)
        static let wave = NSColor(hex: 0xBDBDB9)
        static let clipStroke = NSColor(hex: 0x2C2C2C)

        static func clip(_ kind: ClipKind) -> NSColor {
            switch kind {
            case .video: return video
            case .audio: return audio
            case .image: return image
            case .text: return textClip
            case .solid: return solid
            }
        }
    }

    static let bg = Color(nsColor: NS.bg)
    static let panel = Color(nsColor: NS.panel)
    static let raised = Color(nsColor: NS.raised)
    static let field = Color(hex: 0x181818)
    static let hover = Color.white.opacity(0.07)
    static let stroke = Color.white.opacity(0.085)
    static let text = Color(nsColor: NS.text)
    static let textDim = Color(nsColor: NS.textDim)
    static let textFaint = Color(nsColor: NS.textFaint)
    /// Small spaced-out section labels.
    static func label(_ size: CGFloat = 10) -> Font { .system(size: size, weight: .semibold) }
    static let accent = Color(nsColor: NS.accent)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Shared controls

/// Square icon button with a hover state and optional "on" state.
struct IconButton: View {
    let symbol: String
    var active = false
    var size: CGFloat = 28
    var help = ""
    /// Shifts the glyph up (negative) or down to centre symbols whose weight sits off-centre.
    var nudge: CGFloat = 0
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(active || hovering ? Theme.text : Theme.textDim)
                .offset(y: nudge)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Color.white.opacity(0.1) : (hovering ? Theme.hover : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The icon for a solid clip: a 16:9 frame filled with colour.
struct SolidIcon: View {
    var lineWidth: CGFloat = 1.3

    var body: some View {
        Canvas { ctx, size in
            let outer = CGRect(x: lineWidth / 2, y: lineWidth / 2, width: size.width - lineWidth, height: size.height - lineWidth)
            ctx.stroke(Path(roundedRect: outer, cornerRadius: 2.2), with: .foreground, lineWidth: lineWidth)
            let inner = outer.insetBy(dx: lineWidth + 1.1, dy: lineWidth + 1.1)
            ctx.fill(Path(roundedRect: inner, cornerRadius: 1), with: .foreground)
        }
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Draggable splitter between panes.
struct Splitter: View {
    let vertical: Bool
    let onDrag: (CGFloat) -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill((hovering || dragging) ? Color.white.opacity(0.45) : Theme.stroke)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .overlay(
                Color.clear
                    .frame(width: vertical ? 9 : nil, height: vertical ? nil : 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                dragging = true
                                onDrag(vertical ? v.location.x : v.location.y)
                            }
                            .onEnded { _ in dragging = false }
                    )
            )
            .zIndex(10)
    }
}
