import Foundation
import MinutesCore
import Observation
import UIKit

/// Runs the post-recording pipeline one meeting at a time. The speech, speaker and language
/// models are each hundreds of MB once loaded; running two meetings at once would only make
/// both slower and risk the system killing the app for memory.
@MainActor
@Observable
final class ProcessingQueue {
    enum Job {
        case full(liveWords: [TimedWord]?)
        case speakers
        case summary
        /// Opt-in: transcribe and identify speakers again on the PC, then summarize here.
        case server(AccuracyServer)

        var firstStage: PipelineStage {
            switch self {
            case .full, .speakers, .summary: return .transcribing(0)
            case .server: return .remote("Sending to PC…", 0)
            }
        }
    }

    private(set) var stages: [UUID: PipelineStage] = [:]
    private var pending: [(id: UUID, job: Job)] = []
    private var worker: Task<Void, Never>?
    private weak var store: MeetingStore?

    func attach(_ store: MeetingStore) {
        self.store = store
    }

    func stage(for id: UUID) -> PipelineStage? { stages[id] }

    func isBusy(_ id: UUID) -> Bool {
        stages[id] != nil || pending.contains { $0.id == id }
    }

    func enqueue(_ id: UUID, _ job: Job) {
        guard !isBusy(id) else { return }
        store?.update(id) { if case .full = job { $0.status = .processing } }
        pending.append((id, job))
        runNext()
    }

    /// Meetings left `.processing` by a previous launch (the app was closed mid-way) start again
    /// from the file. Interrupted recordings wait for the user to choose to process them.
    func resumeUnfinished() {
        for meeting in store?.meetings ?? [] where meeting.status == .processing {
            enqueue(meeting.id, .full(liveWords: nil))
        }
    }

    private func runNext() {
        guard worker == nil, !pending.isEmpty, let store else { return }
        let (id, job) = pending.removeFirst()
        guard let meeting = store.meeting(id), let audioURL = store.audioURL(for: meeting) else {
            store.update(id) {
                $0.status = .failed
                $0.processingError = "The recording's audio file is missing."
            }
            runNext()
            return
        }

        stages[id] = job.firstStage
        UIApplication.shared.isIdleTimerDisabled = true
        // A few minutes of grace if the user locks the phone right after stopping. Beyond that
        // iOS suspends the app; the meeting stays `.processing` and resumes on next launch.
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "Process meeting") {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }

        let report: @Sendable (PipelineStage) -> Void = { [weak self] stage in
            Task { @MainActor in
                if self?.stages[id] != nil { self?.stages[id] = stage }
            }
        }
        let settings = Preferences.pipelineSettings

        worker = Task {
            var result: Meeting
            switch job {
            case .full(let liveWords):
                result = await MeetingPipeline.process(meeting, audioURL: audioURL, liveWords: liveWords, settings: settings, stage: report)
                result = await Self.compressRecording(result, folder: store.folder(for: id))
            case .speakers:
                report(.identifyingSpeakers(0))
                result = await MeetingPipeline.identifySpeakers(meeting, audioURL: audioURL) { report(.identifyingSpeakers($0)) }
                result = await MeetingPipeline.summarize(result, stage: report)
            case .summary:
                result = await MeetingPipeline.summarize(meeting, stage: report)
            case .server(let server):
                result = await MeetingPipeline.reprocessOnServer(meeting, audioURL: audioURL, server: server, settings: settings, stage: report)
            }

            // Keep what the user changed while this ran. A deleted meeting stays deleted.
            if let latest = store.meeting(id) {
                if latest.titleIsCustom {
                    result.title = latest.title
                    result.titleIsCustom = true
                }
                // Re-identifying speakers (here or on the PC) decides for itself whether old
                // names still apply.
                if case .summary = job { result.speakerNames = latest.speakerNames }
                store.save(result)
            }
            stages[id] = nil
            worker = nil
            if pending.isEmpty { UIApplication.shared.isIdleTimerDisabled = false }
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            runNext()
        }
    }

    /// The PCM recording is ~115 MB an hour; once processed it's re-encoded to AAC (~15 MB).
    private nonisolated static func compressRecording(_ meeting: Meeting, folder: URL) async -> Meeting {
        guard meeting.status == .ready, meeting.audioFileName == "recording.caf" else { return meeting }
        var meeting = meeting
        let source = folder.appendingPathComponent("recording.caf")
        let destination = folder.appendingPathComponent("recording.m4a")
        do {
            try AudioFiles.compress(source, to: destination)
            meeting.audioFileName = "recording.m4a"
            try? FileManager.default.removeItem(at: source)
        } catch {
            print("[ProcessingQueue] keeping uncompressed audio: \(error)")
        }
        return meeting
    }
}
