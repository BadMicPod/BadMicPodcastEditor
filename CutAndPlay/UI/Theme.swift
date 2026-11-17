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
            Glyph(symbol: symbol, size: size * 0.46)
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
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}

/// The app's own line icons, drawn on a 16-point grid with one 1.3-point stroke so they read as one
/// family. Each stands in for the system symbol of the same meaning.
struct LineIcon: Shape {
    let name: String

    static let names: Set<String> = ["cursorarrow", "scissors", "textformat", "square.and.arrow.down", "eye", "eye.slash",
                                     "lock", "repeat", "arrow.left.and.right", "arrow.up.left.and.arrow.down.right",
                                     "arrow.down.right.and.arrow.up.left", "trash"]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func line(_ pts: [(CGFloat, CGFloat)]) {
            p.move(to: pt(pts[0].0, pts[0].1))
            for q in pts.dropFirst() { p.addLine(to: pt(q.0, q.1)) }
        }
        switch name {
        case "cursorarrow":
            line([(3, 2), (13, 8.2), (8.6, 9.1), (11.1, 13.5), (9.5, 14.4), (7, 10), (3.6, 12)])
            p.closeSubpath()
        case "scissors":
            p.addEllipse(in: CGRect(x: 1.7, y: 9.7, width: 4.6, height: 4.6))
            p.addEllipse(in: CGRect(x: 9.7, y: 9.7, width: 4.6, height: 4.6))
            line([(5.6, 10.4), (13, 2)])
            line([(10.4, 10.4), (3, 2)])
        case "textformat":
            line([(3, 13.5), (7, 2.5), (9, 2.5), (13, 13.5)])
            line([(4.6, 9.5), (11.4, 9.5)])
        case "square.and.arrow.down":
            line([(8, 1.5), (8, 10)])
            line([(5, 7), (8, 10), (11, 7)])
            p.move(to: pt(3, 9.5)); p.addLine(to: pt(3, 12.5))
            p.addQuadCurve(to: pt(4.5, 14), control: pt(3, 14))
            p.addLine(to: pt(11.5, 14))
            p.addQuadCurve(to: pt(13, 12.5), control: pt(13, 14))
            p.addLine(to: pt(13, 9.5))
        case "eye", "eye.slash":
            p.move(to: pt(1.5, 8))
            p.addQuadCurve(to: pt(14.5, 8), control: pt(8, 1))
            p.addQuadCurve(to: pt(1.5, 8), control: pt(8, 15))
            p.addEllipse(in: CGRect(x: 6, y: 6, width: 4, height: 4))
            if name == "eye.slash" { line([(2.5, 13.5), (13.5, 2.5)]) }
        case "lock":
            p.addRoundedRect(in: CGRect(x: 3, y: 7, width: 10, height: 7.5), cornerSize: CGSize(width: 1.5, height: 1.5))
            p.move(to: pt(5.2, 7)); p.addLine(to: pt(5.2, 5))
            p.addArc(center: pt(8, 5), radius: 2.8, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: pt(10.8, 7))
        case "repeat":
            p.move(to: pt(2, 7)); p.addLine(to: pt(2, 6))
            p.addQuadCurve(to: pt(4.5, 3.5), control: pt(2, 3.5))
            p.addLine(to: pt(13, 3.5))
            line([(11, 1.5), (13, 3.5), (11, 5.5)])
            p.move(to: pt(14, 9)); p.addLine(to: pt(14, 10))
            p.addQuadCurve(to: pt(11.5, 12.5), control: pt(14, 12.5))
            p.addLine(to: pt(3, 12.5))
            line([(5, 14.5), (3, 12.5), (5, 10.5)])
        case "arrow.left.and.right":
            line([(1.5, 8), (14.5, 8)])
            line([(4.5, 5), (1.5, 8), (4.5, 11)])
            line([(11.5, 5), (14.5, 8), (11.5, 11)])
        case "arrow.up.left.and.arrow.down.right":
            line([(2, 6), (2, 2), (6, 2)]); line([(2, 2), (6.5, 6.5)])
            line([(14, 10), (14, 14), (10, 14)]); line([(14, 14), (9.5, 9.5)])
        case "arrow.down.right.and.arrow.up.left":
            line([(6.5, 2.5), (6.5, 6.5), (2.5, 6.5)]); line([(2, 2), (6.5, 6.5)])
            line([(9.5, 13.5), (9.5, 9.5), (13.5, 9.5)]); line([(14, 14), (9.5, 9.5)])
        case "trash":
            line([(2.5, 4.5), (13.5, 4.5)])
            line([(6, 4.5), (6, 3), (10, 3), (10, 4.5)])
            line([(4, 4.5), (4.7, 13.5), (11.3, 13.5), (12, 4.5)])
        default:
            break
        }
        return p.applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 16).translatedBy(x: rect.minX, y: rect.minY))
    }
}

/// An icon by system-symbol name, drawn from the app's own line set where it has one.
struct Glyph: View {
    let symbol: String
    /// The size a system symbol would be drawn at; line icons are sized to match.
    let size: CGFloat
    var weight: Font.Weight = .medium

    var body: some View {
        if LineIcon.names.contains(symbol) {
            LineIcon(name: symbol)
                .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                .frame(width: size * 1.2, height: size * 1.2)
        } else if symbol == "solid" {
            SolidIcon(lineWidth: 1.3).frame(width: size * 1.15, height: size * 0.86)
        } else {
            Image(systemName: symbol).font(.system(size: size, weight: weight))
        }
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
