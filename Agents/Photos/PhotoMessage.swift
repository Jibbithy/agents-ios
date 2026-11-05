import Foundation

/// The text of a turn that carries photos - THE CONTRACT between the phone,
/// Claude on atlas, and history replay. The hub stores the turn's text as-is,
/// so a bubble reopened next week is rebuilt from exactly this string: compose
/// and parse must stay inverses, and both live here so they cannot drift.
enum PhotoMessage {
    /// Where the phone uploads. Flat on purpose - Claude files photos out of
    /// it, the phone never sorts. The hub does not create directories.
    static let inbox = "/data/photos/inbox"

    static let marker = "[photo] "

    /// Tells Claude the house rules without any hub change. One line, last,
    /// so parse can drop it by equality.
    static let instruction =
        "[photos are in the inbox; read them. To log to Obsidian, copy into vault Attachments/ and embed with ![[name]] in the note I name, else append to \"Photo Log/<yyyy-MM-dd>.md\" with a one-line caption. To file them, move them under /data/photos/<folder>/. Never delete a photo.]"

    static func compose(text: String, paths: [String]) -> String {
        guard !paths.isEmpty else { return text }
        let lines = paths.map { marker + $0 }
        return ([text, ""] + lines + [instruction]).joined(separator: "\n")
    }

    /// Splits a sent turn back into what the user typed and the photo paths.
    /// Only the exact block compose emits counts - "" separator, marker
    /// lines, then the instruction as the LAST line. Anything else (a user who
    /// just typed "[photo] ..." at the end) is returned untouched.
    static func parse(_ message: String) -> (text: String, paths: [String]) {
        var lines = message.components(separatedBy: "\n")
        guard lines.last == instruction else { return (message, []) }
        lines.removeLast()
        var paths: [String] = []
        while let last = lines.last, last.hasPrefix(marker) {
            paths.insert(String(last.dropFirst(marker.count)), at: 0)
            lines.removeLast()
        }
        guard !paths.isEmpty, lines.last == "" else { return (message, []) }
        lines.removeLast()
        return (lines.joined(separator: "\n"), paths)
    }

    static func fileName(at date: Date, index: Int, suffix: String = "", timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return "\(f.string(from: date))_\(index)\(suffix).jpg"
    }

    static func defaultText(count: Int) -> String {
        count == 1 ? "What's in this photo?" : "What's in these photos?"
    }
}
