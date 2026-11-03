import Foundation

/// One transcribed word (or token) with its position in the recording.
public struct TimedWord: Codable, Hashable, Sendable {
    /// The text exactly as the transcriber produced it, including any leading space, so
    /// concatenating consecutive words reproduces the sentence without re-guessing spacing.
    public var text: String
    /// Seconds from the start of the recording.
    public var start: Double
    public var end: Double
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// A stretch of audio the diarizer attributed to one voice.
public struct SpeakerTurn: Codable, Hashable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// A paragraph of the finished transcript: consecutive words from one speaker.
public struct Utterance: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    /// Stable speaker key ("1", "2", …) numbered by who spoke first. Display names live in
    /// `Meeting.speakerNames` so renaming never rewrites the transcript.
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: Int, speaker: String, start: Double, end: Double, text: String) {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct MeetingSummary: Codable, Hashable, Sendable {
    public var title: String
    public var overview: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [String]
    public var generatedAt: Date
    /// Set when part of the meeting couldn't be summarized (Apple Intelligence refused it), so
    /// the reader knows the summary has a gap. Optional, so older saved summaries still decode.
    public var caveat: String?
    /// Who wrote this summary. Every summary so far has been Apple Intelligence on the iPhone, so
    /// a summary saved before this field existed reads as that.
    public var source: Source?

    public enum Source: String, Codable, Sendable {
        case appleIntelligence
        case pc
    }

    public init(title: String, overview: String, keyPoints: [String], decisions: [String], actionItems: [String], generatedAt: Date = Date(), caveat: String? = nil, source: Source? = .appleIntelligence) {
        self.title = title
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.generatedAt = generatedAt
        self.caveat = caveat
        self.source = source
    }
}

public struct Meeting: Codable, Hashable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case recording
        case processing
        case ready
        /// The app was killed mid-recording. The audio written so far is intact and can
        /// still be processed from the file.
        case interrupted
        /// Transcription itself failed. The audio is kept so it can be retried.
        case failed
    }

    public var id: UUID
    public var title: String
    /// Set once the user renames the meeting, so a later summary doesn't overwrite it.
    public var titleIsCustom: Bool
    public var createdAt: Date
    public var duration: Double
    public var status: Status
    /// File name inside the meeting's folder.
    public var audioFileName: String?
    public var localeIdentifier: String
    public var words: [TimedWord]
    public var speakerTurns: [SpeakerTurn]
    public var utterances: [Utterance]
    public var speakerNames: [String: String]
    /// The user's hint for the diarizer. `nil` lets it decide.
    public var expectedSpeakers: Int?
    public var summary: MeetingSummary?
    public var processingError: String?
    public var speakerError: String?
    public var summaryError: String?
    /// What produced the words and speakers when it wasn't this device, e.g.
    /// "WhisperX large-v3 + speaker-diarization-community-1" after re-processing on the PC.
    public var transcriptEngine: String?
    /// Why re-processing on the PC failed. The transcript from before is kept.
    public var serverError: String?

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), localeIdentifier: String, status: Status = .recording) {
        self.id = id
        self.title = title
        self.titleIsCustom = false
        self.createdAt = createdAt
        self.duration = 0
        self.status = status
        self.audioFileName = nil
        self.localeIdentifier = localeIdentifier
        self.words = []
        self.speakerTurns = []
        self.utterances = []
        self.speakerNames = [:]
        self.expectedSpeakers = nil
        self.summary = nil
        self.processingError = nil
        self.speakerError = nil
        self.summaryError = nil
        self.transcriptEngine = nil
        self.serverError = nil
    }

    // Every field but the identity decodes with a default, so meetings saved by an older
    // build still open after a field is added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Meeting"
        titleIsCustom = try c.decodeIfPresent(Bool.self, forKey: .titleIsCustom) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .ready
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        localeIdentifier = try c.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? Locale.current.identifier
        words = try c.decodeIfPresent([TimedWord].self, forKey: .words) ?? []
        speakerTurns = try c.decodeIfPresent([SpeakerTurn].self, forKey: .speakerTurns) ?? []
        utterances = try c.decodeIfPresent([Utterance].self, forKey: .utterances) ?? []
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        expectedSpeakers = try c.decodeIfPresent(Int.self, forKey: .expectedSpeakers)
        summary = try c.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        processingError = try c.decodeIfPresent(String.self, forKey: .processingError)
        speakerError = try c.decodeIfPresent(String.self, forKey: .speakerError)
        summaryError = try c.decodeIfPresent(String.self, forKey: .summaryError)
        transcriptEngine = try c.decodeIfPresent(String.self, forKey: .transcriptEngine)
        serverError = try c.decodeIfPresent(String.self, forKey: .serverError)
    }

    public func displayName(forSpeaker key: String) -> String {
        if let name = speakerNames[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "Speaker \(key)"
    }

    /// Speaker keys in order of first appearance.
    public var speakers: [String] {
        var seen = Set<String>()
        return utterances.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }

    public static func defaultTitle(for date: Date) -> String {
        "Meeting – " + date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

// MARK: - Where each part came from

extension Meeting {
    /// The PC's engine in words: "Whisper large-v3 with pyannote speaker detection".
    private var pcEngine: String? {
        guard let engine = transcriptEngine else { return nil }
        var readable = engine.replacingOccurrences(of: "WhisperX ", with: "Whisper ")
        if let plus = readable.range(of: " + ") {
            readable = readable[..<plus.lowerBound] + " with pyannote speaker detection"
        }
        return readable
    }

    /// Where the transcript and speakers came from, e.g. "your PC (Whisper large-v3 with …)".
    public var transcriptSource: String {
        pcEngine.map { "your PC (\($0))" } ?? "this iPhone"
    }

    /// Who wrote the summary, or nil if there isn't one.
    public var summarySource: String? {
        guard let summary else { return nil }
        switch summary.source ?? .appleIntelligence {
        case .appleIntelligence: return "Apple Intelligence on this iPhone"
        case .pc: return "your PC"
        }
    }

    /// One accurate sentence about what made this meeting's minutes: all on the iPhone, the
    /// transcript on the PC and the summary on the iPhone, or all on the PC.
    public var provenance: String {
        let summaryOnPhone = summary.map { ($0.source ?? .appleIntelligence) == .appleIntelligence }
        switch (pcEngine, summaryOnPhone) {
        case (nil, true?):
            return "Made entirely on this iPhone: the transcript by Apple's speech recognition, who spoke by on-device speaker detection, and this summary by Apple Intelligence."
        case (let engine?, true?):
            return "The transcript and speakers came from your PC (\(engine)). This summary was written on this iPhone by Apple Intelligence."
        case (let engine?, false?):
            return "The transcript, speakers and this summary all came from your PC (\(engine))."
        case (nil, false?):
            return "The transcript and speakers were made on this iPhone. This summary came from your PC."
        case (nil, nil):
            return "Transcript and speakers made on this iPhone by Apple's speech recognition and on-device speaker detection."
        case (let engine?, nil):
            return "Transcript and speakers from your PC (\(engine))."
        }
    }
}
