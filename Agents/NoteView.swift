import Foundation

/// The Markdown half of rack-control's NoteView, without the view.
///
/// NAMED `NoteView` DELIBERATELY, even though nothing here is a View. It keeps
/// `ClaudeView`'s call site - `NoteView.markdown(bubble.text)` - identical to
/// the one in rack-control-ios, so that file stays a byte-for-byte copy and a
/// diff between the two repos stays meaningful. Renaming this to `Markdown`
/// would buy a better name and cost the only drift check the split has.
///
/// The View itself does not come across: it calls `HubClient.shared.note(_:)`,
/// which this app's narrowed client does not have, and navigates to `Route`,
/// which lives in FilesView.swift.
enum NoteView {
    enum Block { case text(String), link(String) }

    /// Split a note on [[wikilinks]]. Retained even though this app never
    /// renders a vault note, because it is the half of the pair that defines
    /// what `markdown` is given - and it is eight lines.
    static func blocks(of text: String) -> [Block] {
        var out: [Block] = []
        var rest = Substring(text)
        while let open = rest.range(of: "[["), let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) {
            let before = rest[rest.startIndex..<open.lowerBound]
            if !before.isEmpty { out.append(.text(String(before))) }
            var target = String(rest[open.upperBound..<close.lowerBound])
            // Obsidian allows [[note|alias]] and [[note#heading]]; the hub keys
            // notes on the bare name.
            if let bar = target.firstIndex(of: "|") { target = String(target[target.startIndex..<bar]) }
            if let hash = target.firstIndex(of: "#") { target = String(target[target.startIndex..<hash]) }
            out.append(.link(target.trimmingCharacters(in: .whitespaces)))
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { out.append(.text(String(rest))) }
        return out
    }

    /// Falls back to the raw string rather than showing nothing when a note
    /// contains Markdown this initialiser rejects.
    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
