import Foundation
import FoundationModels

@Generable
struct SummaryDraft {
    @Guide(description: "A short, specific title for the meeting, 3 to 8 words, no date")
    var title: String
    @Guide(description: "Two to four sentences: what the meeting was about and where it ended up")
    var overview: String
    @Guide(description: "The main points discussed, one short sentence each, in the order they came up")
    var keyPoints: [String]
    @Guide(description: "Decisions that were actually agreed. Empty if none were made")
    var decisions: [String]
    @Guide(description: "Follow-up tasks, each starting with the person responsible when the transcript says who. Empty if none")
    var actionItems: [String]
}

public enum SummaryAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

public enum SummaryError: LocalizedError {
    case unavailable(String)
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .emptyTranscript: return "There's nothing in the transcript to summarize."
        }
    }
}

/// Summarizes with Apple's on-device foundation model.
///
/// That model has a small context window (4,096 tokens on iOS 26), and an hour of meeting is
/// roughly 12,000 tokens of transcript, so long meetings are summarized in two passes: notes
/// for each chunk that fits, then one structured summary of the notes. Short meetings go
/// straight to the structured summary from the transcript itself.
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

    /// - Parameter lines: the transcript as "Name: text" lines.
    public static func summarize(lines: [String], progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> MeetingSummary {
        if case .unavailable(let reason) = availability { throw SummaryError.unavailable(reason) }
        let lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { throw SummaryError.emptyTranscript }

        let model = SystemLanguageModel.default
        // Room for the instructions and the response; the rest is transcript.
        let budget = max(800, Int(Double(model.contextSize) * 0.55))

        let transcript = lines.joined(separator: "\n")
        if await tokens(transcript, model: model) <= budget {
            progress("Writing summary…")
            do {
                return try await finalSummary(source: "Transcript:\n" + transcript)
            } catch where isContextOverflow(error) {
                // The estimate said it fits and it didn't; take the chunked route below.
            }
        }

        var notes = try await notesForChunks(chunk(lines, budget: budget, model: model), progress: progress)
        // Notes for a very long meeting can themselves overflow; condense until they fit.
        while notes.count > 1, await tokens(notes.joined(separator: "\n\n"), model: model) > budget {
            progress("Condensing notes…")
            notes = try await condense(chunk(notes, budget: budget, model: model))
        }
        progress("Writing summary…")
        return try await finalSummary(source: "Notes from the meeting, in order:\n\n" + notes.joined(separator: "\n\n"))
    }

    // MARK: - Passes

    private static let options = GenerationOptions(temperature: 0.2)

    private static func notesForChunks(_ chunks: [String], progress: @Sendable (String) -> Void) async throws -> [String] {
        var notes: [String] = []
        for (i, chunk) in chunks.enumerated() {
            progress("Reading part \(i + 1) of \(chunks.count)…")
            let response = try await respondShrinking(instructions: """
                You take notes on one part of a meeting transcript. Write concise bullet points \
                covering what was discussed, any decisions, and any tasks people took on (with who). \
                Use the speakers' names as written. Only include what the transcript says.
                """, prompt: "Part \(i + 1) of \(chunks.count):\n\(chunk)")
            notes.append(response)
        }
        return notes
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

    private static func finalSummary(source: String) async throws -> MeetingSummary {
        let instructions = """
            You summarize meetings for the people who were in them. Be specific and factual, use \
            the speakers' names as written, and never invent decisions or tasks that aren't there.
            """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let draft = try await session.respond(to: source, generating: SummaryDraft.self, options: options).content
            return MeetingSummary(
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                overview: draft.overview.trimmingCharacters(in: .whitespacesAndNewlines),
                keyPoints: clean(draft.keyPoints),
                decisions: clean(draft.decisions),
                actionItems: clean(draft.actionItems)
            )
        } catch where isGuardrail(error) {
            // The default guardrails sometimes refuse ordinary meeting talk (health, HR, an
            // argument). Plain-text generation is allowed the permissive guardrails, so fall
            // back to that rather than leaving the meeting without any summary.
            let session = LanguageModelSession(model: permissiveModel, instructions: instructions)
            let text = try await session.respond(to: "Summarize this meeting in one paragraph, then list any decisions and action items.\n\n" + source, options: options).content
            return MeetingSummary(title: "", overview: text.trimmingCharacters(in: .whitespacesAndNewlines), keyPoints: [], decisions: [], actionItems: [])
        }
    }

    // MARK: - Helpers

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

    private static func isGuardrail(_ error: Error) -> Bool {
        if let e = error as? LanguageModelSession.GenerationError, case .guardrailViolation = e { return true }
        if #available(iOS 27, macOS 27, *), let e = error as? LanguageModelError, case .guardrailViolation = e { return true }
        return false
    }

    private static func clean(_ items: [String]) -> [String] {
        items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
