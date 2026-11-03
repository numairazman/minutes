import Foundation

/// What the lock-screen widgets show, written by the app into the shared App Group container
/// whenever meetings change. Plain JSON so the extension needs nothing from MinutesCore.
struct WidgetSnapshot: Codable {
    struct LastMeeting: Codable {
        var id: UUID
        var title: String
        var createdAt: Date
        var duration: TimeInterval
        var people: Int
    }

    var lastMeeting: LastMeeting?

    static let appGroup = "group.com.numairazman.minutes"

    /// In the group's Library folder: the conventional place, and the one `devicectl` can read
    /// back for checking from a Mac.
    private static var url: URL? {
        guard let library = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Library", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return library.appendingPathComponent("widget-snapshot.json")
    }

    static func read() -> WidgetSnapshot {
        guard let url, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return WidgetSnapshot(lastMeeting: nil) }
        return snapshot
    }

    func write() {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
