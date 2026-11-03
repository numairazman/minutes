import MinutesCore
import SwiftUI

struct RecordingView: View {
    /// Called with the saved meeting's id, or nil if nothing was kept.
    let onFinish: (UUID?) -> Void

    @Environment(MeetingStore.self) private var store
    @Environment(ProcessingQueue.self) private var processing
    @Environment(RecordingController.self) private var recorder

    @State private var startError: String?
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 20) {
            header
            LevelMeter(levels: recorder.levels, active: recorder.phase == .recording)
            if let notice = recorder.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            }
            transcript
            controls
        }
        .padding()
        .task { await start() }
        .interactiveDismissDisabled()
        .alert("Couldn't start recording", isPresented: .init(get: { startError != nil }, set: { if !$0 { startError = nil } })) {
            Button("OK") { onFinish(nil) }
        } message: {
            Text(startError ?? "")
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard) {
            Button("Discard Recording", role: .destructive) {
                Task {
                    await recorder.discard(store: store)
                    onFinish(nil)
                }
            }
        } message: {
            Text("The audio and transcript so far will be deleted.")
        }
        .sensoryFeedback(.start, trigger: recorder.phase == .recording)
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(recorder.phase == .recording ? Color.red : Color.secondary)
                    .symbolEffect(.pulse, isActive: recorder.phase == .recording)
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(TranscriptExporter.timestamp(recorder.elapsed))
                .font(.system(size: 54, weight: .light, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
        }
        .padding(.top, 12)
    }

    private var statusText: String {
        switch recorder.phase {
        case .idle, .starting: return "Starting…"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Saving…"
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if recorder.finalizedText.isEmpty && recorder.volatileText.isEmpty {
                        Text("Live transcript appears here as people talk. Speakers are worked out when you stop.")
                            .foregroundStyle(.tertiary)
                    } else {
                        let finalized = Text(verbatim: recorder.finalizedText + (recorder.finalizedText.isEmpty ? "" : " "))
                        let volatile = Text(verbatim: recorder.volatileText).foregroundStyle(.secondary)
                        Text("\(finalized)\(volatile)")
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 16))
            .onChange(of: recorder.finalizedText.count + recorder.volatileText.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Button {
                confirmDiscard = true
            } label: {
                Image(systemName: "trash")
                    .font(.title2)
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Discard")

            Button {
                Task {
                    let id = await recorder.stop(store: store, processing: processing)
                    onFinish(id)
                }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.largeTitle)
                    .frame(width: 84, height: 84)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(.red)
            .accessibilityLabel("Stop and process")

            Button {
                recorder.phase == .paused ? recorder.resume() : recorder.pause()
            } label: {
                Image(systemName: recorder.phase == .paused ? "play.fill" : "pause.fill")
                    .font(.title2)
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel(recorder.phase == .paused ? "Resume" : "Pause")
        }
        .disabled(recorder.phase != .recording && recorder.phase != .paused)
        .padding(.bottom, 8)
    }

    private func start() async {
        guard recorder.phase == .idle else { return }
        do {
            try await recorder.start(store: store)
        } catch {
            startError = error.localizedDescription
        }
    }
}
