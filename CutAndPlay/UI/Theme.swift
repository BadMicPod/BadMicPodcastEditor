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
        static let bg = NSColor(hex: 0x0C0C0E)
        static let panel = NSColor(hex: 0x131316)
        static let lane = NSColor(hex: 0x17171B)
        static let laneAlt = NSColor(hex: 0x141418)
        static let raised = NSColor(hex: 0x1E1E23)
        static let stroke = NSColor(white: 1, alpha: 0.07)
        static let text = NSColor(white: 1, alpha: 0.92)
        static let textDim = NSColor(white: 1, alpha: 0.55)
        static let textFaint = NSColor(white: 1, alpha: 0.3)
        static let accent = NSColor(hex: 0xFF5B3A)
        static let snap = NSColor(hex: 0xFFD23F)

        static let video = NSColor(hex: 0x3D6BE0)
        static let audio = NSColor(hex: 0x1FA88A)
        static let image = NSColor(hex: 0x8A5BE0)
        static let textClip = NSColor(hex: 0xD9488B)
        static let solid = NSColor(hex: 0x6B7280)
        static let wave = NSColor(hex: 0x7CF2D2)

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
    static let field = Color.white.opacity(0.055)
    static let hover = Color.white.opacity(0.08)
    static let stroke = Color.white.opacity(0.07)
    static let text = Color.white.opacity(0.92)
    static let textDim = Color.white.opacity(0.55)
    static let textFaint = Color.white.opacity(0.3)
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
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(active ? Theme.accent : (hovering ? Theme.text : Theme.textDim))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover : .clear))
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
            ctx.stroke(Path(roundedRect: outer, cornerRadius: 2.5), with: .foreground, lineWidth: lineWidth)
            let inner = outer.insetBy(dx: lineWidth + 1.4, dy: lineWidth + 1.4)
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
            .fill((hovering || dragging) ? Theme.accent.opacity(0.9) : Theme.stroke)
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
