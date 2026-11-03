import Foundation
import MinutesCore
import Observation
import WidgetKit

/// Meetings live as plain files: Documents/Meetings/<id>/meeting.json plus the audio. Plain
/// files rather than a database so they also show up in the Files app, and a corrupt meeting
/// can only ever take itself down.
@MainActor
@Observable
final class MeetingStore {
    private(set) var meetings: [Meeting] = []
    private(set) var loadErrors: [String] = []

    let root: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
        updateWidgets()
    }

    func meeting(_ id: UUID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audioURL(for meeting: Meeting) -> URL? {
        guard let name = meeting.audioFileName else { return nil }
        let url = folder(for: meeting.id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Changes

    func save(_ meeting: Meeting) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.append(meeting)
        }
        meetings.sort { $0.createdAt > $1.createdAt }
        write(meeting)
        updateWidgets()
    }

    /// The lock-screen widget shows the newest finished meeting. Written only when that changes,
    /// since `save` runs on every rename and stage. (Without the App Group entitlement the
    /// shared container is missing and this does nothing.)
    private func updateWidgets() {
        let newest = meetings.first { $0.status == .ready }.map {
            WidgetSnapshot.LastMeeting(id: $0.id, title: $0.title, createdAt: $0.createdAt, duration: $0.duration, people: $0.speakers.count)
        }
        guard newest?.id != lastWidgetMeeting?.id || newest?.title != lastWidgetMeeting?.title else { return }
        lastWidgetMeeting = newest
        WidgetSnapshot(lastMeeting: newest).write()
        WidgetCenter.shared.reloadTimelines(ofKind: "last-meeting")
    }

    @ObservationIgnored private var lastWidgetMeeting: WidgetSnapshot.LastMeeting?

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard var meeting = meeting(id) else { return }
        change(&meeting)
        save(meeting)
    }

    func delete(_ id: UUID) {
        meetings.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: folder(for: id))
        updateWidgets()
    }

    /// A new meeting for the recorder, saved immediately as `.recording` so that if the app is
    /// killed mid-meeting, the next launch finds it and offers to process what was captured.
    func createRecording() -> (meeting: Meeting, audioURL: URL) {
        var meeting = Meeting(title: Meeting.defaultTitle(for: Date()), localeIdentifier: Preferences.locale.identifier)
        meeting.audioFileName = "recording.caf"
        try? FileManager.default.createDirectory(at: folder(for: meeting.id), withIntermediateDirectories: true)
        save(meeting)
        return (meeting, folder(for: meeting.id).appendingPathComponent("recording.caf"))
    }

    /// Copies an audio file in (Voice Memos, an email attachment, a Teams recording) so it can
    /// go through the same pipeline as a recording.
    func importAudio(from source: URL) throws -> Meeting {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let title = source.deletingPathExtension().lastPathComponent
        var meeting = Meeting(
            title: title.isEmpty ? Meeting.defaultTitle(for: Date()) : title,
            localeIdentifier: Preferences.locale.identifier,
            status: .processing
        )
        meeting.titleIsCustom = !title.isEmpty
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let name = "audio.\(ext)"
        let folder = folder(for: meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        meeting.audioFileName = name
        meeting.duration = AudioFiles.duration(of: destination)
        if let date = (try? source.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
            meeting.createdAt = date
        }
        save(meeting)
        return meeting
    }

    // MARK: - Disk

    private func load() {
        var loaded: [Meeting] = []
        let decoder = JSONDecoder()
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.hasDirectoryPath {
            let file = folder.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: file) else { continue }
            do {
                var meeting = try decoder.decode(Meeting.self, from: data)
                if meeting.status == .recording {
                    // Nothing is recording at launch, so this one was cut off by a crash or
                    // the system ending the app. Its audio is intact up to that point.
                    meeting.status = .interrupted
                    if let url = audioURL(for: meeting) { meeting.duration = AudioFiles.duration(of: url) }
                    write(meeting)
                }
                loaded.append(meeting)
            } catch {
                loadErrors.append("\(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        meetings = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    private func write(_ meeting: Meeting) {
        do {
            let folder = folder(for: meeting.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(meeting)
            try data.write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
        } catch {
            print("[MeetingStore] couldn't save \(meeting.id): \(error)")
        }
    }
}
