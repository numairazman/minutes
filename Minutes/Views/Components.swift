import MinutesCore
import SwiftUI

extension PipelineStage {
    /// What's happening, in words. The percentage is drawn by `InkProgress` instead.
    var headline: String {
        switch self {
        case .transcribing: return "Transcribing"
        case .identifyingSpeakers: return "Working out who spoke"
        case .summarizing(let detail): return detail.replacingOccurrences(of: "…", with: "")
        case .remote(let detail, _): return detail.replacingOccurrences(of: "…", with: "")
        }
    }

    var fraction: Double? {
        switch self {
        case .transcribing(let f), .identifyingSpeakers(let f), .remote(_, let f):
            return f > 0 ? f : nil
        case .summarizing:
            return nil
        }
    }
}

extension Meeting {
    /// "17 minutes", "1 hour 5 minutes", "40 seconds".
    var lengthText: String {
        let minutes = Int((duration / 60).rounded())
        if duration < 60 { return "\(max(1, Int(duration.rounded()))) seconds" }
        if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let h = minutes / 60, m = minutes % 60
        let hours = h == 1 ? "1 hour" : "\(h) hours"
        return m == 0 ? hours : "\(hours) \(m) min"
    }

    /// Short form for the margin: "17 min", "1 h 5".
    var shortLength: String {
        let minutes = Int((duration / 60).rounded())
        if duration < 60 { return "\(max(1, Int(duration.rounded()))) sec" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60)"
    }

    var peopleText: String? {
        switch speakers.count {
        case 0: return nil
        case 1: return "1 person"
        default: return "\(speakers.count) people"
        }
    }

    /// The line under a title in the list: the summary if there is one, else how it begins.
    var excerpt: String? {
        if let overview = summary?.overview, !overview.isEmpty { return overview }
        return utterances.first?.text
    }
}

/// "Today", "Yesterday", "Thursday", or "Monday, 12 October" further back.
func dayHeading(for date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day, days < 7 {
        return date.formatted(.dateTime.weekday(.wide))
    }
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
    return sameYear
        ? date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        : date.formatted(.dateTime.day().month(.wide).year())
}

/// A meeting's state, written as a note: an icon in the margin, words on the page, and an ink
/// line filling up while it's being processed. Red only for something that needs the user.
struct StatusNote: View {
    let meeting: Meeting
    let stage: PipelineStage?
    var compact = false

    var body: some View {
        if let stage {
            VStack(alignment: .leading, spacing: 6) {
                Text(stage.headline)
                    .font(Typeface.note(compact ? .footnote : .subheadline, .medium))
                    .foregroundStyle(Color.ink)
                InkProgress(fraction: stage.fraction)
                    .frame(maxWidth: compact ? 160 : .infinity)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(stage.label)
        } else {
            switch meeting.status {
            case .processing:
                note("Waiting its turn", icon: "hourglass", color: .pencil)
            case .interrupted:
                note("Cut off when the app closed. The audio up to then is safe.", icon: "exclamationmark.circle", color: .margin)
            case .failed:
                note(meeting.processingError ?? "Couldn't transcribe this one.", icon: "exclamationmark.triangle", color: .margin)
            case .recording:
                note("Recording", icon: "record.circle", color: .margin)
            case .ready:
                EmptyView()
            }
        }
    }

    private func note(_ text: String, icon: String, color: Color) -> some View {
        Label {
            Text(text).lineLimit(compact ? 2 : nil)
        } icon: {
            Image(systemName: icon)
        }
        .font(Typeface.note(compact ? .footnote : .subheadline))
        .foregroundStyle(color)
    }
}

/// Exported lazily as a .txt file, so the share sheet offers Save to Files, OneDrive (when its
/// app is installed), Mail, Messages, AirDrop — with a real file name rather than "text.txt".
struct TranscriptFile: Transferable {
    let meeting: Meeting
    let options: ExportOptions

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .utf8PlainText) { item in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(TranscriptExporter.fileName(for: item.meeting))
            try TranscriptExporter.text(for: item.meeting, options: item.options).write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
