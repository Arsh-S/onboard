import AppKit
import EventKit
import Foundation

/// Things Onboard can do without touching the screen: Reminders, Calendar, a Mail draft.
public enum Tools {
    static let store = EKEventStore()

    public static func date(_ s: String) -> Date? {
        guard !s.isEmpty, let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        return d.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))?.date
    }

    public static func addReminder(_ title: String, when: String) async -> String {
        guard (try? await store.requestFullAccessToReminders()) == true else { return "Reminders access was not granted" }
        let r = EKReminder(eventStore: store)
        r.title = title; r.calendar = store.defaultCalendarForNewReminders()
        let due = date(when)
        if let d = due { r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d); r.addAlarm(EKAlarm(absoluteDate: d)) }
        do { try store.save(r, commit: true); return "Reminder added: \(title)" + (due.map { ", due \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "") }
        catch { return "Could not add the reminder: \(error.localizedDescription)" }
    }

    public static func addEvent(_ title: String, when: String) async -> String {
        guard (try? await store.requestFullAccessToEvents()) == true else { return "Calendar access was not granted" }
        guard let start = date(when) else { return "I could not read the time \"\(when)\"" }
        let e = EKEvent(eventStore: store)
        e.title = title; e.startDate = start; e.endDate = start.addingTimeInterval(1800); e.calendar = store.defaultCalendarForNewEvents
        do { try store.save(e, span: .thisEvent); return "Event added: \(title), \(start.formatted(date: .abbreviated, time: .shortened))" }
        catch { return "Could not add the event: \(error.localizedDescription)" }
    }

    /// Opens a draft in Mail. Onboard never presses Send.
    public static func draftEmail(to: String, subject: String, body: String) -> String {
        var c = URLComponents(); c.scheme = "mailto"; c.path = to
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        guard let u = c.url else { return "Could not build the draft" }
        NSWorkspace.shared.open(u)
        return "Draft opened in Mail (not sent)"
    }

    public static func openFile(_ url: URL) -> String { NSWorkspace.shared.open(url) ? "Opened \(url.lastPathComponent)" : "Could not open \(url.lastPathComponent)" }
}
