import Foundation

public struct PipelineSettings: Sendable {
    public var locale: Locale
    /// Names, acronyms and jargon to bias the transcriber toward.
    public var vocabulary: [String]
    public var summarize: Bool

    public init(locale: Locale, vocabulary: [String] = [], summarize: Bool = true) {
        self.locale = locale
        self.vocabulary = vocabulary
        self.summarize = summarize
    }
}

public enum PipelineStage: Equatable, Sendable {
    case transcribing(Double)
    case identifyingSpeakers(Double)
    case summarizing(String)
    /// Re-processing on the PC: a label ("Transcribing on PC…") and how far that step is.
    case remote(String, Double)

    public var label: String {
        switch self {
        case .transcribing(let fraction):
            return fraction > 0 ? "Transcribing… \(Int(fraction * 100))%" : "Transcribing…"
        case .identifyingSpeakers(let fraction):
            return fraction > 0 ? "Identifying speakers… \(Int(fraction * 100))%" : "Identifying speakers…"
        case .summarizing(let detail):
            return detail
        case .remote(let detail, let fraction):
            return fraction > 0 ? "\(detail) \(Int(fraction * 100))%" : detail
        }
    }

    public var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}

/// After a recording stops (or a file is imported): transcribe if needed → identify speakers →
/// align → summarize. The same path serves both, so imports exercise exactly what recordings do.
///
/// Each stage fails on its own: no speakers still leaves a transcript, no summary still leaves
/// speakers. Only a failed transcription marks the meeting failed, and the audio is kept for a retry.
public enum MeetingPipeline {
    public static func process(
        _ meeting: Meeting,
        audioURL: URL,
        liveWords: [TimedWord]?,
        settings: PipelineSettings,
        stage: @escaping @Sendable (PipelineStage) -> Void
    ) async -> Meeting {
        var meeting = meeting
        meeting.processingError = nil
        if meeting.duration <= 0 { meeting.duration = AudioFiles.duration(of: audioURL) }

        if let liveWords, !liveWords.isEmpty {
            meeting.words = liveWords
        } else {
            stage(.transcribing(0))
            do {
                meeting.words = try await FileTranscriber.transcribe(
                    url: audioURL, locale: settings.locale, vocabulary: settings.vocabulary,
                    progress: { stage(.transcribing($0)) }
                )
            } catch {
                meeting.processingError = error.localizedDescription
                meeting.status = .failed
                return meeting
            }
        }
        meeting.transcriptEngine = nil

        if Task.isCancelled { return meeting }
        stage(.identifyingSpeakers(0))
        meeting = await identifySpeakers(meeting, audioURL: audioURL) { stage(.identifyingSpeakers($0)) }

        if settings.summarize, !Task.isCancelled {
            meeting = await summarize(meeting, stage: stage)
        }
        meeting.status = .ready
        return meeting
    }

    /// Also used on its own when the user corrects the number of speakers — the words don't
    /// change, so there is no need to transcribe again.
    public static func identifySpeakers(
        _ meeting: Meeting,
        audioURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> Meeting {
        var meeting = meeting
        meeting.speakerError = nil
        guard !meeting.words.isEmpty else {
            meeting.speakerTurns = []
            meeting.utterances = []
            return meeting
        }
        do {
            meeting.speakerTurns = try await SpeakerDiarizer.shared.turns(
                for: audioURL, expectedSpeakers: meeting.expectedSpeakers, progress: progress
            )
        } catch {
            meeting.speakerTurns = []
            meeting.speakerError = "Speakers couldn't be identified: \(error.localizedDescription)"
        }
        let previous = Set(meeting.speakers)
        meeting.utterances = SpeakerAligner.utterances(words: meeting.words, turns: meeting.speakerTurns)
        // Names given to speakers that no longer exist after a re-run would silently attach to
        // whoever now has that number; drop them unless the set of speakers is unchanged.
        if Set(meeting.speakers) != previous { meeting.speakerNames = [:] }
        return meeting
    }

    /// The opt-in "maximum accuracy" tier: the PC's WhisperX server transcribes and identifies
    /// speakers again, then words are matched to speakers and summarized here, exactly as after
    /// on-device processing. If the PC fails, the meeting keeps the transcript it had.
    public static func reprocessOnServer(
        _ meeting: Meeting,
        audioURL: URL,
        server: AccuracyServer,
        settings: PipelineSettings,
        stage: @escaping @Sendable (PipelineStage) -> Void
    ) async -> Meeting {
        var meeting = meeting
        meeting.serverError = nil
        let transcript: AccuracyServer.Transcript
        do {
            transcript = try await server.transcribe(
                audioURL: audioURL,
                language: Locale(identifier: meeting.localeIdentifier).language.languageCode?.identifier,
                speakers: meeting.expectedSpeakers,
                vocabulary: settings.vocabulary,
                progress: { stage(.remote($0, $1)) }
            )
        } catch is CancellationError {
            return meeting
        } catch {
            meeting.serverError = error.localizedDescription
            return meeting
        }
        let previous = Set(meeting.speakers)
        meeting.words = transcript.words
        meeting.speakerTurns = transcript.turns
        meeting.utterances = SpeakerAligner.utterances(words: meeting.words, turns: meeting.speakerTurns)
        meeting.transcriptEngine = transcript.engine ?? "PC"
        meeting.processingError = nil
        meeting.speakerError = nil
        meeting.status = .ready
        // Same rule as identifySpeakers: names only survive if the set of speakers is unchanged.
        if Set(meeting.speakers) != previous { meeting.speakerNames = [:] }
        if settings.summarize, !Task.isCancelled {
            meeting = await summarize(meeting, stage: stage)
        }
        return meeting
    }

    public static func summarize(_ meeting: Meeting, stage: @escaping @Sendable (PipelineStage) -> Void) async -> Meeting {
        var meeting = meeting
        meeting.summaryError = nil
        guard !meeting.utterances.isEmpty else { return meeting }
        stage(.summarizing("Summarizing…"))
        do {
            let summary = try await MeetingSummarizer.summarize(
                lines: TranscriptExporter.speakerLines(for: meeting),
                progress: { stage(.summarizing($0)) }
            )
            meeting.summary = summary
            if !meeting.titleIsCustom, !summary.title.isEmpty { meeting.title = summary.title }
        } catch {
            meeting.summaryError = error.localizedDescription
        }
        return meeting
    }
}
