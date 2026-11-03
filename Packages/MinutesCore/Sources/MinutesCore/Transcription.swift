import AVFoundation
import CoreMedia
import Foundation
import Speech

public enum TranscriptionError: LocalizedError {
    case notAvailable
    case unsupportedLocale(String)
    case noAudioFormat

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "On-device transcription isn't available on this device."
        case .unsupportedLocale(let id):
            return "On-device transcription doesn't support \(Locale.current.localizedString(forIdentifier: id) ?? id) yet."
        case .noAudioFormat:
            return "The speech model didn't report an audio format it accepts."
        }
    }
}

/// Apple's on-device SpeechTranscriber (iOS 26+): long-form, runs on the Neural Engine, no
/// network once its language model is installed.
public enum SpeechModel {
    /// Live and file transcription both use this configuration. `fastResults` is deliberately
    /// left out: Apple documents it as trading accuracy for latency, and every word ending up
    /// right matters more here than the live preview appearing a beat sooner. `volatileResults`
    /// costs nothing in accuracy — it only adds the in-progress guesses the preview shows.
    public static func makeTranscriber(locale: Locale, live: Bool) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.notAvailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        }
        return SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: live ? [.volatileResults] : [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    /// Downloads the language model the first time a locale is used (a few hundred MB, once).
    public static func ensureInstalled(_ modules: [any SpeechModule], progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
            progress?(p.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    public static func isInstalled(locale: Locale) async -> Bool {
        guard let transcriber = try? await makeTranscriber(locale: locale, live: false) else { return false }
        return await AssetInventory.status(forModules: [transcriber]) == .installed
    }

    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    static func context(for vocabulary: [String]) -> AnalysisContext? {
        let terms = vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        let context = AnalysisContext()
        context.contextualStrings[.general] = terms
        return context
    }

    /// Splits a final result into timed words. Runs carry the time range; a run without one
    /// (whitespace, occasionally punctuation) is folded into its neighbour so no text is lost.
    static func words(from result: SpeechTranscriber.Result, prependSpace: Bool) -> [TimedWord] {
        var words: [TimedWord] = []
        var pending = prependSpace ? " " : ""
        let text = result.text
        for run in text.runs {
            let piece = String(text[run.range].characters)
            guard let range = run.audioTimeRange, range.duration.seconds.isFinite else {
                if words.isEmpty { pending += piece } else { words[words.count - 1].text += piece }
                continue
            }
            words.append(TimedWord(
                text: pending + piece,
                start: range.start.seconds,
                end: range.end.seconds,
                confidence: run.transcriptionConfidence
            ))
            pending = ""
        }
        if words.isEmpty, !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // No timing at all (shouldn't happen with .audioTimeRange) — keep the text, timed
            // to the whole result.
            words.append(TimedWord(text: pending, start: result.range.start.seconds, end: result.range.end.seconds))
        }
        return words
    }
}

/// Transcribes a finished audio file (an import, or a recording whose live pass was lost).
public enum FileTranscriber {
    public static func transcribe(
        url: URL,
        locale: Locale,
        vocabulary: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedWord] {
        let transcriber = try await SpeechModel.makeTranscriber(locale: locale, live: false)
        try await SpeechModel.ensureInstalled([transcriber])

        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let context = SpeechModel.context(for: vocabulary) {
            try await analyzer.setContext(context)
        }

        let collector = Task { () throws -> [TimedWord] in
            var words: [TimedWord] = []
            for try await result in transcriber.results where result.isFinal {
                words += SpeechModel.words(from: result, prependSpace: !words.isEmpty)
                if duration > 0 { progress(min(1, result.range.end.seconds / duration)) }
            }
            return words
        }

        do {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }
}

/// Transcribes audio as it's recorded. Buffers handed to `append` must already be in
/// `format` (see `BufferConverter`) — the recorder converts once and writes the same buffers
/// to disk, so the transcript's timeline is the audio file's timeline.
public final class LiveTranscriber: @unchecked Sendable {
    public let format: AVAudioFormat
    /// Called on an arbitrary thread with all finalized text so far and the current guess.
    public var onUpdate: (@Sendable (_ finalized: String, _ volatile: String) -> Void)?

    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?

    private let lock = NSLock()
    private var finalizedWords: [TimedWord] = []
    private var finalizedText = ""
    private var volatileText = ""
    private var failure: Error?

    public static func start(locale: Locale, vocabulary: [String], installProgress: (@Sendable (Double) -> Void)? = nil) async throws -> LiveTranscriber {
        let transcriber = try await SpeechModel.makeTranscriber(locale: locale, live: true)
        try await SpeechModel.ensureInstalled([transcriber], progress: installProgress)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let context = SpeechModel.context(for: vocabulary) {
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let live = LiveTranscriber(format: format, analyzer: analyzer, transcriber: transcriber, input: continuation)
        live.listen()
        try await analyzer.start(inputSequence: stream)
        return live
    }

    private init(format: AVAudioFormat, analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, input: AsyncStream<AnalyzerInput>.Continuation) {
        self.format = format
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.input = input
    }

    /// Safe to call from the audio tap thread.
    public func append(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    /// The error that stopped live transcription, if any. The recording itself carries on;
    /// processing falls back to transcribing the saved file.
    public var error: Error? {
        lock.withLock { failure }
    }

    /// Ends the input, waits for the model to finalize what's left, and returns every word.
    /// Returns `nil` if live transcription failed part-way, so the caller re-transcribes the file.
    public func finish() async -> [TimedWord]? {
        input.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            record(error)
        }
        await resultsTask?.value
        return lock.withLock { failure == nil ? finalizedWords : nil }
    }

    public func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
    }

    private func listen() {
        let transcriber = self.transcriber
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handle(result)
                }
            } catch {
                self?.record(error)
            }
        }
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        let (finalized, volatile) = lock.withLock { () -> (String, String) in
            update(with: result)
            return (finalizedText, volatileText)
        }
        onUpdate?(finalized, volatile)
    }

    /// Called with `lock` held.
    private func update(with result: SpeechTranscriber.Result) {
        if result.isFinal {
            let words = SpeechModel.words(from: result, prependSpace: !finalizedWords.isEmpty)
            finalizedWords += words
            // Appended, not re-joined from every word: an hour of speech is thousands of
            // results, and re-joining would make each one cost the whole transcript.
            let addition = SpeakerAligner.joinedText(words)
            if !addition.isEmpty {
                finalizedText += (finalizedText.isEmpty ? "" : " ") + addition
            }
            volatileText = ""
        } else {
            volatileText = String(result.text.characters).trimmingCharacters(in: .whitespaces)
        }
    }

    private func record(_ error: Error) {
        lock.withLock {
            if failure == nil { failure = error }
        }
    }
}
