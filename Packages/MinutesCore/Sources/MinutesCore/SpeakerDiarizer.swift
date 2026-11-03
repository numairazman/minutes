import FluidAudio
import Foundation

/// Works out who spoke when, on device, with FluidAudio's offline pipeline (pyannote
/// community-1 segmentation + WeSpeaker embeddings + VBx clustering on Core ML).
///
/// Offline rather than streaming: FluidAudio measures its streaming diarizer at 10–15% worse
/// DER, and nothing needs speaker labels before the meeting ends — the live view shows text only.
public actor SpeakerDiarizer {
    public static let shared = SpeakerDiarizer()

    private var models: OfflineDiarizerModels?

    /// Downloads (first run only, from Hugging Face) and compiles the Core ML models. Safe to
    /// call early — the app does it when a recording starts so the models are ready by the end.
    public func prepare() async throws {
        guard models == nil else { return }
        models = try await OfflineDiarizerModels.load()
    }

    public var isPrepared: Bool { models != nil }

    /// - Parameter expectedSpeakers: an exact count when the user knows it. Clustering is the
    ///   step most likely to merge two similar voices or split one; a known count fixes that.
    public func turns(
        for url: URL,
        expectedSpeakers: Int?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [SpeakerTurn] {
        try await prepare()
        guard let models else { return [] }

        var config = OfflineDiarizerConfig.default
        if let expectedSpeakers, expectedSpeakers > 0 {
            config = config.withSpeakers(exactly: expectedSpeakers)
        }
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)

        do {
            // The URL form streams through a memory-mapped temp file; the [Float] form would
            // hold a whole meeting in memory (an hour at 16 kHz is ~230 MB of floats).
            let result = try await manager.process(url) { done, total in
                if total > 0 { progress?(Double(done) / Double(total)) }
            }
            return result.segments.map {
                SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
            }
        } catch OfflineDiarizationError.noSpeechDetected {
            return []
        }
    }
}
