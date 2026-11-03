import ActivityKit
import Foundation

/// The Live Activity for a meeting, from the moment Record is pressed until its summary is
/// written. Compiled into both the app (which starts and updates it) and the widget extension
/// (which draws it).
struct RecordingAttributes: ActivityAttributes {
    var meetingID: UUID
    var startedAt: Date

    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording, paused
            /// Stopped; transcribing, identifying speakers or summarizing.
            case processing
            /// Processing can't continue while the app is in the background (Apple Intelligence
            /// won't run there), so the card says so instead of freezing at a percentage.
            case waiting
            case done, failed
        }

        var phase: Phase
        /// Recorded time as of `asOf`. The lock screen counts on from there by itself.
        var elapsed: TimeInterval
        var asOf: Date
        /// The last few seconds of input level, 0…255, oldest first — the pen trace.
        var levels: [UInt8] = []
        /// Samples taken so far, so each one keeps its up/down wiggle as the trace scrolls.
        var tick: Int = 0
        /// The tail of the live transcript.
        var line: String = ""
        /// Processing: what's happening ("Transcribing") and how far, if known.
        var stage: String?
        var fraction: Double?
        /// Done: the meeting's title and the first sentence of its summary.
        var title: String?
        var summary: String?

        /// The range for `Text(timerInterval:)`: starts where the clock would have started had
        /// it never been paused, so pauses don't count.
        var clockStart: Date { asOf.addingTimeInterval(-elapsed) }
    }
}

/// Deep links shared by the Live Activity, the widgets and the Control.
enum MinutesLink {
    static let record = URL(string: "minutes://record")!
    static let stop = URL(string: "minutes://stop")!
    static func meeting(_ id: UUID) -> URL { URL(string: "minutes://meeting/\(id.uuidString)")! }
}
