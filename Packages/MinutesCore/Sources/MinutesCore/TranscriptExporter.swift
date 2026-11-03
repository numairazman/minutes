import Foundation

public struct ExportOptions: Sendable {
    public var includeSummary: Bool
    public var includeTimestamps: Bool

    public init(includeSummary: Bool = true, includeTimestamps: Bool = true) {
        self.includeSummary = includeSummary
        self.includeTimestamps = includeTimestamps
    }
}

/// Plain UTF-8 text — opens anywhere (OneDrive, Word, Notes, email) with no conversion.
public enum TranscriptExporter {
    public static func text(for meeting: Meeting, options: ExportOptions = .init()) -> String {
        var out: [String] = []
        out.append(meeting.title)
        var meta = [meeting.createdAt.formatted(date: .complete, time: .shortened)]
        if meeting.duration > 0 { meta.append(durationText(meeting.duration)) }
        out.append(meta.joined(separator: " · "))
        let speakers = meeting.speakers.map { meeting.displayName(forSpeaker: $0) }
        if !speakers.isEmpty { out.append("Speakers: " + speakers.joined(separator: ", ")) }

        if options.includeSummary, let summary = meeting.summary {
            out.append("")
            out.append("SUMMARY")
            out.append("")
            out.append(summary.overview)
            section("Key points", summary.keyPoints, into: &out)
            section("Decisions", summary.decisions, into: &out)
            section("Action items", summary.actionItems, into: &out)
        }

        out.append("")
        out.append("TRANSCRIPT")
        if meeting.utterances.isEmpty {
            out.append("")
            out.append(meeting.words.isEmpty ? "(No speech was detected.)" : SpeakerAligner.joinedText(meeting.words))
        }
        for utterance in meeting.utterances {
            out.append("")
            let name = meeting.displayName(forSpeaker: utterance.speaker)
            out.append(options.includeTimestamps ? "[\(timestamp(utterance.start))] \(name):" : "\(name):")
            out.append(utterance.text)
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Transcript as "Name: text" lines, the form the summarizer reads.
    public static func speakerLines(for meeting: Meeting) -> [String] {
        meeting.utterances.map { "\(meeting.displayName(forSpeaker: $0.speaker)): \($0.text)" }
    }

    /// e.g. "Weekly sync 2026-11-02.txt". Characters OneDrive and Windows reject are removed.
    public static func fileName(for meeting: Meeting) -> String {
        let day = meeting.createdAt.formatted(.iso8601.year().month().day())
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|#%").union(.newlines).union(.controlCharacters)
        let title = meeting.title.components(separatedBy: forbidden).joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        let base = title.isEmpty ? "Meeting" : String(title.prefix(80))
        return base.contains(day) ? "\(base).txt" : "\(base) \(day).txt"
    }

    public static func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    public static func durationText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "\(Int(seconds.rounded())) sec" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    private static func section(_ title: String, _ items: [String], into out: inout [String]) {
        guard !items.isEmpty else { return }
        out.append("")
        out.append(title)
        for item in items { out.append("- " + item) }
    }
}
