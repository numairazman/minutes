import AppIntents
import Foundation

// Pause and Resume on the lock screen and in the Dynamic Island. LiveActivityIntent runs in the
// app's own process, which is alive for the whole recording (background audio), so these act on
// the real recorder. The widget extension compiles them too (its buttons reference them) but
// never runs them: WIDGET_EXTENSION is defined only there.
//
// If the app was killed, iOS may relaunch it in the background to run one of these; the
// recorder is idle then, so pause/resume do nothing — which is right, nothing is recording.
//
// Stop is deliberately not one of these. Stopping starts processing, and Apple Intelligence
// won't run with the app in the background, so Stop is a link that opens Minutes instead.

struct PauseRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause recording"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run { RecordingController.shared.pause() }
        #endif
        return .result()
    }
}

struct ResumeRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume recording"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run { RecordingController.shared.resume() }
        #endif
        return .result()
    }
}
