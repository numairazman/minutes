import AVFoundation
import Foundation

/// Streaming converter from whatever the microphone delivers (48 kHz Float32, stereo on some
/// routes) to the speech model's format. One instance per stream: AVAudioConverter keeps
/// resampler state between buffers, and recreating it per buffer would click at every seam.
public final class BufferConverter {
    public let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    public init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    public func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        if buffer.format == outputFormat { return buffer }
        // A route change (headphones in, Bluetooth mic) changes the input format mid-recording.
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { throw ConversionError.unsupported(buffer.format) }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            // `.noDataNow`, not `.endOfStream`: the stream continues with the next tap buffer,
            // and end-of-stream would flush and reset the resampler.
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw error ?? ConversionError.unsupported(buffer.format) }
        return output.frameLength > 0 ? output : nil
    }

    public enum ConversionError: LocalizedError {
        case unsupported(AVAudioFormat)
        public var errorDescription: String? {
            if case .unsupported(let format) = self { return "Can't convert audio from \(format)." }
            return nil
        }
    }
}

public enum AudioFiles {
    /// Uncompressed 16-bit CAF while recording, because the app can be killed mid-meeting.
    /// Tested by SIGKILLing a writer after 10 s of audio: the PCM CAF read back all 10 s, an
    /// AAC .m4a wouldn't open at all, and AAC in a CAF read back as 0 frames.
    public static func makeRecordingFile(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    public static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Re-encodes a finished recording as AAC (.m4a, ~15 MB an hour instead of ~115 MB).
    /// Only after processing, when nothing needs the PCM any more.
    public static func compress(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: format.sampleRate <= 16_000 ? 32_000 : 64_000,
        ]
        try? FileManager.default.removeItem(at: destination)
        do {
            let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else { return }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
