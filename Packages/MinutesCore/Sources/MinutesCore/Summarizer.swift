import Foundation
import FoundationModels

public enum SummaryAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

public enum SummaryError: LocalizedError {
    case unavailable(String)
    case emptyTranscript
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .emptyTranscript: return "There's nothing in the transcript to summarize."
        case .failed(let reason): return reason
        }
    }

    /// FoundationModels errors describe themselves as "The operation couldn't be completed.
    /// (FoundationModels…GenerationError error -1.)", which means nothing to the person reading
    /// the meeting. Say what happened and what to do instead; the transcript is always intact.
    static func plain(_ error: Error) -> SummaryError {
        if let error = error as? SummaryError { return error }
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .assetsUnavailable:
                return .failed("Apple Intelligence is still getting ready on this iPhone. Try the summary again in a little while.")
            case .guardrailViolation, .refusal:
                return .failed("Apple Intelligence declined to summarize this meeting. The transcript is all here.")
            case .unsupportedLanguageOrLocale:
                return .failed("Apple Intelligence can't summarize meetings in this language yet.")
            case .rateLimited, .concurrentRequests:
                return .failed("Apple Intelligence is busy right now. Try the summary again in a moment.")
            default:
                break
            }
        }
        if #available(iOS 27, macOS 27, *), let e = error as? LanguageModelError {
            switch e {
            case .guardrailViolation, .refusal:
                return .failed("Apple Intelligence declined to summarize this meeting. The transcript is all here.")
            case .unsupportedLanguageOrLocale:
                return .failed("Apple Intelligence can't summarize meetings in this language yet.")
            case .rateLimited, .timeout:
                return .failed("Apple Intelligence is busy right now. Try the summary again in a moment.")
            default:
                break
            }
        }
        return .failed("Apple Intelligence couldn't write a summary this time. The transcript is complete, and you can try the summary again.")
    }
}

/// Summarizes with Apple's on-device foundation model.
///
/// That model has a small context window (4,096 tokens on iOS 26), and an hour of meeting is
/// roughly 12,000 tokens of transcript, so long meetings are summarized in two passes: notes
/// for each chunk that fits, then one summary of the notes. Short meetings go straight to the
/// summary from the transcript itself.
///
/// Everything runs under the permissive content-transformation guardrails, which exist for
/// exactly this — rewriting the user's own text. The default guardrails refused a real 9-minute
/// meeting on an iPhone 16 Pro (ordinary late-night talk), and guided generation (`@Generable`)
/// is only allowed the default ones, so the summary is asked for as plain text in a fixed layout
/// and parsed. If even that is refused, the meeting is summarized in small pieces and only the
/// refused pieces are left out, with a caveat saying so.
public enum MeetingSummarizer {
    public static var availability: SummaryAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable("This device doesn't support Apple Intelligence, which writes the summary.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in Settings to get summaries.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence is still downloading. Try the summary again in a little while.")
        case .unavailable:
            return .unavailable("Apple Intelligence isn't available right now.")
        }
    }

    /// Whether summaries will actually work right now: `availability` only says Apple Intelligence
    /// is switched on, and it said so on an iPhone whose summaries were failing. This asks the
    /// model for one word, the same way a summary does, and reports what really happened.
    public static func check() async -> SummaryAvailability {
        if case .unavailable(let reason) = availability { return .unavailable(reason) }
        do {
            let session = LanguageModelSession(model: permissiveModel, instructions: "Answer with one word.")
            _ = try await session.respond(to: "Say ready.", options: GenerationOptions(temperature: 0, maximumResponseTokens: 4))
            return .available
        } catch {
            log("check failed: \(error)")
            return .unavailable(SummaryError.plain(error).errorDescription ?? "Apple Intelligence didn't answer.")
        }
    }

    /// - Parameter lines: the transcript as "Name: text" lines.
    public static func summarize(lines: [String], progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> MeetingSummary {
        do {
            return try await draft(lines: lines, progress: progress)
        } catch {
            // The raw error, for Console.app / the Mac harness; the user sees the plain version.
            print("[MeetingSummarizer] failed: \(error)")
            throw SummaryError.plain(error)
        }
    }

    private static func draft(lines: [String], progress: @escaping @Sendable (String) -> Void) async throws -> MeetingSummary {
        if case .unavailable(let reason) = availability { throw SummaryError.unavailable(reason) }
        let lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { throw SummaryError.emptyTranscript }

        let model = SystemLanguageModel.default
        // Room for the instructions and the response; the rest is transcript.
        let budget = max(800, Int(Double(model.contextSize) * 0.55))

        let transcript = lines.joined(separator: "\n")
        var chunkBudget = budget
        let transcriptTokens = await tokens(transcript, model: model)
        log("context \(model.contextSize) tokens, transcript \(transcriptTokens), budget \(budget), \(lines.count) lines")
        if transcriptTokens <= budget {
            progress("Writing summary…")
            do {
                return try await finalSummary(source: "Transcript:\n" + transcript)
            } catch where isContextOverflow(error) {
                // The estimate said it fits and it didn't; take the chunked route below.
                log("single pass overflowed: \(error)")
            } catch where isDeclined(error) {
                log("single pass declined: \(error)")
                // Refused as a whole. Small pieces isolate whatever tripped it, so the rest of
                // the meeting still gets summarized.
                chunkBudget = max(300, budget / 4)
            }
        }

        let (pieceNotes, skipped) = try await notesForChunks(chunk(lines, budget: chunkBudget, model: model), progress: progress)
        var notes = pieceNotes
        // Notes for a very long meeting can themselves overflow; condense until they fit.
        while notes.count > 1, await tokens(notes.joined(separator: "\n\n"), model: model) > budget {
            progress("Condensing notes…")
            notes = try await condense(chunk(notes, budget: budget, model: model))
        }
        progress("Writing summary…")
        var summary = try await finalSummary(source: "Notes from the meeting, in order:\n\n" + notes.joined(separator: "\n\n"))
        if skipped > 0 {
            summary.caveat = "Apple Intelligence wouldn't summarize part of this meeting, so the summary leaves it out. The transcript has all of it."
        }
        return summary
    }

    // MARK: - Passes

    private static let options = GenerationOptions(temperature: 0.2)

    /// Notes per chunk. A chunk Apple Intelligence refuses is skipped and counted; only if every
    /// chunk is refused does the whole summary fail.
    private static func notesForChunks(_ chunks: [String], progress: @Sendable (String) -> Void) async throws -> (notes: [String], skipped: Int) {
        var notes: [String] = []
        var skipped = 0
        var lastRefusal: Error?
        for (i, chunk) in chunks.enumerated() {
            progress("Reading part \(i + 1) of \(chunks.count)…")
            log("part \(i + 1) of \(chunks.count): asking")
            do {
                let response = try await respondShrinking(instructions: """
                    You take notes on one part of a meeting transcript. Write concise bullet points \
                    covering what was discussed, any decisions, and any tasks people took on (with who). \
                    Use the speakers' names as written and keep numbers exactly as said. Only include \
                    what the transcript says.
                    """, prompt: "Part \(i + 1) of \(chunks.count):\n\(chunk)")
                notes.append(response)
                log("part \(i + 1): got \(response.count) characters of notes")
            } catch where isDeclined(error) {
                log("part \(i + 1) of \(chunks.count) declined: \(error)")
                skipped += 1
                lastRefusal = error
            }
        }
        if notes.isEmpty, let lastRefusal { throw lastRefusal }
        return (notes, skipped)
    }

    private static func condense(_ groups: [String]) async throws -> [String] {
        var condensed: [String] = []
        for group in groups {
            condensed.append(try await respondShrinking(instructions: """
                Merge these meeting notes into one shorter set of bullet points. Keep every \
                decision and task and who owns it; drop repetition.
                """, prompt: group))
        }
        return condensed
    }

    private static let summaryInstructions = """
        You summarize meetings for the people who were in them. Be specific and factual, use the \
        speakers' names as written, keep numbers and amounts exactly as they were said, and never \
        invent decisions or tasks that aren't there.

        Answer in exactly this layout, with these five headings and nothing else:
        Title: a specific title, 3 to 8 words, no date
        Overview: two to four sentences on what the meeting covered and where it ended up
        Key points:
        - one short sentence per point, in the order they came up
        Decisions:
        - each thing that was agreed or decided, or "- None"
        Action items:
        - each follow-up task, starting with the person responsible when the transcript says who, or "- None"
        """

    private static func finalSummary(source: String) async throws -> MeetingSummary {
        log("summary: asking (\(source.count) characters in)")
        let session = LanguageModelSession(model: permissiveModel, instructions: summaryInstructions)
        let text = try await session.respond(to: source, options: options).content
        log("summary: got \(text.count) characters, layout parsed: \(SummaryLayout.parse(text) != nil)")
        if let parsed = SummaryLayout.parse(text) { return parsed }
        // The model ignored the layout. The text is still a summary; keep it whole.
        return MeetingSummary(title: "", overview: text.trimmingCharacters(in: .whitespacesAndNewlines), keyPoints: [], decisions: [], actionItems: [])
    }

    // MARK: - Helpers

    /// Errors and sizes only, never transcript text: shows up in Console.app and the Mac harness.
    private static func log(_ message: String) {
        print("[MeetingSummarizer] \(message)")
    }

    private static var permissiveModel: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    /// Token counts are estimates when the exact counter isn't available (iOS 26.0–26.3); the
    /// estimate errs high, and `respondShrinking` covers the rare chunk that still overflows.
    private static func tokens(_ text: String, model: SystemLanguageModel) async -> Int {
        if #available(iOS 26.4, macOS 26.4, *), let count = try? await model.tokenCount(for: text) {
            return count
        }
        return text.utf8.count / 3 + 1
    }

    private static func chunk(_ lines: [String], budget: Int, model: SystemLanguageModel) async -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var currentTokens = 0
        for line in lines {
            let lineTokens = await tokens(line, model: model)
            if currentTokens + lineTokens > budget, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
                currentTokens = 0
            }
            current.append(line)
            currentTokens += lineTokens
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }

    /// Plain-text response from a fresh session (sessions keep their history, and one per call
    /// keeps every chunk's context to itself). If the prompt overflows the context anyway,
    /// halves it and retries.
    private static func respondShrinking(instructions: String, prompt: String) async throws -> String {
        do {
            let session = LanguageModelSession(model: permissiveModel, instructions: instructions)
            return try await session.respond(to: prompt, options: options).content
        } catch where isContextOverflow(error) && prompt.count > 400 {
            let lines = prompt.components(separatedBy: "\n")
            let mid = max(1, lines.count / 2)
            let a = try await respondShrinking(instructions: instructions, prompt: lines[..<mid].joined(separator: "\n"))
            let b = try await respondShrinking(instructions: instructions, prompt: lines[mid...].joined(separator: "\n"))
            return a + "\n" + b
        }
    }

    private static func isContextOverflow(_ error: Error) -> Bool {
        if let e = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = e { return true }
        if #available(iOS 27, macOS 27, *), let e = error as? LanguageModelError, case .contextSizeExceeded = e { return true }
        return false
    }

    /// A guardrail violation or a model refusal: either way, this text won't be summarized as is.
    private static func isDeclined(_ error: Error) -> Bool {
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .guardrailViolation, .refusal: return true
            default: break
            }
        }
        if #available(iOS 27, macOS 27, *), let e = error as? LanguageModelError {
            switch e {
            case .guardrailViolation, .refusal: return true
            default: break
            }
        }
        return false
    }

    private static func clean(_ items: [String]) -> [String] {
        items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// Reads the summary layout back into fields. Lenient on purpose: a small model may bold the
/// headings, number the items, or put the overview on the next line.
enum SummaryLayout {
    private enum Section { case preamble, title, overview, keyPoints, decisions, actionItems }

    static func parse(_ text: String) -> MeetingSummary? {
        var section = Section.preamble
        var title = ""
        var overview: [String] = []
        var keyPoints: [String] = [], decisions: [String] = [], actionItems: [String] = []

        for raw in text.components(separatedBy: .newlines) {
            var line = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if let (heading, rest) = heading(in: line) {
                section = heading
                if !rest.isEmpty {
                    switch heading {
                    case .title: title = rest
                    case .overview: overview.append(rest)
                    case .keyPoints: keyPoints.append(item(rest))
                    case .decisions: decisions.append(item(rest))
                    case .actionItems: actionItems.append(item(rest))
                    case .preamble: break
                    }
                }
                continue
            }
            switch section {
            case .preamble, .overview: overview.append(line)
            case .title: if title.isEmpty { title = line } else { overview.append(line) }
            case .keyPoints: keyPoints.append(item(line))
            case .decisions: decisions.append(item(line))
            case .actionItems: actionItems.append(item(line))
            }
        }

        let summary = MeetingSummary(
            title: title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.").union(.whitespaces)),
            overview: overview.joined(separator: " "),
            keyPoints: clean(keyPoints),
            decisions: clean(decisions),
            actionItems: clean(actionItems)
        )
        // Without an overview or any key points the layout wasn't followed; let the caller decide.
        return summary.overview.isEmpty && summary.keyPoints.isEmpty ? nil : summary
    }

    private static func heading(in line: String) -> (Section, String)? {
        let headings: [(String, Section)] = [
            ("title", .title), ("overview", .overview), ("key points", .keyPoints),
            ("decisions", .decisions), ("action items", .actionItems),
        ]
        let lower = line.lowercased()
        for (name, section) in headings where lower.hasPrefix(name) {
            let rest = line.dropFirst(name.count)
            guard rest.isEmpty || rest.first == ":" || rest.first == " " else { continue }
            let value = rest.drop { $0 == ":" || $0 == " " || $0 == "-" || $0 == "–" }
            return (section, String(value).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// "- x", "• x", "* x", "1. x", "1) x" → "x"
    private static func item(_ line: String) -> String {
        var s = Substring(line)
        if let first = s.first, "-•*–".contains(first) {
            s = s.dropFirst()
        } else if let dot = s.firstIndex(where: { $0 == "." || $0 == ")" }), s[s.startIndex..<dot].allSatisfy(\.isNumber), dot > s.startIndex {
            s = s[s.index(after: dot)...]
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func clean(_ items: [String]) -> [String] {
        items.filter { item in
            let lower = item.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            // "None", "N/A", "No specific decisions were made; …" are the model saying the list is empty.
            let empty = ["none", "n/a", "na", "nothing"].contains(lower)
                || lower.hasPrefix("none ") || lower.hasPrefix("none,")
                || (lower.hasPrefix("no ") && (lower.contains("decision") || lower.contains("action item") || lower.contains("task")))
            return !item.isEmpty && !empty
        }
    }
}
