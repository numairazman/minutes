import MinutesCore
import SwiftUI
import UniformTypeIdentifiers

struct MeetingListView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(ProcessingQueue.self) private var processing
    @Environment(RecordingController.self) private var recorder

    @ScaledMetric(relativeTo: .footnote) private var marginWidth: CGFloat = 58

    @State private var path: [Route] = []
    @State private var showingRecorder = false
    @State private var showingImporter = false
    @State private var pad = Pad()

    private var metrics: PageMetrics { PageMetrics(marginWidth: marginWidth) }

    enum Route: Hashable {
        case meeting(UUID)
        case settings
    }

    var body: some View {
        ZStack {
            NavigationStack(path: $path) {
                page
                    .background(PaperPage(metrics: metrics))
                    .toolbar(.hidden, for: .navigationBar)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        PageBar {
                            BarKey(systemImage: "slider.horizontal.3", label: "Settings") { path.append(.settings) }
                        } trailing: {
                            BarKey(systemImage: "tray.and.arrow.down", label: "Import audio") { showingImporter = true }
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { recordDock }
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .meeting(let id): MeetingDetailView(meetingID: id)
                        case .settings: SettingsView()
                        }
                    }
            }
            PadHost(pad: pad)
        }
        .environment(pad)
        .tint(.ballpoint)
        .fullScreenCover(isPresented: $showingRecorder) {
            RecordingView { id in
                showingRecorder = false
                if let id { path = [.meeting(id)] }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio, .movie, .mpeg4Movie]) { result in
            importAudio(result)
        }
        .onOpenURL { url in Task { await open(url) } }
    }

    /// minutes://pair?address=192.168.1.168&token=… from the pairing QR code (`server/pairing-qr.swift`):
    /// saves the PC's address and token, then checks the PC answers.
    private func open(_ url: URL) async {
        guard url.scheme == "minutes" else { return }
        switch url.host() {
        case "record":
            // The lock-screen widget, the Record control, and a tap on the Live Activity while
            // recording. RecordingView starts a recording only if none is running; otherwise it
            // just shows the one in progress.
            showingRecorder = true
            return
        case "stop":
            // Stop on the Live Activity opens the app, so processing (and Apple Intelligence) runs
            // with Minutes on screen.
            if recorder.isActive {
                let id = await recorder.stop(store: store, processing: processing)
                showingRecorder = false
                if let id { path = [.meeting(id)] }
            }
            return
        case "meeting":
            // Never close the recorder for the meeting it's still recording.
            if recorder.isActive {
                showingRecorder = true
                return
            }
            if let id = UUID(uuidString: url.lastPathComponent), store.meeting(id) != nil {
                showingRecorder = false
                path = [.meeting(id)]
            }
            return
        default:
            break
        }
        guard url.host() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let address = items.first(where: { $0.name == "address" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value,
              let server = AccuracyServer(address: address, token: token)
        else { return }
        UserDefaults.standard.set(address, forKey: Preferences.serverAddressKey)
        ServerToken.save(token)
        do {
            let status = try await server.status()
            pad.show {
                NoticeCard(
                    title: "Paired with your PC",
                    message: "Minutes can now re-process a meeting on \(server.baseURL.host() ?? address) with \(status.model) on its \(status.device). Choose it from a meeting's ⋯ menu."
                )
            }
        } catch {
            pad.show {
                NoticeCard(
                    title: "Saved, but the PC didn't answer",
                    message: "The address and token are saved. \(error.localizedDescription) Check the PC is on and the Minutes server is running, then use Test connection in Settings."
                )
            }
        }
    }

    // MARK: - The pad

    private var page: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
            Text("Minutes")
                .font(Typeface.page(.largeTitle, .bold))
                .foregroundStyle(Color.ink)
                .padding(.leading, metrics.ruleX + PageMetrics.gutter / 2)
                .padding(.top, Space.line)
                .accessibilityAddTraits(.isHeader)

            if store.meetings.isEmpty {
                emptyPage
            }

            ForEach(Array(days.enumerated()), id: \.element.heading) { index, day in
                MarginRow(metrics: metrics) {
                    Text(day.heading)
                        .font(Typeface.page(.subheadline, .semibold).italic())
                        .foregroundStyle(Color.pencil)
                        .accessibilityAddTraits(.isHeader)
                }
                // The first day sits under the title; later days get a section's gap.
                .padding(.top, index == 0 ? Space.group : Space.section)
                .padding(.bottom, Space.tight)

                ForEach(day.meetings) { meeting in
                    entry(meeting)
                }
            }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func entry(_ meeting: Meeting) -> some View {
        Button {
            path.append(.meeting(meeting.id))
        } label: {
            VStack(spacing: 0) {
                MarginRow(metrics: metrics) {
                    VStack(alignment: .trailing, spacing: Space.tight) {
                        Text(meeting.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(Typeface.note(.footnote, .medium).monospacedDigit())
                            .foregroundStyle(Color.ink)
                        if meeting.duration > 0 {
                            Text(meeting.shortLength)
                                .font(Typeface.note(.caption).monospacedDigit())
                                .foregroundStyle(Color.pencil)
                        }
                    }
                } page: {
                    VStack(alignment: .leading, spacing: Space.line) {
                        VStack(alignment: .leading, spacing: Space.tight) {
                            Text(meeting.title)
                                .font(Typeface.page(.title3, .semibold))
                                .foregroundStyle(Color.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if meeting.status == .ready, let excerpt = meeting.excerpt {
                                Text(excerpt)
                                    .font(Typeface.page(.subheadline))
                                    .foregroundStyle(Color.pencil)
                                    .lineSpacing(2)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        StatusNote(meeting: meeting, stage: processing.stage(for: meeting.id), compact: true)
                        if !meeting.speakers.isEmpty {
                            HStack(spacing: Space.tight + 2) {
                                ForEach(meeting.speakers.prefix(8), id: \.self) { InkStroke(color: Ink.color(for: $0), length: 14) }
                            }
                            .accessibilityElement()
                            .accessibilityLabel(meeting.peopleText ?? "")
                        }
                    }
                }
                .padding(.vertical, Space.row)
                RuledLine()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(meeting.status == .recording)
    }

    private var emptyPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarginRow(metrics: metrics) {
                VStack(alignment: .leading, spacing: Space.item) {
                    Text("Nothing on the pad yet.")
                        .font(Typeface.page(.title2))
                        .foregroundStyle(Color.ink)
                    Text("Press record when the meeting starts. When you stop, you get the transcript, who said what, and a summary, all made on this iPhone.")
                        .font(Typeface.page(.body))
                        .foregroundStyle(Color.pencil)
                        .lineSpacing(4)
                }
            }
            .padding(.top, Space.group)
            // A few blank ruled lines, as on a fresh page.
            ForEach(0..<6, id: \.self) { _ in
                RuledLine().padding(.top, Space.part)
            }
        }
    }

    // MARK: - Record

    private var recordDock: some View {
        VStack(spacing: Space.line) {
            Button {
                showingRecorder = true
            } label: {
                RecordKey(recording: false)
            }
            .buttonStyle(PressableStyle())
            // While recording, the key goes back to the recording instead of being dead.
            .accessibilityLabel(recorder.isActive ? "Back to recording" : "Record")
            .sensoryFeedback(.impact(weight: .medium), trigger: showingRecorder)
            Text(recorder.isActive ? "Back to recording" : "Record")
                .font(Typeface.note(.footnote, .medium))
                .foregroundStyle(Color.pencil)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.row)
        .padding(.bottom, Space.line)
        .background {
            LinearGradient(colors: [Color.paper.opacity(0), Color.paper, Color.paper], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    // MARK: - Helpers

    private var days: [(heading: String, meetings: [Meeting])] {
        var result: [(heading: String, meetings: [Meeting])] = []
        for meeting in store.meetings {
            let heading = dayHeading(for: meeting.createdAt)
            if result.last?.heading == heading {
                result[result.count - 1].meetings.append(meeting)
            } else {
                result.append((heading, [meeting]))
            }
        }
        return result
    }

    private func importAudio(_ result: Result<URL, Error>) {
        do {
            let meeting = try store.importAudio(from: result.get())
            processing.enqueue(meeting.id, .full(liveWords: nil))
            path = [.meeting(meeting.id)]
        } catch {
            pad.show { NoticeCard(title: "Couldn't import that file", message: error.localizedDescription) }
        }
    }
}
