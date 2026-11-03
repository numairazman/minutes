import SwiftUI
import UIKit

// "Steno": every screen is a page of a stenographer's pad — pale green eye-ease paper, a red
// margin rule, and a ballpoint with several inks, one per speaker. The margin column holds *when*
// (times, lengths, markers); the page column holds *what* was said.
//
// At night it's the same pad in low light — deep green-grey paper with paper-coloured ink — rather
// than a generic dark theme, so the object stays recognisable.

extension Color {
    static let paper = Color(light: 0xEDF2E4, dark: 0x222D28)
    static let paperRaised = Color(light: 0xE2EAD6, dark: 0x2B3832)
    static let rule = Color(light: 0xC5D3CB, dark: 0x394A41)
    /// The margin rule. Also the record button and error notes: one red, like the pad's.
    static let margin = Color(light: 0xC9473D, dark: 0xE5705F)
    static let ink = Color(light: 0x1D2A3A, dark: 0xE6ECDF)
    static let pencil = Color(light: 0x5E6B72, dark: 0x9DAEA3)
    /// Blue ballpoint: controls, links, and the first speaker.
    static let ballpoint = Color(light: 0x2D5BD0, dark: 0x8EB0FF)

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Each speaker writes in their own ink, in the order they first spoke.
enum Ink {
    private static let inks: [Color] = [
        .ballpoint,
        Color(light: 0x2F7A4D, dark: 0x79CF9A),
        Color(light: 0x8B3A7A, dark: 0xE39AD2),
        Color(light: 0x1E7489, dark: 0x6CCBE0),
        Color(light: 0x9C6A12, dark: 0xE7BC62),
        Color(light: 0xA33A2F, dark: 0xF2917F),
    ]

    static func color(for speaker: String) -> Color {
        let index = (Int(speaker) ?? 1) - 1
        return inks[((index % inks.count) + inks.count) % inks.count]
    }
}

/// New York for everything written on the page; SF Pro for controls and margin notes.
enum Typeface {
    static func page(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        .system(style, design: .serif, weight: weight)
    }

    static func note(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default, weight: weight)
    }
}

// MARK: - Spacing

/// One vertical rhythm on a 4 pt grid, named for what each gap separates. Every screen uses
/// these and nothing else, so equal things sit at equal distances everywhere.
enum Space {
    /// A label and the value right under it ("Speech model" / "Ready").
    static let tight: CGFloat = 4
    /// Lines that belong to one item (a title and its excerpt, a name and its words).
    static let line: CGFloat = 8
    /// Items in a group (bullets in a list, chips in the legend).
    static let item: CGFloat = 12
    /// The padding inside a ruled row, above and below its content.
    static let row: CGFloat = 16
    /// Between groups on one page (header to notes, heading to its rows).
    static let group: CGFloat = 24
    /// Before a new part of the page (Decided after the overview, tabs after the header).
    static let part: CGFloat = 32
    /// Between sections of Settings, and day groups in the list.
    static let section: CGFloat = 40
}

// MARK: - Page layout

/// The page's columns. The margin scales with Dynamic Type so "10:47 PM" never wraps.
struct PageMetrics {
    var marginWidth: CGFloat
    static let edge: CGFloat = 20
    /// More room on the right than the left: text running to within 18 pt of the edge read as
    /// cramped, and the margin column already anchors the left.
    static let trailingEdge: CGFloat = 24
    static let gutter: CGFloat = 16

    /// x of the red margin rule, from the leading edge of the screen.
    var ruleX: CGFloat { Self.edge + marginWidth + Self.gutter / 2 }
}

/// Paper with the red margin rule running the full height.
struct PaperPage: View {
    let metrics: PageMetrics

    var body: some View {
        Color.paper
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.margin.opacity(0.55))
                    .frame(width: 1)
                    .offset(x: metrics.ruleX)
            }
            .ignoresSafeArea()
    }
}

/// One line of the pad: a note in the margin (right-aligned against the rule), the page to its right.
struct MarginRow<Margin: View, Page: View>: View {
    let metrics: PageMetrics
    var alignment: VerticalAlignment = .firstTextBaseline
    @ViewBuilder var margin: Margin
    @ViewBuilder var page: Page

    var body: some View {
        HStack(alignment: alignment, spacing: PageMetrics.gutter) {
            margin
                .frame(width: metrics.marginWidth, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            page
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, PageMetrics.edge)
        .padding(.trailing, PageMetrics.trailingEdge)
    }
}

/// An empty margin that still holds its column. Zero height: a flexible Color here would grow
/// to fill the row and, under first-baseline alignment, push the page text down over the next row.
struct BlankMargin: View {
    var body: some View { Color.clear.frame(height: 0) }
}

extension MarginRow where Margin == BlankMargin {
    /// Page only; the margin stays blank but keeps its width, so text never crosses the rule.
    init(metrics: PageMetrics, alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder page: () -> Page) {
        self.metrics = metrics
        self.alignment = alignment
        self.margin = BlankMargin()
        self.page = page()
    }
}

/// "0:04", "12:31", "1:02:45" — no leading zero hours, as a clock on the page would read.
func clockText(_ seconds: Double, long: Bool = false) -> String {
    let s = max(0, Int(seconds))
    return long || s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

/// The playback position as a line of ink with a red playhead. Draggable, and a real Slider to
/// VoiceOver.
struct InkScrubber: View {
    @Binding var value: Double
    let total: Double

    var body: some View {
        GeometryReader { geo in
            let fraction = total > 0 ? min(1, max(0, value / total)) : 0
            let x = geo.size.width * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Color.rule).frame(height: 3)
                Capsule().fill(Color.ink).frame(width: max(3, x), height: 3)
                Circle()
                    .fill(Color.margin)
                    .frame(width: 14, height: 14)
                    .offset(x: x - 7)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard geo.size.width > 0 else { return }
                value = total * min(1, max(0, drag.location.x / geo.size.width))
            })
        }
        .frame(height: 28)
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...max(total, 1))
                .accessibilityLabel("Position")
        }
    }
}

/// A short pen stroke in a speaker's ink — the pad's way of saying "this person".
struct InkStroke: View {
    let color: Color
    var length: CGFloat = 16

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: length, height: 3.5)
            .rotationEffect(.degrees(-6))
            .accessibilityHidden(true)
    }
}

/// A full-width hairline, the pad's ruled line.
struct RuledLine: View {
    var body: some View {
        Rectangle().fill(Color.rule).frame(height: 1)
    }
}

// MARK: - Controls

/// Hardware-style record key: an ink ring around a red core. The core becomes a rounded square
/// while recording, so the same key reads "stop".
struct RecordKey: View {
    var recording: Bool
    var size: CGFloat = 76

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.ink, lineWidth: 3.5)
            RoundedRectangle(cornerRadius: recording ? size * 0.09 : size * 0.5, style: .continuous)
                .fill(Color.margin)
                .frame(width: recording ? size * 0.36 : size * 0.72, height: recording ? size * 0.36 : size * 0.72)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: recording)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A round outlined key in ink, for secondary actions next to the record key.
struct InkKey: View {
    let systemImage: String
    var size: CGFloat = 56

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.36, weight: .medium))
            .foregroundStyle(Color.ink)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.ink.opacity(0.35), lineWidth: 1.5))
            .contentShape(Circle())
    }
}

/// Words as tabs, the chosen one underlined in blue ballpoint.
struct InkTabs<Tab: Hashable>: View {
    let tabs: [(Tab, String)]
    @Binding var selection: Tab
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 24) {
            ForEach(tabs, id: \.0) { tab, title in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = tab }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(Typeface.page(.title3, selection == tab ? .semibold : .regular))
                            .foregroundStyle(selection == tab ? Color.ink : Color.pencil)
                        ZStack {
                            if selection == tab {
                                Capsule()
                                    .fill(Color.ballpoint)
                                    .frame(height: 2.5)
                                    .rotationEffect(.degrees(-1))
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                        .frame(height: 3)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
    }
}

/// Progress as a line being inked from left to right.
struct InkProgress: View {
    /// 0…1, or nil while the stage can't say how far along it is.
    let fraction: Double?
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.rule)
                if let fraction {
                    Capsule()
                        .fill(Color.ballpoint)
                        .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
                        .animation(.easeOut(duration: 0.3), value: fraction)
                } else {
                    Capsule()
                        .fill(Color.ballpoint)
                        .frame(width: geo.size.width * 0.28)
                        .offset(x: sweep ? geo.size.width * 0.72 : 0)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: sweep)
                        .onAppear { sweep = true }
                }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

// MARK: - Pen trace

/// The recording screen's signature: the input level drawn as one continuous ink line, like a
/// chart recorder's pen, with the pen tip at the right edge. One wandering line rather than a
/// mirrored envelope — that's what makes it read as "being written" instead of "a waveform".
struct PenTrace: View {
    /// Oldest first, 0…1.
    let levels: [Float]
    /// Total samples taken so far. Each sample's up/down wiggle is derived from its absolute
    /// index, so the history scrolls left without shimmering.
    let tick: Int
    var active: Bool

    var body: some View {
        Canvas { context, size in
            let baseline = size.height / 2
            let amplitude = size.height / 2 - 6
            let count = levels.count
            guard count > 1 else { return }
            let step = (size.width - 8) / CGFloat(count - 1)

            var baselinePath = Path()
            baselinePath.move(to: CGPoint(x: 0, y: baseline))
            baselinePath.addLine(to: CGPoint(x: size.width, y: baseline))
            context.stroke(baselinePath, with: .color(.rule), lineWidth: 1)

            var points: [CGPoint] = []
            points.reserveCapacity(count)
            for i in 0..<count {
                let absolute = tick - (count - 1 - i)
                let level = CGFloat(levels[i])
                let point = CGPoint(x: CGFloat(i) * step, y: baseline - level * amplitude * Self.wiggle(absolute))
                points.append(point)
            }

            var trace = Path()
            trace.move(to: points[0])
            for i in 1..<points.count {
                let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
                trace.addQuadCurve(to: mid, control: points[i - 1])
            }
            trace.addLine(to: points[points.count - 1])
            context.stroke(trace, with: .color(.ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            let tip = points[points.count - 1]
            let r: CGFloat = active ? 4 : 3
            context.fill(Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2)),
                         with: .color(active ? .margin : .pencil))
        }
        .accessibilityHidden(true)
    }

    /// Deterministic -1…1 per sample: alternating sign with a little irregularity, so speech reads
    /// as a pen scratching up and down rather than a regular zigzag.
    private static func wiggle(_ n: Int) -> CGFloat {
        let sign: CGFloat = n.isMultiple(of: 2) ? 1 : -1
        var x = UInt64(truncatingIfNeeded: n &* 2_654_435_761)
        x ^= x >> 13
        x = x &* 0x5bd1e995
        x ^= x >> 15
        let jitter = CGFloat(x % 1000) / 1000 // 0…1
        return sign * (0.45 + 0.55 * jitter)
    }
}
