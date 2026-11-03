import MinutesCore
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Preferences.localeKey) private var localeID = ""
    @AppStorage(Preferences.vocabularyKey) private var vocabulary = ""
    @AppStorage(Preferences.keepScreenOnKey) private var keepScreenOn = true
    @AppStorage(Preferences.exportSummaryKey) private var exportSummary = true
    @AppStorage(Preferences.exportTimestampsKey) private var exportTimestamps = true

    @State private var locales: [Locale] = []
    @State private var speechModel: ModelState = .checking
    @State private var speakerModel: ModelState = .checking

    enum ModelState: Equatable {
        case checking, ready, missing, downloading(Double), failed(String)

        var text: String {
            switch self {
            case .checking: return "Checking…"
            case .ready: return "Ready"
            case .missing: return "Not downloaded"
            case .downloading(let p): return p > 0 ? "Downloading \(Int(p * 100))%" : "Downloading…"
            case .failed(let message): return message
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Language", selection: $localeID) {
                        Text("Same as iPhone").tag("")
                        ForEach(locales, id: \.identifier) { locale in
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Names and terms")
                        TextEditor(text: $vocabulary)
                            .frame(minHeight: 90)
                            .font(.body)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("One per line: people's names, company and product names, acronyms. The transcriber leans toward these spellings, which fixes most of the words it would otherwise get wrong.")
                }

                Section {
                    Toggle("Keep screen on while recording", isOn: $keepScreenOn)
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Recording continues with the screen locked either way. Keeping it on lets you glance at the live transcript; it uses more battery, so it's best while plugged in.")
                }

                Section("Export") {
                    Toggle("Include summary", isOn: $exportSummary)
                    Toggle("Include timestamps", isOn: $exportTimestamps)
                }

                Section {
                    LabeledContent("Speech model", value: speechModel.text)
                    LabeledContent("Speaker model", value: speakerModel.text)
                    LabeledContent("Summaries", value: summaryStatus)
                    if speechModel == .missing || speakerModel == .missing || isFailed {
                        Button("Download Models") { Task { await download() } }
                    }
                } header: {
                    Text("On-device models")
                } footer: {
                    Text("Everything runs on this iPhone. The models download once; after that Minutes works offline, and your audio and transcripts never leave the device unless you export them.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await refresh() }
            .onChange(of: localeID) { Task { await refresh() } }
        }
    }

    private var isFailed: Bool {
        if case .failed = speechModel { return true }
        if case .failed = speakerModel { return true }
        return false
    }

    private var summaryStatus: String {
        switch MeetingSummarizer.availability {
        case .available: return "Apple Intelligence"
        case .unavailable(let reason): return reason
        }
    }

    private func refresh() async {
        if locales.isEmpty {
            locales = await SpeechModel.supportedLocales()
                .filter { $0.language.languageCode != nil }
                .sorted { (Locale.current.localizedString(forIdentifier: $0.identifier) ?? "") < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? "") }
        }
        speechModel = await SpeechModel.isInstalled(locale: Preferences.locale) ? .ready : .missing
        speakerModel = await SpeakerDiarizer.shared.isPrepared ? .ready : .missing
    }

    private func download() async {
        speechModel = .downloading(0)
        do {
            let transcriber = try await SpeechModel.makeTranscriber(locale: Preferences.locale, live: false)
            try await SpeechModel.ensureInstalled([transcriber]) { p in
                Task { @MainActor in speechModel = .downloading(p) }
            }
            speechModel = .ready
        } catch {
            speechModel = .failed(error.localizedDescription)
        }
        speakerModel = .downloading(0)
        do {
            try await SpeakerDiarizer.shared.prepare()
            speakerModel = .ready
        } catch {
            speakerModel = .failed("Couldn't download: \(error.localizedDescription)")
        }
    }
}
