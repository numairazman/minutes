import MinutesCore
import SwiftUI

struct RecordingView: View {
    /// Called with the saved meeting's id, or nil if nothing was kept.
    let onFinish: (UUID?) -> Void

    @Environment(MeetingStore.self) private var store
    @Environment(ProcessingQueue.self) private var processing
    @Environment(RecordingController.self) private var recorder

    @ScaledMetric(relativeTo: .footnote) private var marginWidth: CGFloat = 58
    /// This screen is its own full-screen cover, above the app's card host, so it has its own.
    @State private var pad = Pad()

    private var metrics: PageMetrics { PageMetrics(marginWidth: marginWidth) }
    private var isRecording: Bool { recorder.phase == .recording }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            clock
            PenTrace(levels: recorder.levels, tick: recorder.levelTick, active: isRecording)
                .frame(height: 96)
                .padding(.top, Space.row)
            RuledLine()
            if let notice = recorder.notice {
                MarginRow(metrics: metrics) {
                    Image(systemName: "info.circle")
                        .font(Typeface.note(.footnote))
                        .foregroundStyle(Color.pencil)
                } page: {
                    Text(notice)
                        .font(Typeface.note(.footnote))
                        .foregroundStyle(Color.pencil)
                }
                .padding(.vertical, Space.item)
                RuledLine()
            }
            liveText
            controls
        }
        .background(PaperPage(metrics: metrics))
        .overlay { PadHost(pad: pad) }
        .environment(pad)
        .tint(.ballpoint)
        .task { await start() }
        .interactiveDismissDisabled()
        .sensoryFeedback(.start, trigger: isRecording)
    }

    private var topBar: some View {
        MarginRow(metrics: metrics, alignment: .center) {
            Circle()
                .fill(isRecording ? Color.margin : Color.pencil)
                .frame(width: 10, height: 10)
                .phaseAnimator([1.0, 0.3], trigger: isRecording) { dot, phase in
                    dot.opacity(isRecording ? phase : 0.6)
                } animation: { _ in .easeInOut(duration: 0.9) }
                .accessibilityHidden(true)
        } page: {
            HStack {
                Text(statusText)
                    .font(Typeface.note(.subheadline, .medium))
                    .foregroundStyle(Color.ink)
                Spacer()
            Button {
                pad.show {
                    ConfirmCard(
                        title: "Discard this recording?",
                        message: "The audio and the transcript so far will be deleted.",
                        actionTitle: "Discard recording",
                        destructive: true
                    ) {
                        Task {
                            await recorder.discard(store: store)
                            onFinish(nil)
                        }
                    }
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.pencil)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Discard")
            .disabled(recorder.phase != .recording && recorder.phase != .paused)
            }
        }
        .padding(.top, Space.line)
    }

    private var statusText: String {
        switch recorder.phase {
        case .idle, .starting: return "Starting"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Saving"
        }
    }

    private var clock: some View {
        MarginRow(metrics: metrics) {
            VStack(alignment: .trailing, spacing: Space.tight) {
                Text("Began")
                    .font(Typeface.note(.caption))
                    .foregroundStyle(Color.pencil)
                Text((recorder.startedAt ?? Date()).formatted(date: .omitted, time: .shortened))
                    .font(Typeface.note(.footnote, .medium).monospacedDigit())
                    .foregroundStyle(Color.ink)
            }
        } page: {
            Text(clockText(recorder.elapsed))
                .font(.system(size: 60, weight: .light, design: .serif).monospacedDigit())
                .foregroundStyle(Color.ink)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityLabel("Elapsed \(clockText(recorder.elapsed))")
        }
        .padding(.top, Space.group)
    }

    private var liveText: some View {
        ScrollViewReader { proxy in
            ScrollView {
                MarginRow(metrics: metrics) {
                    if recorder.finalizedText.isEmpty && recorder.volatileText.isEmpty {
                        Text("Words appear here as people talk. Who said what is worked out when you stop.")
                            .font(Typeface.page(.body).italic())
                            .foregroundStyle(Color.pencil)
                    } else {
                        let finalized = Text(verbatim: recorder.finalizedText + (recorder.finalizedText.isEmpty ? "" : " "))
                            .foregroundStyle(Color.ink)
                        let volatile = Text(verbatim: recorder.volatileText)
                            .foregroundStyle(Color.pencil)
                        Text("\(finalized)\(volatile)")
                            .font(Typeface.page(.title3))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, Space.group)
                Color.clear.frame(height: 1).id("end")
            }
            .scrollIndicators(.hidden)
            // Live text grows from the bottom, next to the controls; the hint sits at the top.
            .defaultScrollAnchor(recorder.finalizedText.isEmpty && recorder.volatileText.isEmpty ? .top : .bottom)
            .onChange(of: recorder.finalizedText.count + recorder.volatileText.count) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            RuledLine()
            HStack {
                Color.clear.frame(width: 56, height: 56)
                Spacer()
                Button {
                    Task {
                        let id = await recorder.stop(store: store, processing: processing)
                        onFinish(id)
                    }
                } label: {
                    RecordKey(recording: true, size: 84)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Stop and process")
                Spacer()
                Button {
                    recorder.phase == .paused ? recorder.resume() : recorder.pause()
                } label: {
                    InkKey(systemImage: recorder.phase == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(recorder.phase == .paused ? "Resume" : "Pause")
            }
            .padding(.horizontal, Space.part)
            .padding(.top, Space.group)
            .padding(.bottom, Space.item)
            .disabled(recorder.phase != .recording && recorder.phase != .paused)
        }
        .background(Color.paper)
    }

    private func start() async {
        // Reopened while a recording runs (from the Live Activity or the list): just show it.
        guard recorder.phase == .idle else { return }
        do {
            try await recorder.start(store: store)
        } catch {
            pad.show {
                NoticeCard(title: "Couldn't start recording", message: error.localizedDescription) { onFinish(nil) }
            }
        }
    }
}
