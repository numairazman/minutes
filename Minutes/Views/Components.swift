import MinutesCore
import SwiftUI

enum SpeakerStyle {
    private static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .brown, .indigo, .red, .mint]

    static func color(for key: String) -> Color {
        let index = (Int(key) ?? 1) - 1
        return palette[((index % palette.count) + palette.count) % palette.count]
    }
}

struct SpeakerChip: View {
    let name: String
    let key: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(SpeakerStyle.color(for: key))
                .frame(width: 8, height: 8)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SpeakerStyle.color(for: key))
        }
    }
}

struct LevelMeter: View {
    let levels: [Float]
    var active = true

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(active ? Color.red.opacity(0.85) : Color.secondary.opacity(0.4))
                    .frame(width: 4, height: max(4, CGFloat(levels[i]) * 56))
            }
        }
        .frame(height: 60)
        .animation(.linear(duration: 0.05), value: levels)
        .accessibilityHidden(true)
    }
}

struct StatusLabel: View {
    let meeting: Meeting
    let stage: PipelineStage?

    var body: some View {
        switch meeting.status {
        case .recording:
            Label("Recording", systemImage: "record.circle").foregroundStyle(.red)
        case .processing:
            Label(stage?.label ?? "Waiting to process…", systemImage: "waveform").foregroundStyle(.secondary)
        case .interrupted:
            Label("Recording was cut off — tap to process", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        case .failed:
            Label("Transcription failed", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .ready:
            EmptyView()
        }
    }
}

extension Meeting {
    var subtitle: String {
        var parts = [createdAt.formatted(date: .abbreviated, time: .shortened)]
        if duration > 0 { parts.append(TranscriptExporter.durationText(duration)) }
        let count = speakers.count
        if count > 0 { parts.append(count == 1 ? "1 speaker" : "\(count) speakers") }
        return parts.joined(separator: " · ")
    }
}

/// Exported lazily as a .txt file, so the share sheet offers Save to Files, OneDrive (when its
/// app is installed), Mail, Messages, AirDrop — with a real file name rather than "text.txt".
struct TranscriptFile: Transferable {
    let meeting: Meeting
    let options: ExportOptions

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .utf8PlainText) { item in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(TranscriptExporter.fileName(for: item.meeting))
            try TranscriptExporter.text(for: item.meeting, options: item.options).write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
