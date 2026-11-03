import MinutesCore
import SwiftUI

@main
struct MinutesApp: App {
    @State private var store = MeetingStore()
    @State private var processing = ProcessingQueue()
    @State private var recorder = RecordingController()

    var body: some Scene {
        WindowGroup {
            MeetingListView()
                .environment(store)
                .environment(processing)
                .environment(recorder)
                .task {
                    processing.attach(store)
                    processing.resumeUnfinished()
                    ModelWarmup.start()
                }
        }
    }
}

/// Fetches the on-device models in the background on launch, so the first recording doesn't
/// sit waiting for a download: the speech model for the chosen language (Apple, a few hundred
/// MB) and the speaker models (Hugging Face, ~20 MB). Both are one-time downloads.
enum ModelWarmup {
    static func start() {
        Task.detached(priority: .utility) {
            if let transcriber = try? await SpeechModel.makeTranscriber(locale: Preferences.locale, live: false) {
                try? await SpeechModel.ensureInstalled([transcriber])
            }
            try? await SpeakerDiarizer.shared.prepare()
        }
    }
}

/// UserDefaults keys shared by `@AppStorage` in views and by non-view code.
enum Preferences {
    static let localeKey = "transcriptionLocale"
    static let vocabularyKey = "customVocabulary"
    static let keepScreenOnKey = "keepScreenOn"
    static let exportTimestampsKey = "exportTimestamps"
    static let exportSummaryKey = "exportSummary"

    static var locale: Locale {
        if let id = UserDefaults.standard.string(forKey: localeKey), !id.isEmpty { return Locale(identifier: id) }
        return Locale.current
    }

    /// One term per line (commas also accepted, since that's how people paste lists).
    static var vocabulary: [String] {
        (UserDefaults.standard.string(forKey: vocabularyKey) ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static var keepScreenOn: Bool { UserDefaults.standard.object(forKey: keepScreenOnKey) as? Bool ?? true }

    static var exportOptions: ExportOptions {
        ExportOptions(
            includeSummary: UserDefaults.standard.object(forKey: exportSummaryKey) as? Bool ?? true,
            includeTimestamps: UserDefaults.standard.object(forKey: exportTimestampsKey) as? Bool ?? true
        )
    }

    static var pipelineSettings: PipelineSettings {
        PipelineSettings(locale: locale, vocabulary: vocabulary)
    }
}
