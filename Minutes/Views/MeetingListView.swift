import MinutesCore
import SwiftUI
import UniformTypeIdentifiers

struct MeetingListView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(ProcessingQueue.self) private var processing
    @Environment(RecordingController.self) private var recorder

    @ScaledMetric(relativeTo: .footnote) private var marginWidth: CGFloat = 62

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
    }

    // MARK: - The pad

    private var page: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
            Text("Minutes")
                .font(Typeface.page(.largeTitle, .bold))
                .foregroundStyle(Color.ink)
                .padding(.leading, metrics.ruleX + PageMetrics.gutter / 2)
                .padding(.top, 4)
                .padding(.bottom, store.meetings.isEmpty ? 0 : 6)
                .accessibilityAddTraits(.isHeader)

            if store.meetings.isEmpty {
                emptyPage
            }

            ForEach(days, id: \.heading) { day in
                MarginRow(metrics: metrics) {
                    Text(day.heading)
                        .font(Typeface.page(.subheadline, .semibold).italic())
                        .foregroundStyle(Color.pencil)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.top, 18)
                .padding(.bottom, 2)

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
                    VStack(alignment: .trailing, spacing: 3) {
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text(meeting.title)
                            .font(Typeface.page(.title3, .semibold))
                            .foregroundStyle(Color.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if meeting.status == .ready, let excerpt = meeting.excerpt {
                            Text(excerpt)
                                .font(Typeface.page(.subheadline))
                                .foregroundStyle(Color.pencil)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        StatusNote(meeting: meeting, stage: processing.stage(for: meeting.id), compact: true)
                        if !meeting.speakers.isEmpty {
                            HStack(spacing: 5) {
                                ForEach(meeting.speakers.prefix(8), id: \.self) { InkStroke(color: Ink.color(for: $0), length: 14) }
                            }
                            .padding(.top, 2)
                            .accessibilityElement()
                            .accessibilityLabel(meeting.peopleText ?? "")
                        }
                    }
                }
                .padding(.vertical, 14)
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
                VStack(alignment: .leading, spacing: 10) {
                    Text("Nothing on the pad yet.")
                        .font(Typeface.page(.title2))
                        .foregroundStyle(Color.ink)
                    Text("Press record when the meeting starts. When you stop, you get the transcript, who said what, and a summary, all made on this iPhone.")
                        .font(Typeface.page(.body))
                        .foregroundStyle(Color.pencil)
                        .lineSpacing(3)
                }
            }
            .padding(.top, 28)
            // A few blank ruled lines, as on a fresh page.
            ForEach(0..<6, id: \.self) { _ in
                RuledLine().padding(.top, 34)
            }
        }
    }

    // MARK: - Record

    private var recordDock: some View {
        VStack(spacing: 8) {
            Button {
                showingRecorder = true
            } label: {
                RecordKey(recording: false)
            }
            .buttonStyle(PressableStyle())
            .disabled(recorder.isActive)
            .accessibilityLabel("Record")
            .sensoryFeedback(.impact(weight: .medium), trigger: showingRecorder)
            Text("Record")
                .font(Typeface.note(.footnote, .medium))
                .foregroundStyle(Color.pencil)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 6)
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
