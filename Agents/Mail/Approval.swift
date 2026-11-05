import CryptoKit
import Foundation
import os

/// Anything Claude proposed that only this phone can approve: an email, a text,
/// or a change to / deletion of an existing calendar event. mailgate holds it.
///
/// SAME RULE AS MailPending, FOR EVERY KIND: the phone recomputes the hash from
/// the exact fields it shows and reads aloud (`computedHash`, mailgate's
/// src/kinds.js byte for byte), signs THAT, and refuses when it differs from
/// what mailgate reported. The hub runs as atlas and is not trusted to relay
/// the right item. The kind is inside the hash (field 0 for every new kind),
/// so relabelling a text as an email just fails the check.
struct Approval: Equatable, Identifiable, Sendable {
    struct Text: Codable, Equatable, Sendable {
        let chat_guid: String
        let chat_name: String
        let recipients: [String]
        let text: String
    }
    /// The six display strings mailgate formats. Times are
    /// "YYYY-MM-DDTHH:MM:SS±HH:MM", or "YYYY-MM-DD" when all_day is "1"
    /// (end = last day, inclusive).
    struct Event: Codable, Equatable, Sendable {
        let title: String
        let start: String
        let end: String
        let all_day: String
        let location: String
        let notes: String
        var fields: [String] { [title, start, end, all_day, location, notes] }
    }
    struct EventChange: Codable, Equatable, Sendable {
        let calendar: String
        let event_id: String
        let etag: String
        let organizer: String
        let attendees: String
        let before: Event
        let after: Event?
    }
    /// How much of a repeating event goes (mailgate's SERIES_SCOPES).
    enum SeriesScope: String, Codable, Equatable, Sendable {
        case one, future, all
    }
    /// A whole calendar: mailgate's collection href, its name now, and for a
    /// delete how many events go with it (a string, as hashed).
    struct CalendarRef: Codable, Equatable, Sendable {
        let calendar_id: String
        let name: String
    }
    enum Payload: Equatable, Sendable {
        case mail(MailPending.Message)
        case text(Text)
        case eventUpdate(EventChange, after: Event)
        case eventDelete(EventChange)
        /// `before` is the occurrence (or, for .all, the first one); `occurrence`
        /// is its original start, which is what mailgate removes.
        case seriesDelete(EventChange, scope: SeriesScope, occurrence: String)
        case calendarCreate(name: String)
        case calendarRename(CalendarRef, newName: String)
        case calendarDelete(CalendarRef, events: String)
    }

    let id: String
    let hash: String
    let expiresAt: Int64
    let payload: Payload

    init(id: String, hash: String, expiresAt: Int64, payload: Payload) {
        self.id = id
        self.hash = hash
        self.expiresAt = expiresAt
        self.payload = payload
    }

    init(mail p: MailPending) {
        self.init(id: p.id, hash: p.hash, expiresAt: p.expiresAt, payload: .mail(p.message))
    }

    // MARK: hash

    var hashFields: [String] {
        switch payload {
        case .mail(let m):
            return MailPending(id: id, hash: hash, expiresAt: expiresAt, message: m).hashFields
        case .text(let t):
            return ["imessage", t.chat_guid, t.chat_name, t.recipients.joined(separator: "\n"), t.text]
        case .eventUpdate(let c, let after):
            return Self.head("calendar_update", c) + c.before.fields + after.fields
        case .eventDelete(let c):
            return Self.head("calendar_delete", c) + c.before.fields
        case .seriesDelete(let c, let scope, let occurrence):
            return Self.head("calendar_delete_series", c) + [scope.rawValue, occurrence] + c.before.fields
        case .calendarCreate(let name):
            return ["calendar_create_calendar", name]
        case .calendarRename(let c, let newName):
            return ["calendar_rename_calendar", c.calendar_id, c.name, newName]
        case .calendarDelete(let c, let events):
            return ["calendar_delete_calendar", c.calendar_id, c.name, events]
        }
    }

    private static func head(_ kind: String, _ c: EventChange) -> [String] {
        [kind, c.calendar, c.event_id, c.etag, c.organizer, c.attendees]
    }

    var computedHash: String {
        let input = hashFields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var isIntact: Bool { computedHash == hash }

    // MARK: words

    var noun: String {
        switch payload {
        case .mail: "email"
        case .text: "text"
        case .eventUpdate: "calendar change"
        case .eventDelete, .seriesDelete: "calendar deletion"
        case .calendarCreate: "new calendar"
        case .calendarRename: "calendar rename"
        case .calendarDelete: "calendar deletion"
        }
    }

    var actionTitle: String {
        switch payload {
        case .mail, .text: "Send"
        case .eventUpdate: "Change"
        case .eventDelete, .seriesDelete, .calendarDelete: "Delete"
        case .calendarCreate: "Create"
        case .calendarRename: "Rename"
        }
    }

    var doneSentence: String {
        switch payload {
        case .mail, .text: "Sent."
        case .eventUpdate: "Changed it."
        case .eventDelete, .seriesDelete, .calendarDelete: "Deleted it."
        case .calendarCreate: "Created it."
        case .calendarRename: "Renamed it."
        }
    }

    /// Read aloud before listening. Built HERE from the hashed fields, never
    /// from Claude's reply, so what is heard is what is signed. The spoken
    /// word that approves is "send" for every kind (SpokenConfirm is strict).
    var readBack: String {
        switch payload {
        case .mail(let m):
            return MailPending(id: id, hash: hash, expiresAt: expiresAt, message: m).readBack
        case .text(let t):
            // THE MESSAGE ALONE, as Siri says it: the recipient was settled a
            // turn ago ("What do you want to say to Alex?"), and the card
            // shows it with the exact handles mailgate resolved.
            return "It says: \(Self.sentence(t.text)) Send it?"
        case .eventUpdate(let c, let after):
            var s = "Change the calendar event \(c.before.title), \(Self.spoken(c.before)). "
            s += Self.changes(from: c.before, to: after).joined(separator: " ")
            return s + Self.invite(c) + " Say send to change it, or cancel."
        case .eventDelete(let c):
            var s = "Delete the calendar event \(c.before.title), \(Self.spoken(c.before))"
            if !c.before.location.isEmpty { s += ", at \(c.before.location)" }
            return s + "." + Self.invite(c) + " Say send to delete it, or cancel."
        case .seriesDelete(let c, let scope, _):
            let at = c.before.location.isEmpty ? "" : ", at \(c.before.location)"
            let when = Self.spoken(c.before)
            switch scope {
            case .one:
                return "Delete just one time of the repeating event \(c.before.title): \(when)\(at). The others stay."
                    + Self.invite(c) + " Say send to delete it, or cancel."
            case .future:
                return "Delete the repeating event \(c.before.title) from \(when) on\(at). That one and every later one go; earlier ones stay."
                    + Self.invite(c) + " Say send to delete them, or cancel."
            case .all:
                return "Delete the whole repeating event \(c.before.title), every time it happens, starting \(when)\(at)."
                    + Self.invite(c) + " Say send to delete them, or cancel."
            }
        case .calendarCreate(let name):
            return "Create a new calendar called \(name). Say send to create it, or cancel."
        case .calendarRename(let c, let newName):
            return "Rename the calendar \(c.name) to \(newName). Its events stay. Say send to rename it, or cancel."
        case .calendarDelete(let c, let events):
            return "Delete the whole calendar \(c.name), \(Self.eventCount(events)). Say send to delete it, or cancel."
        }
    }

    /// "and its 12 events go with it" / "which is empty".
    static func eventCount(_ events: String) -> String {
        switch events {
        case "0": "which is empty"
        case "1": "and the 1 event on it"
        default: "and all \(events) events on it"
        }
    }

    /// The card's one-line statement of how much of a series goes.
    static func scopeLine(_ scope: SeriesScope) -> String {
        switch scope {
        case .one: "Delete only this one. The others stay."
        case .future: "Delete this one and every later one."
        case .all: "Delete the whole series, every time it happens."
        }
    }

    /// One line per changed field, for the card and the read-back.
    static func changes(from b: Event, to a: Event) -> [String] {
        var out: [String] = []
        if a.title != b.title { out.append("Rename it to \(a.title).") }
        if a.start != b.start || a.end != b.end || a.all_day != b.all_day { out.append("Move it to \(spoken(a)).") }
        if a.location != b.location {
            out.append(a.location.isEmpty ? "Clear the location." : "Set the location to \(a.location).")
        }
        if a.notes != b.notes { out.append(a.notes.isEmpty ? "Clear the notes." : "Set the notes to: \(sentence(a.notes))") }
        return out
    }

    private static func invite(_ c: EventChange) -> String {
        guard !c.organizer.isEmpty || c.attendees != "0" else { return "" }
        var s = " It's an invitation"
        if !c.organizer.isEmpty { s += " from \(c.organizer)" }
        if c.attendees != "0" { s += " with \(c.attendees) people" }
        return s + "; they may be notified."
    }

    private static func sentence(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = t.last, !".!?".contains(last) { t += "." }
        return t
    }

    /// "Friday, September 25, 2:00 PM to 3:00 PM", in the offset mailgate
    /// wrote (the event's zone), so it can't drift with the phone's zone.
    static func spoken(_ e: Event) -> String {
        if e.all_day == "1" {
            let first = day(e.start) ?? e.start
            if e.end == e.start { return "\(first), all day" }
            return "\(first) through \(day(e.end) ?? e.end), all day"
        }
        guard let (s, tz) = instant(e.start), let (en, _) = instant(e.end) else { return "\(e.start) to \(e.end)" }
        let dayF = formatter("EEEE, MMMM d", tz)
        let timeF = formatter("h:mm a", tz)
        let sameDay = dayF.string(from: s) == dayF.string(from: en)
        let end = sameDay ? timeF.string(from: en) : "\(dayF.string(from: en)), \(timeF.string(from: en))"
        return "\(dayF.string(from: s)), \(timeF.string(from: s)) to \(end)"
    }

    private static func formatter(_ pattern: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = pattern
        return f
    }

    private static func day(_ s: String) -> String? {
        let p = DateFormatter()
        p.locale = Locale(identifier: "en_US_POSIX")
        p.timeZone = TimeZone(secondsFromGMT: 0)
        p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: s) else { return nil }
        return formatter("EEEE, MMMM d", TimeZone(secondsFromGMT: 0)!).string(from: d)
    }

    private static func instant(_ s: String) -> (Date, TimeZone)? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: s), s.count >= 6 else { return nil }
        let off = String(s.suffix(6))
        let sign: Int = off.hasPrefix("-") ? -1 : 1
        let parts = off.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let tz = TimeZone(secondsFromGMT: sign * (parts[0] * 3600 + parts[1] * 60)) else { return nil }
        return (d, tz)
    }
}

extension Approval: Decodable {
    private enum Keys: String, CodingKey { case id, kind, hash, expiresAt, message }
    /// A series delete's two extra hashed fields, read from the same `message`.
    private struct SeriesPart: Decodable {
        let scope: SeriesScope
        let occurrence: String
    }
    private struct CreatePart: Decodable { let name: String }
    private struct RenamePart: Decodable { let new_name: String }
    private struct DeletePart: Decodable { let events: String }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        hash = try c.decode(String.self, forKey: .hash)
        expiresAt = try c.decode(Int64.self, forKey: .expiresAt)
        switch try c.decodeIfPresent(String.self, forKey: .kind) ?? "mail" {
        case "mail": payload = .mail(try c.decode(MailPending.Message.self, forKey: .message))
        case "imessage": payload = .text(try c.decode(Text.self, forKey: .message))
        case "calendar_update":
            let ch = try c.decode(EventChange.self, forKey: .message)
            guard let after = ch.after else {
                throw DecodingError.dataCorruptedError(forKey: .message, in: c, debugDescription: "update without after")
            }
            payload = .eventUpdate(ch, after: after)
        case "calendar_delete": payload = .eventDelete(try c.decode(EventChange.self, forKey: .message))
        case "calendar_delete_series":
            let s = try c.decode(SeriesPart.self, forKey: .message)
            payload = .seriesDelete(try c.decode(EventChange.self, forKey: .message), scope: s.scope, occurrence: s.occurrence)
        case "calendar_create_calendar":
            payload = .calendarCreate(name: try c.decode(CreatePart.self, forKey: .message).name)
        case "calendar_rename_calendar":
            payload = .calendarRename(
                try c.decode(CalendarRef.self, forKey: .message), newName: try c.decode(RenamePart.self, forKey: .message).new_name)
        case "calendar_delete_calendar":
            payload = .calendarDelete(
                try c.decode(CalendarRef.self, forKey: .message), events: try c.decode(DeletePart.self, forKey: .message).events)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \(other)")
        }
    }
}

/// `/api/mail/pending_all`. EACH ITEM DECODES ON ITS OWN: one kind this build
/// doesn't know (or one malformed item) is skipped, never the whole list,
/// which would silently hide every other approval.
struct ApprovalPage: Decodable, Sendable {
    let pending: [Approval]

    private struct Lossy: Decodable {
        let value: Approval?
        init(from decoder: Decoder) throws {
            do { value = try Approval(from: decoder) } catch {
                // Skipped, and SAID: hidden silently, an item this build cannot
                // read looks like nothing was ever proposed.
                Logger.mail.error("Mail: skipped a pending item this build can't decode: \(String(describing: error), privacy: .public)")
                value = nil
            }
        }
    }
    private enum Keys: String, CodingKey { case pending }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        pending = try c.decode([Lossy].self, forKey: .pending).compactMap(\.value)
    }
}
