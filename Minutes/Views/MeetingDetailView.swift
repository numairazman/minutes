import MinutesCore
import SwiftUI

struct MeetingDetailView: View {
    let meetingID: UUID

    @Environment(MeetingStore.self) private var store
    @Environment(ProcessingQueue.self) private var processing
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Preferences.exportSummaryKey) private var exportSummary = true
    @AppStorage(Preferences.exportTimestampsKey) private var exportTimestamps = true

    @State private var tab: Tab = .summary
    @State private var player = PlaybackController()
    @State private var renamingSpeaker: String?
    @State private var speakerNameDraft = ""
    @State private var renamingMeeting = false
    @State private var titleDraft = ""
    @State private var confirmDelete = false
    @State private var copied = false

    enum Tab: String, CaseIterable {
        case summary = "Summary"
        case transcript = "Transcript"
    }

    var body: some View {
        if let meeting = store.meeting(meetingID) {
            content(meeting)
        } else {
            ContentUnavailableView("Meeting deleted", systemImage: "trash")
        }
    }

    private func content(_ meeting: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(meeting)
                statusCard(meeting)
                if !meeting.utterances.isEmpty || meeting.summary != nil {
                    Picker("View", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    switch tab {
                    case .summary: SummaryView(meeting: meeting, busy: processing.isBusy(meeting.id)) {
                        processing.enqueue(meeting.id, .summary)
                    }
                    case .transcript: transcript(meeting)
                    }
                } else if meeting.status == .ready {
                    ContentUnavailableView("No speech detected", systemImage: "waveform.slash",
                        description: Text("The recording didn't contain any speech the model could make out."))
                }
            }
            .padding()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(meeting) }
        .safeAreaInset(edge: .bottom) {
            if player.duration > 0 { playerBar }
        }
        .onAppear { player.load(store.audioURL(for: meeting)) }
        .onChange(of: meeting.audioFileName) { player.load(store.audioURL(for: meeting)) }
        .onDisappear { player.stop() }
        .alert("Rename speaker", isPresented: .init(get: { renamingSpeaker != nil }, set: { if !$0 { renamingSpeaker = nil } })) {
            TextField("Name", text: $speakerNameDraft)
                .textInputAutocapitalization(.words)
            Button("Save") {
                if let key = renamingSpeaker {
                    store.update(meeting.id) { $0.speakerNames[key] = speakerNameDraft.trimmingCharacters(in: .whitespaces) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every line from this speaker gets the new name, in the app and in exports.")
        }
        .alert("Rename meeting", isPresented: $renamingMeeting) {
            TextField("Title", text: $titleDraft)
            Button("Save") {
                let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                store.update(meeting.id) {
                    $0.title = title
                    $0.titleIsCustom = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete) {
            Button("Delete Recording and Transcript", role: .destructive) {
                player.stop()
                store.delete(meeting.id)
                dismiss()
            }
        }
        .sensoryFeedback(.success, trigger: copied)
    }

    // MARK: - Sections

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title)
                .font(.title2.bold())
                .onTapGesture {
                    titleDraft = meeting.title
                    renamingMeeting = true
                }
            Text(meeting.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !meeting.speakers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(meeting.speakers, id: \.self) { key in
                            Button {
                                beginRename(key, in: meeting)
                            } label: {
                                SpeakerChip(name: meeting.displayName(forSpeaker: key), key: key)
                            }
                            .buttonStyle(.plain)
                        }
                        Text("Tap a name to rename")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusCard(_ meeting: Meeting) -> some View {
        if let stage = processing.stage(for: meeting.id) {
            card {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.label).font(.subheadline.weight(.medium))
                        Text("Keep Minutes open — this takes a minute or two per hour of audio.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if meeting.status == .processing {
            card { Label("Waiting to process…", systemImage: "hourglass") }
        } else if meeting.status == .interrupted || meeting.status == .failed {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    if meeting.status == .interrupted {
                        Label("The app closed during this recording. The audio up to that point was saved.", systemImage: "exclamationmark.circle")
                    } else {
                        Label(meeting.processingError ?? "Transcription failed.", systemImage: "exclamationmark.triangle")
                    }
                    Button("Process Recording") { processing.enqueue(meeting.id, .full(liveWords: nil)) }
                        .buttonStyle(.borderedProminent)
                }
                .font(.subheadline)
            }
        }
        if let speakerError = meeting.speakerError, processing.stage(for: meeting.id) == nil {
            card { Label(speakerError, systemImage: "person.2.slash").font(.footnote) }
        }
    }

    private func transcript(_ meeting: Meeting) -> some View {
        let playing = currentUtteranceID(meeting)
        let utterances = meeting.utterances
        return LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(utterances.indices, id: \.self) { index in
                let utterance = utterances[index]
                // A paragraph break after a pause isn't a new speaker; don't repeat the name.
                let continues = index > 0 && utterances[index - 1].speaker == utterance.speaker
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if !continues {
                            Button {
                                beginRename(utterance.speaker, in: meeting)
                            } label: {
                                SpeakerChip(name: meeting.displayName(forSpeaker: utterance.speaker), key: utterance.speaker)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Button {
                            player.play(from: utterance.start)
                        } label: {
                            Label(TranscriptExporter.timestamp(utterance.start), systemImage: "play.fill")
                                .font(.caption.monospacedDigit())
                        }
                        .buttonStyle(.borderless)
                        .disabled(player.duration == 0)
                    }
                    Text(utterance.text)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(
                    playing == utterance.id ? SpeakerStyle.color(for: utterance.speaker).opacity(0.12) : .clear,
                    in: .rect(cornerRadius: 10)
                )
            }
        }
    }

    private var playerBar: some View {
        HStack(spacing: 12) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            Slider(value: .init(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
            Text(TranscriptExporter.timestamp(player.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private func toolbar(_ meeting: Meeting) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            ShareLink(
                item: TranscriptFile(meeting: meeting, options: ExportOptions(includeSummary: exportSummary, includeTimestamps: exportTimestamps)),
                preview: SharePreview(TranscriptExporter.fileName(for: meeting))
            ) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(meeting.words.isEmpty)

            Menu {
                Button("Copy Transcript", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = TranscriptExporter.text(for: meeting, options: ExportOptions(includeSummary: exportSummary, includeTimestamps: exportTimestamps))
                    copied.toggle()
                }
                .disabled(meeting.words.isEmpty)
                Button("Rename Meeting", systemImage: "pencil") {
                    titleDraft = meeting.title
                    renamingMeeting = true
                }
                Menu("Number of Speakers", systemImage: "person.2") {
                    Picker("Number of Speakers", selection: speakerCount(meeting)) {
                        Text("Detect automatically").tag(0)
                        ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                .disabled(meeting.words.isEmpty || processing.isBusy(meeting.id))
                Button("Regenerate Summary", systemImage: "sparkles") {
                    processing.enqueue(meeting.id, .summary)
                }
                .disabled(meeting.utterances.isEmpty || processing.isBusy(meeting.id))
                Button("Transcribe Again", systemImage: "arrow.clockwise") {
                    processing.enqueue(meeting.id, .full(liveWords: nil))
                }
                .disabled(processing.isBusy(meeting.id))
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Helpers

    /// Choosing a count re-runs only speaker identification (and the summary, whose names
    /// depend on it) — the words stay as they are.
    private func speakerCount(_ meeting: Meeting) -> Binding<Int> {
        Binding(
            get: { meeting.expectedSpeakers ?? 0 },
            set: { count in
                store.update(meeting.id) { $0.expectedSpeakers = count == 0 ? nil : count }
                processing.enqueue(meeting.id, .speakers)
            }
        )
    }

    private func beginRename(_ key: String, in meeting: Meeting) {
        speakerNameDraft = meeting.speakerNames[key] ?? ""
        renamingSpeaker = key
    }

    private func currentUtteranceID(_ meeting: Meeting) -> Int? {
        guard player.isPlaying else { return nil }
        let t = player.currentTime
        return meeting.utterances.last { $0.start <= t + 0.1 }?.id
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }
}

struct SummaryView: View {
    let meeting: Meeting
    let busy: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let summary = meeting.summary {
                Text(summary.overview)
                    .textSelection(.enabled)
                section("Key points", summary.keyPoints, icon: "list.bullet")
                section("Decisions", summary.decisions, icon: "checkmark.seal")
                section("Action items", summary.actionItems, icon: "checklist")
                Text("Written on this iPhone by Apple Intelligence. Check names and numbers against the transcript.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if let error = meeting.summaryError {
                Label(error, systemImage: "sparkles")
                    .foregroundStyle(.secondary)
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
                    .disabled(busy)
            } else if busy {
                Text("The summary is written once the transcript is ready.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [String], icon: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.headline)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(item).textSelection(.enabled)
                    }
                }
            }
        }
    }
}
