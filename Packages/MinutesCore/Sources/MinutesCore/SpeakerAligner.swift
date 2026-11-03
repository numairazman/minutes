import Foundation

/// Joins the transcriber's timed words with the diarizer's speaker turns.
///
/// The two models run independently, so their boundaries never line up exactly: a turn often
/// ends a few hundred milliseconds before or after the last word of it. Assignment is
/// therefore per *word* (by largest time overlap), never per transcriber result — one result
/// can easily span a change of speaker.
public enum SpeakerAligner {
    /// A word with no overlapping turn takes the nearest turn within this many seconds,
    /// otherwise it inherits its neighbour's speaker.
    static let nearestTurnTolerance = 1.0
    /// Short "islands" — a word or two attributed to someone else in the middle of one
    /// person's turn — are almost always boundary jitter, not a real interjection.
    static let islandMaxWords = 2
    static let islandMaxDuration = 0.8
    /// Same-speaker speech is split into a new paragraph after a pause this long.
    static let paragraphPause = 3.0

    public static func utterances(words: [TimedWord], turns: [SpeakerTurn]) -> [Utterance] {
        guard !words.isEmpty else { return [] }
        let sortedTurns = turns.sorted { $0.start < $1.start }
        // Running maximum of turn ends. Turns are sorted by start but overlap and vary in
        // length (one person talking for ten minutes is a single turn), so ends aren't sorted;
        // their running maximum is, which makes it binary-searchable.
        var maxEnd: [Double] = []
        maxEnd.reserveCapacity(sortedTurns.count)
        for turn in sortedTurns { maxEnd.append(max(maxEnd.last ?? -.infinity, turn.end)) }

        var speakers: [String?] = words.map { speaker(for: $0, in: sortedTurns, maxEnd: maxEnd) }
        fillGaps(&speakers)
        var labels = speakers.map { $0 ?? "1" }
        smoothIslands(&labels, words: words)
        labels = renumber(labels)

        var result: [Utterance] = []
        var startIndex = 0
        for i in 1...words.count {
            let isEnd = i == words.count
            let breaks = isEnd
                || labels[i] != labels[startIndex]
                || words[i].start - words[i - 1].end >= paragraphPause
            guard breaks else { continue }
            let slice = words[startIndex..<i]
            let text = joinedText(slice)
            if !text.isEmpty {
                result.append(Utterance(
                    id: result.count,
                    speaker: labels[startIndex],
                    start: slice.first!.start,
                    end: slice.last!.end,
                    text: text
                ))
            }
            startIndex = i
        }
        return result
    }

    public static func joinedText<S: Sequence>(_ words: S) -> String where S.Element == TimedWord {
        let raw = words.map(\.text).joined()
        return raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Steps

    private static func speaker(for word: TimedWord, in turns: [SpeakerTurn], maxEnd: [Double]) -> String? {
        var best: (speaker: String, overlap: Double)?
        var nearest: (speaker: String, gap: Double)?
        // Every turn before this index ended too early to matter.
        var i = firstIndex(in: maxEnd, atLeast: word.start - nearestTurnTolerance)
        while i < turns.count, turns[i].start <= word.end + nearestTurnTolerance {
            let turn = turns[i]
            let overlap = min(word.end, turn.end) - max(word.start, turn.start)
            if overlap > 0 {
                if overlap > (best?.overlap ?? 0) { best = (turn.speaker, overlap) }
            } else {
                let gap = max(turn.start - word.end, word.start - turn.end)
                if gap < (nearest?.gap ?? .infinity) { nearest = (turn.speaker, gap) }
            }
            i += 1
        }
        if let best { return best.speaker }
        if let nearest, nearest.gap <= nearestTurnTolerance { return nearest.speaker }
        return nil
    }

    private static func firstIndex(in sorted: [Double], atLeast value: Double) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func fillGaps(_ speakers: inout [String?]) {
        var previous: String?
        for i in speakers.indices {
            if let s = speakers[i] { previous = s } else { speakers[i] = previous }
        }
        // Leading words before anyone was detected take the first detected speaker.
        if let firstKnown = speakers.first(where: { $0 != nil }) ?? nil {
            for i in speakers.indices {
                guard speakers[i] == nil else { break }
                speakers[i] = firstKnown
            }
        }
    }

    private static func smoothIslands(_ labels: inout [String], words: [TimedWord]) {
        var runs: [(speaker: String, range: Range<Int>)] = []
        var start = 0
        for i in 1...labels.count where i == labels.count || labels[i] != labels[start] {
            runs.append((labels[start], start..<i))
            start = i
        }
        guard runs.count >= 3 else { return }
        for r in 1..<(runs.count - 1) {
            let run = runs[r]
            let before = runs[r - 1].speaker, after = runs[r + 1].speaker
            let duration = words[run.range.upperBound - 1].end - words[run.range.lowerBound].start
            if before == after, run.range.count <= islandMaxWords, duration <= islandMaxDuration {
                for i in run.range { labels[i] = before }
            }
        }
    }

    /// Diarizer ids ("S3", "speaker_0") become "1", "2", … in order of first appearance.
    private static func renumber(_ labels: [String]) -> [String] {
        var map: [String: String] = [:]
        return labels.map { label in
            if let mapped = map[label] { return mapped }
            let mapped = String(map.count + 1)
            map[label] = mapped
            return mapped
        }
    }
}
