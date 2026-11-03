import MinutesCore
import Security
import SwiftUI

@main
struct MinutesApp: App {
    @State private var store = MeetingStore()
    @State private var processing = ProcessingQueue()
    @State private var recorder = RecordingController.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MeetingListView()
                .environment(store)
                .environment(processing)
                .environment(recorder)
                .task {
                    await RecordingActivityController.shared.endLeftovers()
                    processing.attach(store)
                    processing.resumeUnfinished()
                    #if DEBUG
                    // Diagnostics from a Mac: `devicectl device process launch --console … -resummarizeLatest`
                    // re-runs the summary of the newest meeting so its log can be read on the Mac.
                    if ProcessInfo.processInfo.arguments.contains("-resummarizeLatest"),
                       let latest = store.meetings.first(where: { !$0.utterances.isEmpty }) {
                        print("[Debug] re-summarizing the newest meeting (\(latest.utterances.count) paragraphs)")
                        processing.enqueue(latest.id, .summary)
                    }
                    #endif
                    ModelWarmup.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Processing needs the app on screen (Apple Intelligence won't run in the
                    // background); the lock-screen card says so rather than freezing.
                    let activityMeeting = RecordingActivityController.shared.meetingID
                    guard let id = activityMeeting, processing.isBusy(id) else { return }
                    if phase == .background {
                        RecordingActivityController.shared.waitingForApp()
                    } else if phase == .active {
                        RecordingActivityController.shared.processing(processing.stage(for: id), for: id, force: true)
                    }
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
    static let serverAddressKey = "accuracyServerAddress"

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

    /// The PC for "Re-process for Maximum Accuracy", or nil until an address and token are set.
    static var accuracyServer: AccuracyServer? {
        AccuracyServer(address: UserDefaults.standard.string(forKey: serverAddressKey) ?? "", token: ServerToken.value)
    }
}

/// The PC server's shared token, kept in the Keychain rather than in UserDefaults with the
/// other settings.
enum ServerToken {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.numairazman.minutes.accuracy-server",
        kSecAttrAccount as String: "token",
    ]

    static var value: String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ token: String) {
        SecItemDelete(query as CFDictionary)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
