import Foundation

/// The optional "maximum accuracy" tier: the WhisperX server in `server/` (Whisper large-v3,
/// word alignment, pyannote diarization), running on a PC on the same network.
///
/// It returns words and speaker turns in exactly the shapes the on-device models produce, so
/// everything after it (aligning words to speakers, the summary, export) is the same code.
/// A meeting takes minutes even on a GPU, so the audio is uploaded as a job and then polled.
public struct AccuracyServer: Sendable {
    public static let defaultPort = 8765

    public let baseURL: URL
    let token: String

    /// Accepts what people type: "192.168.1.20", "pc.local:8765", "http://192.168.1.20:8765".
    /// A missing scheme means http and a missing port means 8765.
    public init?(address: String, token: String) {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !token.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host?.isEmpty == false
        else { return nil }
        if components.port == nil, scheme == "http" { components.port = Self.defaultPort }
        components.path = ""
        components.query = nil
        guard let url = components.url else { return nil }
        self.baseURL = url
        self.token = token
    }

    // MARK: - Status

    public struct Status: Decodable, Sendable {
        /// "loading", "ready" or "error".
        public var state: String
        /// Why it isn't ready, in words meant for the user.
        public var message: String?
        /// "NVIDIA GeForce RTX 3070 Ti", or "CPU (16 threads)".
        public var device: String
        public var model: String
        public var jobs: Int

        public var isReady: Bool { state == "ready" }
    }

    /// What Settings › Test Connection shows. Also proves the token is right.
    public func status() async throws -> Status {
        let (data, response) = try await send(request(path: "v1/status"))
        try check(response, data)
        return try decode(Status.self, data)
    }

    // MARK: - Transcription

    public struct Transcript: Decodable, Sendable {
        public var words: [TimedWord]
        public var turns: [SpeakerTurn]
        public var language: String?
        /// "WhisperX large-v3 + speaker-diarization-community-1".
        public var engine: String?
        public var device: String?
    }

    /// Uploads the recording, waits for the PC, and returns its words and speaker turns.
    /// `progress` gets a label ("Transcribing on PC…") and the fraction of that step done.
    /// Cancelling the task also cancels the job on the PC.
    public func transcribe(
        audioURL: URL,
        language: String?,
        speakers: Int?,
        vocabulary: [String],
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws -> Transcript {
        var query: [URLQueryItem] = []
        if let language { query.append(URLQueryItem(name: "language", value: language)) }
        if let speakers { query.append(URLQueryItem(name: "speakers", value: String(speakers))) }
        query += vocabulary.map { URLQueryItem(name: "vocabulary", value: $0) }
        var upload = request(path: "v1/jobs", query: query)
        upload.httpMethod = "POST"
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upload.timeoutInterval = 120

        progress("Sending to PC…", 0)
        let delegate = UploadProgress { progress("Sending to PC…", $0) }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.session.upload(for: upload, fromFile: audioURL, delegate: delegate)
        } catch {
            throw describe(error)
        }
        try check(response, data)
        struct Created: Decodable { var id: String }
        let id = try decode(Created.self, data).id

        do {
            let transcript = try await poll(id, progress: progress)
            Task.detached { try? await self.cancel(id) }
            return transcript
        } catch {
            Task.detached { try? await self.cancel(id) }
            throw error
        }
    }

    private struct JobView: Decodable {
        var state: String
        var stage: String
        var progress: Double
        var error: String?
        var result: Transcript?
    }

    private func poll(_ id: String, progress: @Sendable (String, Double) -> Void) async throws -> Transcript {
        // The phone can sleep or switch networks mid-meeting; the job carries on on the PC
        // either way, so a few failed polls in a row are only a blip.
        var failures = 0
        while true {
            try await Task.sleep(for: .seconds(2))
            let job: JobView
            do {
                let (data, response) = try await send(request(path: "v1/jobs/\(id)"))
                try check(response, data)
                job = try decode(JobView.self, data)
                failures = 0
            } catch let error as AccuracyServerError {
                if case .unreachable = error, failures < 15 {
                    failures += 1
                    continue
                }
                throw error
            }
            switch job.state {
            case "queued":
                progress("Waiting for the PC…", 0)
            case "running":
                progress("\(job.stage) on PC…", job.progress)
            case "done":
                guard let result = job.result else { throw AccuracyServerError.badResponse }
                return result
            case "cancelled":
                throw CancellationError()
            default:
                throw AccuracyServerError.server(job.error ?? "The PC couldn't process this recording.")
            }
        }
    }

    private func cancel(_ id: String) async throws {
        var request = request(path: "v1/jobs/\(id)")
        request.httpMethod = "DELETE"
        _ = try await Self.session.data(for: request)
    }

    // MARK: - HTTP

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private func request(path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await Self.session.data(for: request)
        } catch {
            throw describe(error)
        }
    }

    private func describe(_ error: Error) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        return AccuracyServerError.unreachable(baseURL.host() ?? baseURL.absoluteString)
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AccuracyServerError.badResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw AccuracyServerError.unauthorized
        default:
            struct Detail: Decodable { var detail: String }
            let detail = (try? JSONDecoder().decode(Detail.self, from: data))?.detail
            throw AccuracyServerError.server(detail ?? "The PC answered with HTTP \(http.statusCode).")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AccuracyServerError.badResponse
        }
    }
}

public enum AccuracyServerError: LocalizedError, Sendable {
    case unreachable(String)
    case unauthorized
    case server(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unreachable(let host):
            return "Couldn't reach the PC at \(host). Check that it's on, the Minutes server is running, and this device is on the same network. If iOS asked about Local Network access, allow it."
        case .unauthorized:
            return "The PC rejected the token. Check that it matches MINUTES_TOKEN in the server's .env."
        case .server(let message):
            return message
        case .badResponse:
            return "The PC sent a response Minutes doesn't understand. Update the server from the repo's server folder."
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
