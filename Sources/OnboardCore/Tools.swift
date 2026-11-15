import AppKit
import Contacts
import EventKit
import Foundation

/// Things Onboard can do without touching the screen: Reminders, Calendar, a Mail draft.
public enum Tools {
    static let store = EKEventStore()

    /// Tests set this so nothing is written to the user's Reminders, Calendar or Mail.
    nonisolated(unsafe) public static var dryRun = false

    /// Turn the Mac's WiFi on or off (the same switch as the menu bar), then read the setting back.
    public static func setWifi(_ on: Bool) -> String {
        if dryRun { return "(dry run) WiFi would be turned \(on ? "on" : "off")" }
        func run(_ args: [String]) -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup"); p.arguments = args
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            guard (try? p.run()) != nil else { return "" }
            p.waitUntilExit()
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        // The WiFi device is usually en0, but ask.
        var device = "en0"
        let ports = run(["-listallhardwareports"]).components(separatedBy: "\n")
        if let i = ports.firstIndex(where: { $0.contains("Wi-Fi") }), i + 1 < ports.count, let d = ports[i + 1].components(separatedBy: ": ").last, !d.isEmpty { device = d }
        _ = run(["-setairportpower", device, on ? "on" : "off"])
        let now = run(["-getairportpower", device]).lowercased()
        let isOn = now.hasSuffix("on\n") || now.hasSuffix("on")
        return isOn == on ? "WiFi is \(on ? "on" : "off")." : "FAILED: I could not turn WiFi \(on ? "on" : "off")."
    }

    static let numberWords: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "half": 0.5]

    /// "in two hours", "in 20 minutes", "in 3 days" (NSDataDetector misses these), else any date it can find.
    public static func date(_ s: String, now: Date = Date()) -> Date? {
        let l = s.lowercased()
        if let m = try? NSRegularExpression(pattern: #"(?:in\s+)?(\d+(?:\.\d+)?|[a-z]+)\s+(minute|min|hour|hr|day|week)s?"#).firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
           let r1 = Range(m.range(at: 1), in: l), let r2 = Range(m.range(at: 2), in: l), let n = Double(l[r1]) ?? numberWords[String(l[r1])] {
            let unit: Double = l[r2].hasPrefix("min") ? 60 : l[r2].hasPrefix("h") ? 3600 : l[r2] == "day" ? 86400 : 604800
            if l.contains("in ") || l.contains("from now") { return now.addingTimeInterval(n * unit) }
        }
        return detect(s)
    }

    static func detect(_ s: String) -> Date? {
        guard !s.isEmpty, let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        return d.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))?.date
    }

    public static func addReminder(_ title: String, when: String) async -> String {
        if dryRun { return "Reminder added: \(title)" + (date(when).map { ", due \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "") }
        guard (try? await store.requestFullAccessToReminders()) == true else { return "Reminders access was not granted" }
        let r = EKReminder(eventStore: store)
        r.title = title; r.calendar = store.defaultCalendarForNewReminders()
        let due = date(when)
        if let d = due { r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d); r.addAlarm(EKAlarm(absoluteDate: d)) }
        do { try store.save(r, commit: true); return "Reminder added: \(title)" + (due.map { ", due \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "") }
        catch { return "Could not add the reminder: \(error.localizedDescription)" }
    }

    public static func addEvent(_ title: String, when: String) async -> String {
        if dryRun { return date(when).map { "Event added: \(title), \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "I could not read the time \"\(when)\"" }
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
        if dryRun { return "Draft opened in Mail (not sent)" }
        NSWorkspace.shared.open(u)
        return "Draft opened in Mail (not sent)"
    }

    /// Look a person up in the Mac's Contacts (on-device). Returns their full name and a phone number or email to message.
    public static func lookupContact(_ name: String) async -> (name: String, handle: String)? {
        let q = name.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let store = CNContactStore()
        guard (try? await store.requestAccess(for: .contacts)) == true else { return nil }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        guard let found = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: q), keysToFetch: keys), !found.isEmpty else { return nil }
        // Prefer an exact first-name or full-name match, then anyone with a mobile number.
        let ranked = found.sorted { a, b in
            func score(_ c: CNContact) -> Int {
                let full = "\(c.givenName) \(c.familyName)".lowercased().trimmingCharacters(in: .whitespaces)
                return (full == q.lowercased() ? 4 : 0) + (c.givenName.lowercased() == q.lowercased() || c.nickname.lowercased() == q.lowercased() ? 2 : 0) + (c.phoneNumbers.isEmpty ? 0 : 1)
            }
            return score(a) > score(b)
        }
        for c in ranked {
            let full = "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
            let mobile = c.phoneNumbers.first { ($0.label ?? "").lowercased().contains("mobile") || ($0.label ?? "").lowercased().contains("iphone") } ?? c.phoneNumbers.first
            if let m = mobile { return (full, m.value.stringValue) }
            if let e = c.emailAddresses.first { return (full, e.value as String) }
        }
        return nil
    }

    /// Opens a new message in Messages with the text filled in. Onboard never presses Send.
    /// `to` may be a phone number or email; anything else (a name) leaves the recipient for the owner to pick.
    public static func draftMessage(to: String, body: String) -> String {
        let t = to.trimmingCharacters(in: .whitespaces)
        let direct = t.contains("@") || t.filter(\.isNumber).count >= 7
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&+=?")
        let b = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let r = direct ? (t.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") : ""
        guard let u = URL(string: "sms:\(r)&body=\(b)") else { return "FAILED: could not build the message" }
        if dryRun { return "Message draft opened in Messages (not sent)" }
        NSWorkspace.shared.open(u)
        return direct ? "Verified: a message to \(t) is drafted in Messages, not sent." : "Verified: Messages is open with the text drafted. \(t.isEmpty ? "No recipient yet" : "Choose \(t) as the recipient"); it is not sent."
    }

    public static func openFile(_ url: URL) -> String { NSWorkspace.shared.open(url) ? "Opened \(url.lastPathComponent)" : "Could not open \(url.lastPathComponent)" }
}
