import MinutesCore
import SwiftUI

/// Settings as a page of the pad: sections are headings on the page, switches are tick boxes,
/// text fields are lines to write on, and notes sit in the margin.
struct SettingsView: View {
    @Environment(Pad.self) private var pad

    @AppStorage(Preferences.localeKey) private var localeID = ""
    @AppStorage(Preferences.vocabularyKey) private var vocabulary = ""
    @AppStorage(Preferences.keepScreenOnKey) private var keepScreenOn = true
    @AppStorage(Preferences.exportSummaryKey) private var exportSummary = true
    @AppStorage(Preferences.exportTimestampsKey) private var exportTimestamps = true
    @AppStorage(Preferences.serverAddressKey) private var serverAddress = ""

    @ScaledMetric(relativeTo: .footnote) private var marginWidth: CGFloat = 58

    @State private var locales: [Locale] = []
    @State private var speechModel: ModelState = .checking
    @State private var speakerModel: ModelState = .checking
    @State private var summaries: ModelState = .checking
    @State private var serverToken = ServerToken.value
    @State private var connection: Connection?

    private var metrics: PageMetrics { PageMetrics(marginWidth: marginWidth) }

    enum Connection: Equatable {
        case testing, ok(String), failed(String)
    }

    enum ModelState: Equatable {
        case checking, ready, missing, downloading(Double), failed(String)

        var text: String {
            switch self {
            case .checking: return "Checking"
            case .ready: return "Ready"
            case .missing: return "Not downloaded yet"
            case .downloading(let p): return p > 0 ? "Downloading, \(Int(p * 100))%" : "Downloading"
            case .failed(let message): return message
            }
        }

        var icon: String {
            switch self {
            case .ready: return "checkmark"
            case .failed: return "exclamationmark.triangle"
            default: return "arrow.down.circle"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MarginRow(metrics: metrics) {
                    Text("Settings")
                        .font(Typeface.page(.largeTitle, .bold))
                        .foregroundStyle(Color.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.top, Space.line)

                transcription
                recording
                export
                pcServer
                onDevice
            }
            .padding(.bottom, Space.section)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(PaperPage(metrics: metrics))
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            PageBar { BackKey() } trailing: { EmptyView() }
        }
        .tint(.ballpoint)
        .task { await refresh() }
        .onAppear { serverToken = ServerToken.value }
        .onChange(of: localeID) { Task { await refresh() } }
        .onChange(of: serverToken) { ServerToken.save(serverToken); connection = nil }
        .onChange(of: serverAddress) { connection = nil }
    }

    // MARK: - Sections

    private var transcription: some View {
        section("Transcription") {
            row {
                Button {
                    pad.show { languageCard }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Space.tight) {
                            Text("Language")
                                .font(Typeface.page(.body))
                                .foregroundStyle(Color.ink)
                            Text(languageName(localeID))
                                .font(Typeface.note(.subheadline))
                                .foregroundStyle(Color.ballpoint)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.pencil)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(languageName(localeID))
            }
            row {
                VStack(alignment: .leading, spacing: Space.line) {
                    Text("Names and terms")
                        .font(Typeface.page(.body))
                        .foregroundStyle(Color.ink)
                    TextEditor(text: $vocabulary)
                        .font(Typeface.page(.body))
                        .foregroundStyle(Color.ink)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 104)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.paperRaised, in: .rect(cornerRadius: 8, style: .continuous))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Names and terms")
                }
            }
            note("One per line: people, companies, products, acronyms. The transcriber leans toward these spellings, which fixes most of the words it gets wrong.")
        }
    }

    private var recording: some View {
        section("Recording") {
            row { Toggle("Keep the screen on while recording", isOn: $keepScreenOn).toggleStyle(TickBoxStyle()) }
            note("Recording carries on with the screen locked either way. Keeping it on uses more battery, so it's best while plugged in.")
        }
    }

    private var export: some View {
        section("Export") {
            row { Toggle("Include the summary", isOn: $exportSummary).toggleStyle(TickBoxStyle()) }
            row { Toggle("Include timestamps", isOn: $exportTimestamps).toggleStyle(TickBoxStyle()) }
            note("Plain text, so exports open anywhere: OneDrive, Word, Notes, email.")
        }
    }

    private var pcServer: some View {
        section("Maximum accuracy on your PC") {
            row {
                InkField(placeholder: "PC address, e.g. 192.168.1.20", text: $serverAddress)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            row {
                InkField(placeholder: "Token", text: $serverToken, secure: true)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            MarginRow(metrics: metrics) {
                connectionMark
                    .font(.system(size: 13, weight: .semibold))
            } page: {
                VStack(alignment: .leading, spacing: Space.item) {
                    Button(connection == .testing ? "Testing" : "Test connection") {
                        Task { await testConnection() }
                    }
                    .buttonStyle(InkCapsuleStyle())
                    .disabled(AccuracyServer(address: serverAddress, token: serverToken) == nil || connection == .testing)
                    if connection == .testing {
                        InkProgress(fraction: nil).frame(maxWidth: 160)
                    }
                    switch connection {
                    case .ok(let text):
                        Text(text).font(Typeface.note(.footnote)).foregroundStyle(Ink.color(for: "2"))
                    case .failed(let text):
                        Text(text).font(Typeface.note(.footnote)).foregroundStyle(Color.margin)
                    case .testing, nil:
                        EmptyView()
                    }
                }
            }
            .padding(.vertical, Space.row)
            note("No typing needed: on your Mac, run swift server/pairing-qr.swift in the Minutes folder and scan the code with the Camera. The token is the server's password.")
            note("A meeting's ⋯ menu can then send its recording to your PC for Whisper large-v3 and a second look at who spoke. Nothing is sent unless you choose it.")
        }
    }

    @ViewBuilder
    private var connectionMark: some View {
        switch connection {
        case .ok: Image(systemName: "checkmark").foregroundStyle(Ink.color(for: "2"))
        case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.margin)
        default: Color.clear.frame(width: 1, height: 1)
        }
    }

    private var onDevice: some View {
        section("On this iPhone") {
            model("Speech model", speechModel)
            model("Speaker model", speakerModel)
            model("Summaries", summaries, ready: "Apple Intelligence answered just now")
            if speechModel == .missing || speakerModel == .missing || isFailed {
                MarginRow(metrics: metrics) {
                    Button("Download models") { Task { await download() } }
                        .buttonStyle(InkCapsuleStyle())
                }
                .padding(.vertical, Space.line)
            }
            note("The models download once; after that Minutes works offline. Your audio and transcripts stay on this iPhone unless you export them or send one to your PC.")
        }
    }

    private func model(_ name: String, _ state: ModelState, ready: String? = nil) -> some View {
        MarginRow(metrics: metrics) {
            Image(systemName: state.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state == .ready ? Ink.color(for: "2") : (isFailed(state) ? Color.margin : Color.pencil))
        } page: {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(name).font(Typeface.page(.body)).foregroundStyle(Color.ink)
                Text(state == .ready ? (ready ?? state.text) : state.text)
                    .font(Typeface.note(.footnote))
                    .foregroundStyle(isFailed(state) ? Color.margin : Color.pencil)
                if case .downloading(let p) = state {
                    InkProgress(fraction: p > 0 ? p : nil).frame(maxWidth: 180).padding(.top, Space.tight)
                }
            }
        }
        .padding(.vertical, Space.item)
    }

    // MARK: - Language

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            PadHeading(title: "Language", message: "The language people speak in your meetings.")
            RuledLine()
            ScrollView {
                VStack(spacing: 0) {
                    languageRow("")
                    ForEach(locales, id: \.identifier) { languageRow($0.identifier) }
                }
            }
            .frame(maxHeight: 420)
        }
    }

    private func languageRow(_ id: String) -> some View {
        Button {
            localeID = id
            pad.dismiss()
        } label: {
            VStack(spacing: 0) {
                MarginRow(metrics: metrics, alignment: .center) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.ballpoint)
                        .opacity(id == localeID ? 1 : 0)
                } page: {
                    Text(languageName(id))
                        .font(Typeface.page(.body, id == localeID ? .semibold : .regular))
                        .foregroundStyle(Color.ink)
                }
                .padding(.vertical, Space.item)
                RuledLine()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(id == localeID ? .isSelected : [])
    }

    private func languageName(_ id: String) -> String {
        if id.isEmpty {
            let current = Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier
            return "Same as iPhone (\(current))"
        }
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }

    // MARK: - Layout helpers

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarginRow(metrics: metrics) {
                Text(title)
                    .font(Typeface.page(.title3, .semibold))
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.bottom, Space.line)
            RuledLine()
            content()
        }
        .padding(.top, Space.section)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            MarginRow(metrics: metrics) { content() }
                .padding(.vertical, Space.row)
            RuledLine()
        }
    }

    private func note(_ text: String) -> some View {
        MarginRow(metrics: metrics) {
            Text(text)
                .font(Typeface.note(.footnote))
                .foregroundStyle(Color.pencil)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Space.item)
    }

    // MARK: - State

    private var isFailed: Bool { isFailed(speechModel) || isFailed(speakerModel) }

    private func checkSummaries() async {
        summaries = .checking
        switch await MeetingSummarizer.check() {
        case .available: summaries = .ready
        case .unavailable(let reason): summaries = .failed(reason)
        }
    }

    private func isFailed(_ state: ModelState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func refresh() async {
        if locales.isEmpty {
            locales = await SpeechModel.supportedLocales()
                .filter { $0.language.languageCode != nil }
                .sorted { languageName($0.identifier) < languageName($1.identifier) }
        }
        speechModel = await SpeechModel.isInstalled(locale: Preferences.locale) ? .ready : .missing
        speakerModel = await SpeakerDiarizer.shared.isPrepared ? .ready : .missing
        await checkSummaries()
    }

    private func testConnection() async {
        guard let server = AccuracyServer(address: serverAddress, token: serverToken) else { return }
        connection = .testing
        do {
            let status = try await server.status()
            switch status.state {
            case "ready":
                connection = .ok("Connected: \(status.model) on \(status.device).")
            case "loading":
                connection = .ok("Connected. The PC is still getting ready: \(status.message ?? "loading models").")
            default:
                connection = .failed(status.message ?? "The server on the PC isn't ready.")
            }
        } catch {
            connection = .failed(error.localizedDescription)
        }
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
