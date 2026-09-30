import EventKit
import Foundation

/// Your calendar, for the brief: the next few days of events, read here with EventKit and left
/// in `~/.local/share/frog/pond/senses/calendar.json` for the engine's calendar sense
/// (crates/frog-engine/src/pond/calendar.rs). Opt-in; turning it off deletes the snapshot.
@MainActor
enum CalendarSense {
    static let key = "calendarSense"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    private static let file = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".local/share/frog/pond/senses/calendar.json")

    private static let store = EKEventStore()

    /// Ask for access; true when frog may read the calendar.
    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    static var authorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Write today and the next three days, when the sense is on and allowed.
    static func snapshot() {
        guard enabled, authorized else { return }
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 4, to: start) ?? .now
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { $0.status != .canceled && !declined($0) }
            .map { e in
                Snapshot.Event(title: e.title ?? "Busy", start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                               calendar: e.calendar?.title, location: e.location.flatMap { $0.isEmpty ? nil : $0 })
            }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(Snapshot(at: .now, events: events)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Off: the engine stops seeing the calendar at once.
    static func forget() {
        try? FileManager.default.removeItem(at: file)
    }

    /// Events you said no to aren't part of your day.
    private static func declined(_ e: EKEvent) -> Bool {
        e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    private struct Snapshot: Encodable {
        var at: Date
        var events: [Event]
        struct Event: Encodable {
            var title: String
            var start: Date
            var end: Date
            var allDay: Bool
            var calendar: String?
            var location: String?
        }
    }
}
