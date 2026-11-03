import ActivityKit
import Foundation
import MinutesCore

/// Starts, updates and ends the meeting's Live Activity.
///
/// Updates are throttled to one every 2.5 s while recording (the trace and latest words), and
/// sent at once when the phase changes. `Activity.request` only works with the app in the
/// foreground, which is true for every way a recording starts: the Record key, the widget and
/// the Control all open the app first.
@MainActor
final class RecordingActivityController {
    static let shared = RecordingActivityController()

    private var activity: Activity<RecordingAttributes>?
    private var state: RecordingAttributes.ContentState?
    private var lastPush = Date.distantPast
    private static let recordingInterval: TimeInterval = 2.5

    /// The meeting the current activity belongs to, if any.
    var meetingID: UUID? { activity?.attributes.meetingID }

    /// A crash or a kill mid-meeting leaves the old card on the lock screen ("Recording 1:12:08")
    /// for hours. Nothing is recording at launch, so end whatever is there.
    func endLeftovers() async {
        // Skip our own: a cold launch from the Record control can start one before this runs.
        for leftover in Activity<RecordingAttributes>.activities where leftover.id != activity?.id {
            await leftover.end(nil, dismissalPolicy: .immediate)
        }
    }

    func start(meetingID: UUID, startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RecordingAttributes.ContentState(phase: .recording, elapsed: 0, asOf: Date())
        do {
            activity = try Activity.request(
                attributes: RecordingAttributes(meetingID: meetingID, startedAt: startedAt),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            self.state = state
            lastPush = Date()
        } catch {
            print("[LiveActivity] couldn't start: \(error)")
        }
    }

    /// Called from the recorder's meter (20 times a second); pushes at most every 2.5 s unless
    /// `force` (pause, resume, interruption).
    func recording(elapsed: TimeInterval, paused: Bool, levels: [Float], tick: Int, line: @autoclosure () -> String, force: Bool = false) {
        guard activity != nil, var state else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastPush) >= Self.recordingInterval else { return }
        state.phase = paused ? .paused : .recording
        state.elapsed = elapsed
        state.asOf = now
        state.levels = Self.downsample(levels, to: 48)
        state.tick = tick / max(1, levels.count / 48)
        state.line = Self.tail(line(), 110)
        push(state)
    }

    /// After Stop: the stage the pipeline reports, or "Waiting its turn" before it starts.
    func processing(_ stage: PipelineStage?, for meetingID: UUID, force: Bool = false) {
        guard self.meetingID == meetingID, var state else { return }
        state.phase = .processing
        state.stage = stage?.headline ?? "Waiting its turn"
        state.fraction = stage?.fraction
        state.levels = []
        state.line = ""
        // Stages change several times a second during transcription; the card needs no more
        // than a step every couple of seconds.
        let changed = state.stage != self.state?.stage || self.state?.phase != .processing
        guard force || changed || Date().timeIntervalSince(lastPush) >= Self.recordingInterval else { return }
        push(state)
    }

    /// The app went to the background mid-processing. Apple Intelligence won't run there and
    /// transcription is suspended soon after, so say so instead of freezing at a percentage.
    func waitingForApp() {
        guard var state, state.phase == .processing else { return }
        state.phase = .waiting
        push(state, staleIn: 60)
    }

    func done(_ meeting: Meeting) {
        guard self.meetingID == meeting.id, let activity, var state else { return }
        if meeting.status == .failed {
            state.phase = .failed
            state.stage = meeting.processingError
        } else {
            state.phase = .done
            state.title = meeting.title
            state.summary = meeting.summary.map { Self.firstSentence($0.overview) } ?? meeting.utterances.first.map { Self.tail($0.text, 110) }
            state.stage = nil
            state.fraction = nil
        }
        state.asOf = Date()
        let final = state
        self.activity = nil
        self.state = nil
        Task {
            // Stays on the lock screen a while so the summary can be picked up from there.
            await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(15 * 60)))
        }
    }

    func discard() {
        guard let activity else { return }
        self.activity = nil
        state = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - Helpers

    private func push(_ state: RecordingAttributes.ContentState, staleIn: TimeInterval? = nil) {
        guard let activity else { return }
        self.state = state
        lastPush = Date()
        let content = ActivityContent(state: state, staleDate: staleIn.map { Date().addingTimeInterval($0) })
        Task { await activity.update(content) }
    }

    /// Peak per group, so a short word still shows as a stroke after downsampling.
    private static func downsample(_ levels: [Float], to count: Int) -> [UInt8] {
        guard !levels.isEmpty else { return [] }
        let group = max(1, levels.count / count)
        return stride(from: 0, to: levels.count, by: group).map { start in
            let peak = levels[start..<min(levels.count, start + group)].max() ?? 0
            return UInt8(max(0, min(255, (peak * 255).rounded())))
        }
    }

    private static func tail(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let cut = trimmed.suffix(limit)
        // Start at a word, not mid-word.
        if let space = cut.firstIndex(of: " ") { return "…" + cut[cut.index(after: space)...] }
        return "…" + cut
    }

    private static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = trimmed.firstIndex(where: { ".!?".contains($0) }) {
            return String(trimmed[...end])
        }
        return tail(trimmed, 140)
    }
}
