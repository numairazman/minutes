import AVFoundation
import Foundation
import MinutesCore

// Runs the app's meeting pipeline on a Mac, on a real audio file:
//
//   swift run minutes-check meeting.m4a [--speakers N] [--live] [--no-summary]
//                                       [--locale en-US] [--vocab "Name,Acronym"] [--out file.txt] [--json meeting.json]
//
// --live feeds the file through the same path a recording takes (BufferConverter → the PCM
// recording file + LiveTranscriber) instead of transcribing the file directly.

func usage() -> Never {
    print("usage: minutes-check <audio-file> [--speakers N] [--live] [--no-summary] [--locale id] [--vocab a,b] [--out file.txt] [--json file.json] [--turns]")
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first, !path.hasPrefix("--") else { usage() }
args.removeFirst()
var speakers: Int?
var live = false
var summarize = true
var locale = Locale(identifier: "en-US")
var vocabulary: [String] = []
var outPath: String?
var jsonPath: String?
while let flag = args.first {
    args.removeFirst()
    switch flag {
    case "--speakers": speakers = args.first.flatMap(Int.init); args = Array(args.dropFirst())
    case "--live": live = true
    case "--no-summary": summarize = false
    case "--turns": break
    case "--locale": locale = Locale(identifier: args.first ?? "en-US"); args = Array(args.dropFirst())
    case "--vocab": vocabulary = (args.first ?? "").components(separatedBy: ","); args = Array(args.dropFirst())
    case "--out": outPath = args.first; args = Array(args.dropFirst())
    case "--json": jsonPath = args.first; args = Array(args.dropFirst())
    default: usage()
    }
}

let source = URL(fileURLWithPath: path)
let clock = ContinuousClock()
@Sendable func log(_ message: String) { print("[check] \(message)") }
final class Counter: @unchecked Sendable { var value = 0 }
final class Label: @unchecked Sendable { var value = "" }

/// What the recorder does with microphone buffers, but reading them from a file.
func simulateRecording(from source: URL) async throws -> (recording: URL, words: [TimedWord]?) {
    let transcriber = try await LiveTranscriber.start(locale: locale, vocabulary: vocabulary) { p in
        if p < 1 { log(String(format: "installing speech model %.0f%%", p * 100)) }
    }
    log("live analyzer format: \(transcriber.format)")
    let recording = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-check-\(UUID().uuidString).caf")
    let file = try AudioFiles.makeRecordingFile(at: recording, format: transcriber.format)
    let converter = BufferConverter(outputFormat: transcriber.format)

    let input = try AVAudioFile(forReading: source)
    // 4,800 frames ≈ 100 ms at 48 kHz, about what an input tap delivers.
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4_800) else { exit(1) }
    let updates = Counter()
    transcriber.onUpdate = { _, _ in updates.value += 1 }
    while input.framePosition < input.length {
        try input.read(into: buffer, frameCount: 4_800)
        guard let converted = try converter.convert(buffer) else { continue }
        try file.write(from: converted)
        transcriber.append(converted)
    }
    let words = await transcriber.finish()
    log("live updates: \(updates.value), live error: \(transcriber.error.map { "\($0)" } ?? "none")")
    return (recording, words)
}

let start = clock.now
var audioURL = source
var liveWords: [TimedWord]?
do {
    if live {
        let simulated = try await simulateRecording(from: source)
        audioURL = simulated.recording
        liveWords = simulated.words
        log("live pass: \(liveWords?.count ?? 0) words in \(clock.now - start); recording \(AudioFiles.duration(of: audioURL))s")
    }
} catch {
    log("live pass failed: \(error)")
    exit(1)
}

var meeting = Meeting(title: Meeting.defaultTitle(for: Date()), localeIdentifier: locale.identifier, status: .processing)
meeting.expectedSpeakers = speakers
log("summary model: \(MeetingSummarizer.availability)")

let lastStage = Label()
let pipelineStart = clock.now
meeting = await MeetingPipeline.process(
    meeting, audioURL: audioURL, liveWords: liveWords,
    settings: PipelineSettings(locale: locale, vocabulary: vocabulary, summarize: summarize),
    stage: { stage in
        let label = stage.label
        switch stage {
        case .transcribing(let f), .identifyingSpeakers(let f):
            if f > 0, f < 1, Int(f * 100) % 25 != 0 { return }
        case .summarizing:
            break
        }
        if label != lastStage.value { lastStage.value = label; log(label) }
    }
)
log("pipeline: \(clock.now - pipelineStart), status \(meeting.status)")
log("words \(meeting.words.count), turns \(meeting.speakerTurns.count), utterances \(meeting.utterances.count), speakers \(meeting.speakers)")
if CommandLine.arguments.contains("--turns") || meeting.speakerTurns.count <= 40 {
    for t in meeting.speakerTurns { log(String(format: "turn %@ %7.2f-%7.2f", t.speaker, t.start, t.end)) }
}
for issue in [meeting.processingError, meeting.speakerError, meeting.summaryError].compactMap({ $0 }) {
    log("issue: \(issue)")
}

if live {
    let compressed = audioURL.deletingPathExtension().appendingPathExtension("m4a")
    do {
        try AudioFiles.compress(audioURL, to: compressed)
        let size = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
        log("compressed \(size(audioURL)) → \(size(compressed)) bytes, \(AudioFiles.duration(of: compressed))s")
    } catch {
        log("compress failed: \(error)")
    }
}

let text = TranscriptExporter.text(for: meeting)
print("\n" + String(repeating: "=", count: 60) + "\n" + text)
if let jsonPath {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(meeting).write(to: URL(fileURLWithPath: jsonPath))
    log("wrote \(jsonPath)")
}
if let outPath {
    try text.write(toFile: outPath, atomically: true, encoding: .utf8)
    log("wrote \(outPath) (\(TranscriptExporter.fileName(for: meeting)))")
}
