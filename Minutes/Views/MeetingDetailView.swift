import MinutesCore
import SwiftUI

struct MeetingDetailView: View {
    let meetingID: UUID

    @Environment(MeetingStore.self) private var store
    @Environment(ProcessingQueue.self) private var processing
    @Environment(\.dismiss) private var dismiss
    @Environment(Pad.self) private var pad

    @AppStorage(Preferences.exportSummaryKey) private var exportSummary = true
    @AppStorage(Preferences.exportTimestampsKey) private var exportTimestamps = true
    @AppStorage(Preferences.serverAddressKey) private var serverAddress = ""

    @ScaledMetric(relativeTo: .footnote) private var marginWidth: CGFloat = 58

    @State private var tab: Tab = .summary
    @State private var player = PlaybackController()
    @State private var copied = false

    private var metrics: PageMetrics { PageMetrics(marginWidth: marginWidth) }

    enum Tab: Hashable {
        case summary, transcript
    }

    var body: some View {
        Group {
            if let meeting = store.meeting(meetingID) {
                content(meeting)
            } else {
                MarginRow(metrics: metrics) {
                    Text("This meeting was deleted.")
                        .font(Typeface.page(.title3))
                        .foregroundStyle(Color.pencil)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, Space.section)
            }
        }
        .background(PaperPage(metrics: metrics))
        .tint(.ballpoint)
    }

    private func content(_ meeting: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(meeting)
                notes(meeting)
                if !meeting.utterances.isEmpty || meeting.summary != nil {
                    MarginRow(metrics: metrics) {
                        InkTabs(tabs: [(.summary, "Summary"), (.transcript, "Transcript")], selection: $tab)
                    }
                    .padding(.top, Space.part)
                    RuledLine().padding(.top, Space.tight)
                    Group {
                        switch tab {
                        case .summary: summary(meeting)
                        case .transcript: transcript(meeting)
                        }
                    }
                    .padding(.top, Space.group)
                } else if meeting.status == .ready {
                    MarginRow(metrics: metrics) {
                        Text("No speech was picked up in this recording.")
                            .font(Typeface.page(.body).italic())
                            .foregroundStyle(Color.pencil)
                    }
                    .padding(.top, Space.part)
                }
            }
            .padding(.bottom, Space.section)
        }
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { topBar(meeting) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.duration > 0 { playerDock }
        }
        .onAppear { player.load(store.audioURL(for: meeting)) }
        .onChange(of: meeting.audioFileName) { player.load(store.audioURL(for: meeting)) }
        .onDisappear { player.stop() }
        .sensoryFeedback(.success, trigger: copied)
    }

    // MARK: - Header

    private func header(_ meeting: Meeting) -> some View {
        MarginRow(metrics: metrics) {
            VStack(alignment: .trailing, spacing: Space.tight) {
                Text(meeting.createdAt.formatted(.dateTime.weekday(.abbreviated)))
                    .font(Typeface.note(.caption))
                    .foregroundStyle(Color.pencil)
                Text(meeting.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                    .font(Typeface.note(.footnote, .semibold))
                    .foregroundStyle(Color.ink)
                Text(meeting.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(Typeface.note(.caption).monospacedDigit())
                    .foregroundStyle(Color.pencil)
            }
        } page: {
            VStack(alignment: .leading, spacing: Space.item) {
                Text(meeting.title)
                    .font(Typeface.page(.title, .bold))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { renameMeeting(meeting) }
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHint("Double-tap to rename")
                Text([meeting.duration > 0 ? meeting.lengthText : nil, meeting.peopleText].compactMap { $0 }.joined(separator: ", "))
                    .font(Typeface.note(.subheadline))
                    .foregroundStyle(Color.pencil)
                if !meeting.speakers.isEmpty {
                    FlowLayout(spacing: Space.row, lineSpacing: Space.line) {
                        ForEach(meeting.speakers, id: \.self) { key in
                            Button {
                                beginRename(key, in: meeting)
                            } label: {
                                HStack(spacing: Space.line) {
                                    InkStroke(color: Ink.color(for: key))
                                    Text(meeting.displayName(forSpeaker: key))
                                        .font(Typeface.page(.subheadline, .semibold))
                                        .foregroundStyle(Ink.color(for: key))
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Rename this speaker")
                        }
                    }
                    .padding(.top, Space.tight)
                    if meeting.speakerNames.isEmpty {
                        Text("Tap a name to say who it is.")
                            .font(Typeface.note(.caption))
                            .foregroundStyle(Color.pencil)
                    }
                }
            }
        }
        .padding(.top, Space.item)
    }

    // MARK: - Notes (processing, problems)

    @ViewBuilder
    private func notes(_ meeting: Meeting) -> some View {
        let stage = processing.stage(for: meeting.id)
        if let stage {
            MarginRow(metrics: metrics) {
                VStack(alignment: .leading, spacing: Space.line) {
                    StatusNote(meeting: meeting, stage: stage)
                    Text(stage.isRemote
                        ? "Your PC is doing the work. Keep Minutes open until it's done."
                        : "Keep Minutes open. This takes a minute or two per hour of audio.")
                        .font(Typeface.note(.footnote))
                        .foregroundStyle(Color.pencil)
                }
            }
            .padding(.top, Space.group)
        } else if meeting.status == .processing {
            problem("Waiting its turn behind another meeting.", icon: "hourglass", color: .pencil)
        } else if meeting.status == .interrupted || meeting.status == .failed {
            MarginRow(metrics: metrics) {
                Image(systemName: meeting.status == .failed ? "exclamationmark.triangle" : "exclamationmark.circle")
                    .font(Typeface.note(.subheadline))
                    .foregroundStyle(Color.margin)
            } page: {
                VStack(alignment: .leading, spacing: Space.item) {
                    Text(meeting.status == .failed
                        ? (meeting.processingError ?? "Couldn't transcribe this recording.")
                        : "The app closed during this recording. The audio up to that point is safe.")
                        .font(Typeface.note(.subheadline))
                        .foregroundStyle(Color.ink)
                    Button("Process recording") { processing.enqueue(meeting.id, .full(liveWords: nil)) }
                        .buttonStyle(InkCapsuleStyle())
                }
            }
            .padding(.top, Space.group)
        }
        if stage == nil {
            if let speakerError = meeting.speakerError {
                problem(speakerError, icon: "person.2.slash")
            }
            if let serverError = meeting.serverError {
                problem(serverError, icon: "desktopcomputer.trianglebadge.exclamationmark")
            }
        }
    }

    private func problem(_ text: String, icon: String, color: Color = .margin) -> some View {
        MarginRow(metrics: metrics) {
            Image(systemName: icon)
                .font(Typeface.note(.footnote))
                .foregroundStyle(color)
        } page: {
            Text(text)
                .font(Typeface.note(.footnote))
                .foregroundStyle(Color.pencil)
        }
        .padding(.top, Space.item)
    }

    // MARK: - Summary

    @ViewBuilder
    private func summary(_ meeting: Meeting) -> some View {
        if let summary = meeting.summary {
            VStack(alignment: .leading, spacing: 0) {
                MarginRow(metrics: metrics) {
                    Text(summary.overview)
                        .font(Typeface.page(.body))
                        .foregroundStyle(Color.ink)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                }
                list("Decided", summary.decisions, marker: "checkmark", color: Ink.color(for: "2"))
                list("To do", summary.actionItems, marker: "circle", color: .ballpoint)
                list("Discussed", summary.keyPoints, marker: nil, color: .pencil)
                if let caveat = summary.caveat {
                    MarginRow(metrics: metrics) {
                        Image(systemName: "exclamationmark.circle")
                            .font(Typeface.note(.footnote))
                            .foregroundStyle(Color.margin)
                    } page: {
                        Text(caveat)
                            .font(Typeface.note(.footnote))
                            .foregroundStyle(Color.ink)
                    }
                    .padding(.top, Space.group)
                }
                MarginRow(metrics: metrics) {
                    Image(systemName: meeting.transcriptEngine == nil ? "iphone" : "desktopcomputer")
                        .font(Typeface.note(.caption))
                        .foregroundStyle(Color.pencil)
                } page: {
                    // Exactly what made what: all on this iPhone, or the PC for the transcript
                    // and speakers with Apple Intelligence for the summary.
                    Text("\(meeting.provenance) Check names and numbers against the transcript.")
                        .font(Typeface.page(.caption).italic())
                        .foregroundStyle(Color.pencil)
                        .lineSpacing(2)
                }
                .padding(.top, Space.part)
            }
        } else if let error = meeting.summaryError {
            MarginRow(metrics: metrics) {
                VStack(alignment: .leading, spacing: Space.item) {
                    Text(error)
                        .font(Typeface.page(.body))
                        .foregroundStyle(Color.pencil)
                    Button("Try again") { processing.enqueue(meeting.id, .summary) }
                        .buttonStyle(InkCapsuleStyle())
                        .disabled(processing.isBusy(meeting.id))
                }
            }
        } else if processing.isBusy(meeting.id) {
            MarginRow(metrics: metrics) {
                Text("The summary is written once the transcript is ready.")
                    .font(Typeface.page(.body).italic())
                    .foregroundStyle(Color.pencil)
            }
        }
    }

    /// A summary section: heading on the page, each item's marker in the margin.
    @ViewBuilder
    private func list(_ title: String, _ items: [String], marker: String?, color: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.item) {
                MarginRow(metrics: metrics) {
                    Text(title)
                        .font(Typeface.page(.title3, .semibold))
                        .foregroundStyle(Color.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(items, id: \.self) { item in
                    MarginRow(metrics: metrics) {
                        Group {
                            if let marker {
                                Image(systemName: marker)
                                    .font(.system(size: 13, weight: .semibold))
                            } else {
                                Text("–").font(Typeface.page(.body))
                            }
                        }
                        .foregroundStyle(color)
                    } page: {
                        Text(item)
                            .font(Typeface.page(.body))
                            .foregroundStyle(Color.ink)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, Space.part)
        }
    }

    // MARK: - Transcript

    private func transcript(_ meeting: Meeting) -> some View {
        let playing = currentUtteranceID(meeting)
        let utterances = meeting.utterances
        let long = meeting.duration >= 3600
        return LazyVStack(alignment: .leading, spacing: 0) {
            MarginRow(metrics: metrics) {
                Image(systemName: meeting.transcriptEngine == nil ? "iphone" : "desktopcomputer")
                    .font(Typeface.note(.caption))
                    .foregroundStyle(Color.pencil)
            } page: {
                Text("Transcript and speakers from \(meeting.transcriptSource).")
                    .font(Typeface.note(.caption))
                    .foregroundStyle(Color.pencil)
            }
            .padding(.bottom, Space.row)
            ForEach(utterances.indices, id: \.self) { index in
                let utterance = utterances[index]
                // A paragraph break after a pause isn't a new speaker; don't repeat the name.
                let continues = index > 0 && utterances[index - 1].speaker == utterance.speaker
                let ink = Ink.color(for: utterance.speaker)
                MarginRow(metrics: metrics) {
                    Button {
                        player.play(from: utterance.start)
                    } label: {
                        Text(clockText(utterance.start, long: long))
                            .font(Typeface.note(.footnote).monospacedDigit())
                            .foregroundStyle(player.duration > 0 ? Color.ballpoint : Color.pencil)
                    }
                    .buttonStyle(.plain)
                    .disabled(player.duration == 0)
                    .accessibilityLabel("Play from \(clockText(utterance.start, long: long))")
                } page: {
                    VStack(alignment: .leading, spacing: Space.tight) {
                        if !continues {
                            Button {
                                beginRename(utterance.speaker, in: meeting)
                            } label: {
                                Text(meeting.displayName(forSpeaker: utterance.speaker))
                                    .font(Typeface.page(.subheadline, .semibold))
                                    .foregroundStyle(ink)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Rename this speaker")
                        }
                        Text(utterance.text)
                            .font(Typeface.page(.body))
                            .foregroundStyle(Color.ink)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, Space.tight)
                    .padding(.trailing, Space.tight)
                    .background(alignment: .leading) {
                        // The margin rule takes the speaker's ink for as long as they talk.
                        Capsule()
                            .fill(ink)
                            .frame(width: 3)
                            .offset(x: -PageMetrics.gutter / 2 - 1.5)
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ink.opacity(playing == utterance.id ? 0.10 : 0))
                            .padding(.horizontal, -6)
                    }
                    .animation(.easeOut(duration: 0.25), value: playing)
                }
                .padding(.top, continues ? Space.line : Space.group)
            }
        }
    }

    // MARK: - Player

    private var playerDock: some View {
        HStack(spacing: Space.item) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.paper)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.ink))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            InkScrubber(value: .init(get: { player.currentTime }, set: { player.seek(to: $0) }), total: player.duration)
            Text("\(clockText(player.currentTime, long: player.duration >= 3600)) / \(clockText(player.duration, long: player.duration >= 3600))")
                .font(Typeface.note(.caption).monospacedDigit())
                .foregroundStyle(Color.pencil)
                .fixedSize()
        }
        .padding(.leading, Space.line)
        .padding(.trailing, Space.row)
        .padding(.vertical, Space.line)
        .background(Capsule().fill(Color.paperRaised))
        .overlay(Capsule().strokeBorder(Color.rule, lineWidth: 1))
        .padding(.horizontal, PageMetrics.edge)
        .padding(.top, Space.group)
        .padding(.bottom, Space.line)
        .background {
            // The page fades out under the player rather than showing through around it.
            LinearGradient(colors: [Color.paper.opacity(0), Color.paper, Color.paper], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    // MARK: - Top bar and menu

    private func topBar(_ meeting: Meeting) -> some View {
        PageBar {
            BackKey()
        } trailing: {
            ShareLink(
                item: TranscriptFile(meeting: meeting, options: exportOptions),
                preview: SharePreview(TranscriptExporter.fileName(for: meeting))
            ) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(meeting.words.isEmpty)
            .opacity(meeting.words.isEmpty ? 0.35 : 1)
            .accessibilityLabel("Export")
            BarKey(systemImage: "ellipsis", label: "More") { pad.show { menu(meeting) } }
        }
    }

    private var exportOptions: ExportOptions {
        ExportOptions(includeSummary: exportSummary, includeTimestamps: exportTimestamps)
    }

    /// Everything you can do to a meeting, as one card.
    private func menu(_ meeting: Meeting) -> some View {
        let busy = processing.isBusy(meeting.id)
        return VStack(alignment: .leading, spacing: 0) {
            PadHeading(title: meeting.title)
            RuledLine()
            PadAction(title: "Copy transcript", icon: "doc.on.doc", enabled: !meeting.words.isEmpty) {
                UIPasteboard.general.string = TranscriptExporter.text(for: meeting, options: exportOptions)
                copied.toggle()
                pad.dismiss()
            }
            PadAction(title: "Rename meeting", icon: "pencil") { renameMeeting(meeting) }
            SpeakerCountRow(current: meeting.expectedSpeakers ?? 0, enabled: !meeting.words.isEmpty && !busy) { count in
                pad.dismiss()
                setSpeakerCount(count, for: meeting)
            }
            PadAction(title: "Write the summary again", icon: "sparkles", enabled: !meeting.utterances.isEmpty && !busy) {
                pad.dismiss()
                processing.enqueue(meeting.id, .summary)
            }
            PadAction(title: "Transcribe again", icon: "arrow.clockwise", enabled: !busy) {
                pad.dismiss()
                processing.enqueue(meeting.id, .full(liveWords: nil))
            }
            if !serverAddress.isEmpty {
                PadAction(
                    title: "Re-process for maximum accuracy",
                    icon: "desktopcomputer",
                    enabled: !busy && store.audioURL(for: meeting) != nil && Preferences.accuracyServer != nil
                ) {
                    pad.show {
                        ConfirmCard(
                            title: "Re-process on your PC?",
                            message: "Sends this recording to \(Preferences.accuracyServer?.baseURL.host() ?? "your PC"), which transcribes it with Whisper large-v3 and identifies the speakers again. The transcript, speakers and summary are replaced when it's done; if it fails, the current transcript stays.",
                            actionTitle: "Re-process"
                        ) {
                            if let server = Preferences.accuracyServer { processing.enqueue(meeting.id, .server(server)) }
                        }
                    }
                }
            }
            PadAction(title: "Delete", icon: "trash", destructive: true) {
                pad.show {
                    ConfirmCard(
                        title: "Delete this meeting?",
                        message: "The recording and transcript are removed from this iPhone. Copies you've exported stay where you saved them.",
                        actionTitle: "Delete",
                        destructive: true
                    ) {
                        player.stop()
                        store.delete(meeting.id)
                        dismiss()
                    }
                }
            }
        }
    }

    private func renameMeeting(_ meeting: Meeting) {
        pad.show {
            RenameCard(title: "Rename meeting", placeholder: "Title", initial: meeting.title) { title in
                guard !title.isEmpty else { return }
                store.update(meeting.id) {
                    $0.title = title
                    $0.titleIsCustom = true
                }
            }
        }
    }

    // MARK: - Helpers

    /// Choosing a count re-runs only speaker identification (and the summary, whose names
    /// depend on it) — the words stay as they are. A meeting the PC re-processed goes back to
    /// the PC, so its speakers keep coming from the same models as its words.
    private func setSpeakerCount(_ count: Int, for meeting: Meeting) {
        store.update(meeting.id) { $0.expectedSpeakers = count == 0 ? nil : count }
        if meeting.transcriptEngine != nil, let server = Preferences.accuracyServer {
            processing.enqueue(meeting.id, .server(server))
        } else {
            processing.enqueue(meeting.id, .speakers)
        }
    }

    private func beginRename(_ key: String, in meeting: Meeting) {
        pad.show {
            RenameCard(
                title: "Who is \(meeting.displayName(forSpeaker: key))?",
                message: "Every line from this speaker gets the name, here and in exports.",
                placeholder: "Name",
                initial: meeting.speakerNames[key] ?? ""
            ) { name in
                store.update(meeting.id) { $0.speakerNames[key] = name }
            }
        }
    }

    private func currentUtteranceID(_ meeting: Meeting) -> Int? {
        guard player.isPlaying else { return nil }
        let t = player.currentTime
        return meeting.utterances.last { $0.start <= t + 0.1 }?.id
    }
}

/// A text button outlined in blue ballpoint — the pad's only "button" look.
struct InkCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.note(.subheadline, .semibold))
            .foregroundStyle(isEnabled ? Color.ballpoint : Color.pencil)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(Capsule().strokeBorder(isEnabled ? Color.ballpoint : Color.rule, lineWidth: 1.5))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Lays children out left to right, wrapping onto new lines — for the speaker legend.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// "Number of speakers" as a row of numerals to tick, instead of a nested system menu.
struct SpeakerCountRow: View {
    let current: Int
    var enabled = true
    let pick: (Int) -> Void
    @Environment(\.pageMetrics) private var metrics

    var body: some View {
        VStack(spacing: 0) {
            MarginRow(metrics: metrics) {
                Image(systemName: "person.2")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ink)
            } page: {
                VStack(alignment: .leading, spacing: Space.item) {
                    Text("Number of speakers")
                        .font(Typeface.page(.body))
                        .foregroundStyle(Color.ink)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.line) {
                            choice(0, "Auto")
                            ForEach(1...8, id: \.self) { choice($0, "\($0)") }
                        }
                    }
                    .scrollClipDisabled()
                }
            }
            .padding(.vertical, Space.row)
            RuledLine()
        }
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }

    private func choice(_ value: Int, _ label: String) -> some View {
        let selected = value == current
        return Button {
            pick(value)
        } label: {
            Text(label)
                .font(Typeface.page(.body, selected ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(selected ? Color.paper : Color.ink)
                .frame(minWidth: 34, minHeight: 34)
                .padding(.horizontal, value == 0 ? 8 : 0)
                .background {
                    if selected {
                        Capsule().fill(Color.ballpoint)
                    } else {
                        Capsule().strokeBorder(Color.rule, lineWidth: 1.2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == 0 ? "Detect automatically" : "\(value) speakers")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
