import AVFoundation
import MinutesCore
import Observation
import UIKit

enum RecorderError: LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Minutes doesn't have access to the microphone. Turn it on in Settings › Privacy & Security › Microphone."
        }
    }
}

/// Microphone → AVAudioEngine tap → one conversion to 16 kHz mono → the recording file *and*
/// the live transcriber.
///
/// The file is the source of truth. Live transcription is a preview that also saves time at
/// the end: if it ran start to finish without an error, its words are the transcript; if not
/// (model still downloading, the system reclaimed it in the background), the file is
/// transcribed after the meeting instead. Nothing the transcriber does can stop the recording.
@MainActor
@Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle, starting, recording, paused, stopping
    }

    private(set) var phase: Phase = .idle
    private(set) var meetingID: UUID?
    private(set) var elapsed: TimeInterval = 0
    /// The last 12 s of input level at 20 samples a second — enough history for the pen trace to
    /// read as a drawn line rather than a jagged few points.
    private(set) var levels: [Float] = Array(repeating: 0, count: 240)
    /// Samples taken so far; the pen trace derives each sample's wiggle from its absolute index.
    private(set) var levelTick = 0
    /// The tail of the live transcript — enough to fill the screen. The whole text of an hour
    /// would be re-laid-out by SwiftUI on every update.
    private(set) var finalizedText = ""
    private(set) var volatileText = ""
    private(set) var notice: String?

    var isActive: Bool { phase != .idle }

    private let engine = AVAudioEngine()
    private var sink: AudioSink?
    private var live: LiveTranscriber?
    private var liveStart: Task<Void, Never>?
    private var meter: Timer?
    private var observers: [NSObjectProtocol] = []

    // MARK: - Control

    func start(store: MeetingStore) async throws {
        guard phase == .idle else { return }
        phase = .starting
        notice = nil
        finalizedText = ""
        volatileText = ""
        elapsed = 0
        levels = Array(repeating: 0, count: levels.count)
        levelTick = 0

        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .idle
            throw RecorderError.microphoneDenied
        }

        let (meeting, audioURL) = store.createRecording()
        do {
            try configureSession()
            let sink = try AudioSink(url: audioURL)
            self.sink = sink
            meetingID = meeting.id
            installTap(sink)
            engine.prepare()
            try engine.start()
        } catch {
            teardownEngine()
            store.delete(meeting.id)
            sink = nil
            meetingID = nil
            phase = .idle
            throw error
        }

        phase = .recording
        UIApplication.shared.isIdleTimerDisabled = Preferences.keepScreenOn
        observeSession()
        startMeter()
        startLiveTranscription()
        // The speaker models are needed the moment the meeting ends; load them now, while
        // the user is still talking, rather than then.
        Task.detached(priority: .utility) { try? await SpeakerDiarizer.shared.prepare() }
    }

    func pause() {
        guard phase == .recording else { return }
        engine.pause()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            phase = .recording
            notice = nil
        } catch {
            notice = "Couldn't resume: \(error.localizedDescription)"
        }
    }

    /// Stops, saves and hands the meeting to the processing queue. Returns its id.
    @discardableResult
    func stop(store: MeetingStore, processing: ProcessingQueue) async -> UUID? {
        guard phase == .recording || phase == .paused, let sink, let meetingID else { return nil }
        phase = .stopping
        teardownEngine()

        var words: [TimedWord]?
        if let live, sink.liveIsComplete {
            words = await live.finish()
        } else {
            liveStart?.cancel()
            await live?.cancel()
        }
        sink.close()
        let duration = sink.duration
        reset()

        guard duration >= 1 else {
            store.delete(meetingID)
            return nil
        }
        store.update(meetingID) {
            $0.duration = duration
            $0.status = .processing
        }
        processing.enqueue(meetingID, .full(liveWords: words))
        return meetingID
    }

    func discard(store: MeetingStore) async {
        guard let meetingID else { return }
        phase = .stopping
        teardownEngine()
        liveStart?.cancel()
        await live?.cancel()
        sink?.close()
        reset()
        store.delete(meetingID)
    }

    // MARK: - Engine

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // `.record` without `.allowBluetoothHFP`: with AirPods connected iOS would otherwise
        // take input from their microphone, which hears the wearer and almost no one else in
        // the room. The built-in microphones are what a meeting recording wants.
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
    }

    private func installTap(_ sink: AudioSink) {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0), block: Self.tapBlock(for: sink))
    }

    /// Built outside the main actor: the tap runs on an audio thread, and a closure formed in a
    /// main-actor method would be treated as main-actor isolated.
    private nonisolated static func tapBlock(for sink: AudioSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.consume(buffer) }
    }

    private func teardownEngine() {
        meter?.invalidate()
        meter = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func reset() {
        sink = nil
        live = nil
        liveStart = nil
        meetingID = nil
        phase = .idle
        notice = nil
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    // A phone call or Siri took the microphone; the engine has already stopped.
                    if self.phase == .recording {
                        self.phase = .paused
                        self.notice = "Paused because another app took the microphone."
                    }
                case .ended:
                    if options?.contains(.shouldResume) == true { self.resume() }
                default:
                    break
                }
            }
        })
        // Plugging in headphones or a USB mic changes the input format, and the engine stops.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let sink = self.sink, self.phase == .recording || self.phase == .paused else { return }
                self.installTap(sink)
                guard self.phase == .recording else { return }
                do {
                    try self.engine.start()
                } catch {
                    self.phase = .paused
                    self.notice = "The microphone changed. Tap Resume to keep recording."
                }
            }
        })
    }

    private func startMeter() {
        meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let sink = self.sink else { return }
                self.elapsed = sink.duration
                self.levels.removeFirst()
                self.levels.append(self.phase == .recording ? sink.takeLevel() : 0)
                self.levelTick += 1
            }
        }
    }

    private func startLiveTranscription() {
        liveStart = Task { [weak self] in
            do {
                let live = try await LiveTranscriber.start(locale: Preferences.locale, vocabulary: Preferences.vocabulary) { progress in
                    Task { @MainActor in
                        self?.notice = "Downloading the speech model (first time only)… \(Int(progress * 100))%"
                    }
                }
                live.onUpdate = { finalized, volatile in
                    Task { @MainActor in
                        self?.finalizedText = String(finalized.suffix(4000))
                        self?.volatileText = volatile
                    }
                }
                guard let self, !Task.isCancelled, let sink = self.sink else {
                    await live.cancel()
                    return
                }
                sink.attach(live)
                self.live = live
                self.notice = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.sink?.abandonLive()
                self.notice = "Live transcript unavailable: \(error.localizedDescription) Recording continues, and the transcript is made when you stop."
            }
        }
    }
}

/// Everything the audio thread touches. Lives outside the main actor; its own lock guards the
/// state the meter and the transcriber hand-off read.
final class AudioSink: @unchecked Sendable {
    /// Audio kept for the live transcriber until it's ready (it takes a moment to load, longer
    /// on first use), so its transcript still starts at 0:00. Beyond this the backlog is dropped
    /// and the file is transcribed after the meeting instead.
    private static let maxBacklogSeconds = 600.0

    let format: AVAudioFormat
    private let file: AVAudioFile
    private let converter: BufferConverter
    private let lock = NSLock()
    private var live: LiveTranscriber?
    private var liveConverter: BufferConverter?
    private var backlog: [AVAudioPCMBuffer] = []
    private var backlogFrames: AVAudioFramePosition = 0
    private var liveMissedAudio = false
    private var framesWritten: AVAudioFramePosition = 0
    private var peak: Float = 0
    private var closed = false

    init(url: URL) throws {
        // 16 kHz mono: what both the speech model and the speaker models consume.
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        file = try AudioFiles.makeRecordingFile(at: url, format: target)
        format = file.processingFormat
        converter = BufferConverter(outputFormat: format)
    }

    /// Audio thread.
    func consume(_ input: AVAudioPCMBuffer) {
        let level = Self.level(of: input)
        guard let buffer = try? converter.convert(input) else { return }
        lock.withLock {
            guard !closed else { return }
            do {
                try file.write(from: buffer)
            } catch {
                return
            }
            framesWritten += AVAudioFramePosition(buffer.frameLength)
            peak = max(peak, level)
            if let live {
                forward(buffer, to: live)
            } else if !liveMissedAudio {
                backlog.append(buffer)
                backlogFrames += AVAudioFramePosition(buffer.frameLength)
                if Double(backlogFrames) / format.sampleRate > Self.maxBacklogSeconds {
                    backlog = []
                    liveMissedAudio = true
                }
            }
        }
    }

    func attach(_ live: LiveTranscriber) {
        lock.withLock {
            if live.format != format { liveConverter = BufferConverter(outputFormat: live.format) }
            for buffer in backlog { forward(buffer, to: live) }
            backlog = []
            self.live = live
        }
    }

    func abandonLive() {
        lock.withLock {
            backlog = []
            liveMissedAudio = true
        }
    }

    /// True when every recorded frame reached the live transcriber.
    var liveIsComplete: Bool {
        lock.withLock { live != nil && !liveMissedAudio }
    }

    var duration: TimeInterval {
        lock.withLock { Double(framesWritten) / format.sampleRate }
    }

    /// Peak level since the last call, 0…1.
    func takeLevel() -> Float {
        lock.withLock {
            defer { peak = 0 }
            return peak
        }
    }

    func close() {
        lock.withLock {
            closed = true
            file.close()
        }
    }

    /// Called with `lock` held.
    private func forward(_ buffer: AVAudioPCMBuffer, to live: LiveTranscriber) {
        if let liveConverter {
            if let converted = try? liveConverter.convert(buffer) { live.append(converted) }
        } else {
            live.append(buffer)
        }
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = data[0]
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        // -55 dB (a quiet room) … -10 dB (someone speaking close by) → 0…1
        return min(1, max(0, (db + 55) / 45))
    }
}
