import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The recording's Live Activity: a card off the pad. The margin holds the state (a red dot while
/// recording); the page holds the clock, the pen trace and the latest words. It follows the
/// meeting past Stop — transcribing, working out who spoke, the summary — and ends on its title.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            LockScreenCard(context: context)
                .activityBackgroundTint(Color.paper)
                .activitySystemActionForegroundColor(Color.ink)
                .widgetURL(context.state.isLive ? MinutesLink.record : MinutesLink.meeting(context.attributes.meetingID))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandStatus(state: state)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.isLive {
                        Clock(state: state)
                            .font(.system(size: 26, weight: .light, design: .serif).monospacedDigit())
                            .foregroundStyle(Color.ink)
                            .frame(maxWidth: 120, alignment: .trailing)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandDetail(state: state)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                StateMark(state: state, size: 12)
            } compactTrailing: {
                CompactTrailing(state: state)
            } minimal: {
                StateMark(state: state, size: 12)
            }
            .keylineTint(Color.margin)
            // While live, a tap goes back to the recording screen; afterwards, to the minutes.
            .widgetURL(state.isLive ? MinutesLink.record : MinutesLink.meeting(context.attributes.meetingID))
        }
        .supplementalActivityFamilies([.small])
    }
}

private extension RecordingAttributes.ContentState {
    var isLive: Bool { phase == .recording || phase == .paused }
}

// MARK: - Lock screen

private struct LockScreenCard: View {
    let context: ActivityViewContext<RecordingAttributes>
    @Environment(\.activityFamily) private var family

    private var state: RecordingAttributes.ContentState { context.state }

    var body: some View {
        if family == .small {
            SmallCard(state: state)
        } else {
            HStack(alignment: .top, spacing: 0) {
                // The margin: what state the meeting is in, and when it began.
                VStack(alignment: .trailing, spacing: Space.tight) {
                    StateMark(state: state, size: 12)
                        .padding(.top, 7)
                    if state.isLive {
                        Text(context.attributes.startedAt, style: .time)
                            .font(Typeface.note(.caption2).monospacedDigit())
                            .foregroundStyle(Color.pencil)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, Space.line)

                Rectangle()
                    .fill(Color.margin.opacity(0.55))
                    .frame(width: 1)

                page
                    .padding(.leading, Space.item)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, Space.row)
            .padding(.trailing, Space.row)
            .padding(.leading, Space.tight)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch state.phase {
        case .recording, .paused:
            VStack(alignment: .leading, spacing: Space.line) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.phase == .recording ? "Recording" : "Paused")
                        .font(Typeface.page(.headline, .semibold))
                        .foregroundStyle(Color.ink)
                    Spacer(minLength: Space.line)
                    Clock(state: state)
                        .font(.system(size: 30, weight: .light, design: .serif).monospacedDigit())
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 150, alignment: .trailing)
                }
                TraceShape(levels: state.levels, tick: state.tick)
                    .stroke(state.phase == .recording ? Color.ink : Color.pencil,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(height: 30)
                    .overlay(alignment: .trailing) {
                        Circle()
                            .fill(state.phase == .recording ? Color.margin : Color.pencil)
                            .frame(width: 7, height: 7)
                    }
                if !state.line.isEmpty {
                    Text(state.line)
                        .font(Typeface.page(.subheadline))
                        .foregroundStyle(Color.pencil)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
                LiveControls(state: state)
            }
        case .processing, .waiting:
            VStack(alignment: .leading, spacing: Space.line) {
                Text(state.phase == .waiting ? "Open Minutes to finish" : (state.stage ?? "Processing"))
                    .font(Typeface.page(.headline, .semibold))
                    .foregroundStyle(Color.ink)
                if state.phase == .processing {
                    InkBar(fraction: state.fraction)
                }
                Text(state.phase == .waiting
                    ? "Apple Intelligence writes the summary while Minutes is open."
                    : "\(lengthText(state.elapsed)) recorded")
                    .font(Typeface.note(.footnote))
                    .foregroundStyle(Color.pencil)
            }
        case .done:
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(state.title ?? "Minutes ready")
                    .font(Typeface.page(.headline, .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                if let summary = state.summary, !summary.isEmpty {
                    Text(summary)
                        .font(Typeface.page(.subheadline))
                        .foregroundStyle(Color.pencil)
                        .lineLimit(2)
                }
                Text("Tap to read the minutes")
                    .font(Typeface.note(.footnote, .medium))
                    .foregroundStyle(Color.ballpoint)
                    .padding(.top, Space.tight)
            }
        case .failed:
            VStack(alignment: .leading, spacing: Space.tight) {
                Text("Couldn't finish this meeting")
                    .font(Typeface.page(.headline, .semibold))
                    .foregroundStyle(Color.ink)
                Text(state.stage ?? "Open Minutes to see what happened. The recording is saved.")
                    .font(Typeface.note(.footnote))
                    .foregroundStyle(Color.pencil)
                    .lineLimit(3)
            }
        }
    }
}

/// Apple Watch Smart Stack and CarPlay: the margin dot and the clock, nothing else.
private struct SmallCard: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        HStack(spacing: Space.line) {
            StateMark(state: state, size: 10)
            if state.isLive {
                Clock(state: state)
                    .font(.system(.title3, design: .serif).monospacedDigit())
                    .foregroundStyle(Color.ink)
            } else {
                Text(state.phase == .done ? (state.title ?? "Minutes ready") : (state.stage ?? "Processing"))
                    .font(Typeface.page(.subheadline, .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
            }
        }
        .padding(Space.line)
    }
}

// MARK: - Dynamic Island

private struct IslandStatus: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        HStack(spacing: Space.line) {
            StateMark(state: state, size: 10)
            Text(title)
                .font(Typeface.page(.subheadline, .semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
        }
        .environment(\.colorScheme, .dark)
    }

    private var title: String {
        switch state.phase {
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .processing: return "Minutes"
        case .waiting: return "Minutes"
        case .done: return "Ready"
        case .failed: return "Minutes"
        }
    }
}

private struct IslandDetail: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        Group {
            switch state.phase {
            case .recording, .paused:
                VStack(alignment: .leading, spacing: Space.line) {
                    TraceShape(levels: state.levels, tick: state.tick)
                        .stroke(state.phase == .recording ? Color.ink : Color.pencil,
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(height: 26)
                    if !state.line.isEmpty {
                        Text(state.line)
                            .font(Typeface.page(.footnote))
                            .foregroundStyle(Color.pencil)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    LiveControls(state: state)
                }
            case .processing, .waiting:
                VStack(alignment: .leading, spacing: Space.line) {
                    Text(state.phase == .waiting ? "Open Minutes to finish the summary" : (state.stage ?? "Processing"))
                        .font(Typeface.page(.subheadline, .semibold))
                        .foregroundStyle(Color.ink)
                    if state.phase == .processing { InkBar(fraction: state.fraction) }
                }
            case .done:
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text(state.title ?? "Minutes ready")
                        .font(Typeface.page(.subheadline, .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    if let summary = state.summary {
                        Text(summary)
                            .font(Typeface.page(.footnote))
                            .foregroundStyle(Color.pencil)
                            .lineLimit(2)
                    }
                }
            case .failed:
                Text(state.stage ?? "Couldn't finish. Open Minutes to see why.")
                    .font(Typeface.note(.footnote))
                    .foregroundStyle(Color.pencil)
            }
        }
        // The Island is always black; the night inks read on it regardless of the phone's mode.
        .environment(\.colorScheme, .dark)
    }
}

private struct CompactTrailing: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        Group {
            switch state.phase {
            case .recording, .paused:
                Clock(state: state)
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(state.phase == .recording ? Color.margin : Color.pencil)
                    .multilineTextAlignment(.trailing)
                    // A fixed width, or the Island resizes every time a digit changes.
                    .frame(width: 52, alignment: .trailing)
            case .processing:
                Text(state.fraction.map { "\(Int($0 * 100))%" } ?? "···")
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.ink)
                    .frame(width: 44, alignment: .trailing)
            case .waiting:
                Image(systemName: "hand.tap")
                    .foregroundStyle(Color.ink)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Ink.color(for: "2"))
            case .failed:
                Image(systemName: "exclamationmark")
                    .foregroundStyle(Color.margin)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Parts

/// The margin's mark: a red dot while recording, grey while paused, a tick when done.
private struct StateMark: View {
    let state: RecordingAttributes.ContentState
    let size: CGFloat

    var body: some View {
        switch state.phase {
        case .recording:
            Circle().fill(Color.margin).frame(width: size, height: size)
                .accessibilityLabel("Recording")
        case .paused:
            Circle().fill(Color.pencil).frame(width: size, height: size)
                .accessibilityLabel("Paused")
        case .processing, .waiting:
            Image(systemName: "pencil.line")
                .font(.system(size: size + 2, weight: .semibold))
                .foregroundStyle(Color.ballpoint)
                .accessibilityLabel("Processing")
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: size + 1, weight: .bold))
                .foregroundStyle(Ink.color(for: "2"))
                .accessibilityLabel("Ready")
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.margin)
                .accessibilityLabel("Problem")
        }
    }
}

/// The elapsed time, counted on by the system between updates; pauses don't count.
private struct Clock: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        Text(
            timerInterval: state.clockStart...Date.distantFuture,
            pauseTime: state.phase == .paused ? state.asOf : nil,
            countsDown: false,
            showsHours: true
        )
    }
}

/// Pause/Resume run in the app without opening it; Stop opens Minutes, which then processes.
private struct LiveControls: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        HStack(spacing: Space.item) {
            if state.phase == .recording {
                Button(intent: PauseRecordingIntent()) {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(CardButtonStyle(filled: false))
            } else {
                Button(intent: ResumeRecordingIntent()) {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(CardButtonStyle(filled: false))
            }
            Link(destination: MinutesLink.stop) {
                Label("Stop", systemImage: "stop.fill")
                    .modifier(CardButtonLabel(filled: true))
            }
        }
        .padding(.top, Space.tight)
    }
}

private struct CardButtonStyle: ButtonStyle {
    let filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(CardButtonLabel(filled: filled))
    }
}

private struct CardButtonLabel: ViewModifier {
    let filled: Bool
    func body(content: Content) -> some View {
        content
            .font(Typeface.note(.subheadline, .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(filled ? Color.paper : Color.ink)
            .padding(.horizontal, Space.row)
            .padding(.vertical, Space.line)
            .background {
                if filled {
                    Capsule().fill(Color.margin)
                } else {
                    Capsule().strokeBorder(Color.ink.opacity(0.35), lineWidth: 1.2)
                }
            }
    }
}

/// Progress as an inked line; a dotted rule while the stage can't say how far it is.
private struct InkBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.rule)
                if let fraction {
                    Capsule().fill(Color.ballpoint)
                        .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
                } else {
                    Capsule()
                        .stroke(Color.ballpoint, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 6]))
                }
            }
        }
        .frame(height: 3)
    }
}

/// The pen trace as a Shape: Live Activities are rendered from archived views, where Canvas
/// doesn't draw. One wandering line, as in the app.
struct TraceShape: Shape {
    let levels: [UInt8]
    let tick: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let baseline = rect.midY
        guard levels.count > 1 else {
            path.move(to: CGPoint(x: rect.minX, y: baseline))
            path.addLine(to: CGPoint(x: rect.maxX - 6, y: baseline))
            return path
        }
        let amplitude = rect.height / 2 - 2
        let step = (rect.width - 6) / CGFloat(levels.count - 1)
        var points: [CGPoint] = []
        for (i, level) in levels.enumerated() {
            let absolute = tick - (levels.count - 1 - i)
            let y = baseline - CGFloat(level) / 255 * amplitude * wiggle(absolute)
            points.append(CGPoint(x: rect.minX + CGFloat(i) * step, y: y))
        }
        path.move(to: points[0])
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private func wiggle(_ n: Int) -> CGFloat {
        let sign: CGFloat = n.isMultiple(of: 2) ? 1 : -1
        var x = UInt64(truncatingIfNeeded: n &* 2_654_435_761)
        x ^= x >> 13
        x = x &* 0x5bd1e995
        x ^= x >> 15
        return sign * (0.45 + 0.55 * CGFloat(x % 1000) / 1000)
    }
}

private func lengthText(_ seconds: TimeInterval) -> String {
    let minutes = Int((seconds / 60).rounded())
    if seconds < 60 { return "\(max(1, Int(seconds))) seconds" }
    if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
    return "\(minutes / 60) h \(minutes % 60) min"
}
