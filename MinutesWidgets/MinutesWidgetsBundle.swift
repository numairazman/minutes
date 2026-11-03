import AppIntents
import SwiftUI
import WidgetKit

@main
struct MinutesWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        RecordWidget()
        LastMeetingWidget()
        RecordControl()
    }
}

// MARK: - Record (circular and inline)

/// Lock screen: one tap opens Minutes and starts recording.
struct RecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "record", provider: StaticProvider()) { _ in
            RecordWidgetView()
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(MinutesLink.record)
        }
        .configurationDisplayName("Record")
        .description("Start recording a meeting.")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}

private struct RecordWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryInline {
            Label("Record a meeting", systemImage: "record.circle")
        } else {
            // The app's record key: an ink ring around a dot, in the lock screen's own tint.
            ZStack {
                AccessoryWidgetBackground()
                Circle().strokeBorder(lineWidth: 2.5).padding(7)
                Circle().padding(15).widgetAccentable()
            }
            .accessibilityLabel("Record a meeting")
        }
    }
}

struct StaticProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }
    func placeholder(in context: Context) -> Entry { Entry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: Date())], policy: .never))
    }
}

// MARK: - Last meeting (rectangular)

/// Lock screen: the newest meeting's title and length; tap to open its minutes. Before any
/// meeting exists (or without the shared App Group, see project.yml) it offers Record instead.
struct LastMeetingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "last-meeting", provider: LastMeetingProvider()) { entry in
            LastMeetingView(meeting: entry.meeting)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(entry.meeting.map { MinutesLink.meeting($0.id) } ?? MinutesLink.record)
        }
        .configurationDisplayName("Last meeting")
        .description("Your latest meeting's minutes, one tap away.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct LastMeetingProvider: TimelineProvider {
    struct Entry: TimelineEntry {
        let date: Date
        let meeting: WidgetSnapshot.LastMeeting?
    }

    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), meeting: .init(id: UUID(), title: "Weekly sync", createdAt: Date(), duration: 1_800, people: 3))
    }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Entry(date: Date(), meeting: WidgetSnapshot.read().lastMeeting))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app reloads this timeline whenever a meeting finishes; nothing changes otherwise.
        completion(Timeline(entries: [Entry(date: Date(), meeting: WidgetSnapshot.read().lastMeeting)], policy: .never))
    }
}

private struct LastMeetingView: View {
    let meeting: WidgetSnapshot.LastMeeting?

    var body: some View {
        if let meeting {
            VStack(alignment: .leading, spacing: 1) {
                // An absolute day and time: the timeline never refreshes on its own, so "2 hours
                // ago" would stay "2 hours ago" forever.
                Text(meeting.createdAt, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.system(.caption2, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(meeting.title)
                    .font(.system(.headline, design: .serif))
                    .lineLimit(2)
                    .widgetAccentable()
                Text(detail(meeting))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .font(.title2)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Minutes")
                        .font(.system(.headline, design: .serif))
                    Text("Record a meeting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detail(_ meeting: WidgetSnapshot.LastMeeting) -> String {
        let minutes = max(1, Int((meeting.duration / 60).rounded()))
        let length = minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
        return meeting.people > 1 ? "\(length), \(meeting.people) people" : length
    }
}

// MARK: - Record control

/// Lock screen corner, Control Center and the Action button: opens Minutes recording.
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.numairazman.minutes.record") {
            ControlWidgetButton(action: OpenURLIntent(MinutesLink.record)) {
                Label("Record meeting", systemImage: "record.circle")
            }
        }
        .displayName("Record meeting")
        .description("Open Minutes and start recording.")
    }
}
