import MinutesCore
import SwiftUI
import UniformTypeIdentifiers

struct MeetingListView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(ProcessingQueue.self) private var processing
    @Environment(RecordingController.self) private var recorder

    @State private var path: [UUID] = []
    @State private var showingRecorder = false
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var pendingDelete: Meeting?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.meetings.isEmpty {
                    ContentUnavailableView {
                        Label("No meetings yet", systemImage: "waveform")
                    } description: {
                        Text("Tap Record when your meeting starts. When you stop, Minutes transcribes it, works out who said what, and writes a summary — all on this iPhone.")
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Minutes")
            .navigationDestination(for: UUID.self) { id in
                MeetingDetailView(meetingID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import audio", systemImage: "square.and.arrow.down") { showingImporter = true }
                }
            }
            .safeAreaInset(edge: .bottom) { recordButton }
        }
        .fullScreenCover(isPresented: $showingRecorder) {
            RecordingView { id in
                showingRecorder = false
                if let id { path = [id] }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio, .movie, .mpeg4Movie]) { result in
            importAudio(result)
        }
        .confirmationDialog("Delete this meeting?", isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { meeting in
            Button("Delete Recording and Transcript", role: .destructive) { store.delete(meeting.id) }
        } message: { meeting in
            Text("“\(meeting.title)” will be removed from this iPhone. Anything you've already exported stays where you saved it.")
        }
        .alert("Something went wrong", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var list: some View {
        List {
            ForEach(store.meetings) { meeting in
                NavigationLink(value: meeting.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(meeting.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        StatusLabel(meeting: meeting, stage: processing.stage(for: meeting.id))
                            .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
                .disabled(meeting.status == .recording)
                .swipeActions {
                    if meeting.status != .recording {
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = meeting }
                    }
                }
            }
        }
    }

    private var recordButton: some View {
        Button {
            showingRecorder = true
        } label: {
            Label("Record", systemImage: "mic.fill")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .disabled(recorder.isActive)
    }

    private func importAudio(_ result: Result<URL, Error>) {
        do {
            let meeting = try store.importAudio(from: result.get())
            processing.enqueue(meeting.id, .full(liveWords: nil))
            path = [meeting.id]
        } catch {
            errorMessage = "Couldn't import that file: \(error.localizedDescription)"
        }
    }
}
