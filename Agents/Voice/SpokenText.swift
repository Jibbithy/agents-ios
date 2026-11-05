import Foundation

/// What of a reply gets read aloud.
///
/// A Claude Code answer is written for a SCREEN: fenced code, tables, links.
/// Read out verbatim that is noise - "pipe, dash, dash, pipe" - so this keeps
/// the prose, drops what only works on a screen, and caps the length at about
/// 45 seconds. Whatever it leaves out is still in the chat, and the spoken
/// text says so rather than stopping mid-thought as if that were everything.
enum SpokenText {
    /// About 45 seconds at the synthesiser's default rate.
    static let wordCap = 110
    static let restIsInTheChat = "The rest is in the chat."
    static let allInTheChat = "The answer is in the chat."

    static func from(_ markdown: String) -> String {
        var dropped = false

        // Caps the WORK, not just the eventual output. Everything below is
        // linear in the text - the code spans are pulled out and put back in
        // one pass each - but a pass over a huge reply is still wasted: only
        // the first ~110 words are ever spoken, so nothing past roughly a
        // page of characters could survive the word cap regardless.
        let tooLong = markdown.count > 20_000
        let boundedMarkdown = tooLong ? String(markdown.prefix(20_000)) : markdown
        if tooLong { dropped = true }

        var fenceChar: Character?
        var fenceLen = 0
        var kept: [String] = []

        // A blank line closes the paragraph before it - a kept line left
        // without a stop ("**Summary**") gets one now, rather than running
        // straight into the next paragraph's first word. The same close also
        // runs right before a new list item or heading, and on any fence,
        // table or divider line: each of those starts a new block whether or
        // not a blank line happened to separate it from what came before.
        func closeParagraph() {
            guard let last = kept.last, !last.isEmpty else { return }
            kept[kept.count - 1] = ensureSentenceEnd(last)
        }

        for raw in boundedMarkdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if let openChar = fenceChar {
                // INSIDE A FENCE, only a marker of the SAME character, at
                // least as long as the one that opened it, closes it - a
                // shorter or different marker (a ```swift fence nested inside
                // a ````markdown one) is fence CONTENT, not a close. A fence
                // that never closes drops everything after it for the rest of
                // the reply, on purpose: that is a reply cut off mid-code, and
                // there is nothing safe left to read.
                if let (ch, len) = fenceMarker(line), ch == openChar, len >= fenceLen {
                    fenceChar = nil
                }
                continue
            }
            if line.isEmpty {
                closeParagraph()
                continue
            }
            if let (ch, len) = fenceMarker(line) {
                closeParagraph()
                fenceChar = ch
                fenceLen = len
                dropped = true
                continue
            }
            if line.hasPrefix("|") {
                closeParagraph()
                dropped = true
                continue
            }
            // A divider has nothing to read - not a list marker (which needs
            // a space after its marker) or bold text (never ALL asterisks).
            if isHorizontalRule(line) {
                closeParagraph()
                continue
            }

            let (rawBody, isItem) = unmarked(line)
            var body = rawBody
            // "- [ ] Ship it" / "- [x] Done": the box is a checkbox, not
            // words - it says nothing that "Ship it" doesn't already.
            if isItem, let r = body.range(of: #"^\[[ xX]\]\s+"#, options: .regularExpression) {
                body.removeSubrange(r)
            }
            // A LIST ITEM OR HEADING starts a new block, so it closes off
            // whatever prose came before it even with no blank line between
            // them, and ends in a full stop itself so the voice pauses
            // between items instead of running "disk memory" together. Plain
            // prose lines are left alone otherwise: a sentence that happens
            // to wrap would otherwise gain a stop in its middle.
            if isItem { closeParagraph() }
            kept.append(isItem ? ensureSentenceEnd(body) : body)
        }

        var text = kept.joined(separator: " ")

        // Code spans come out before anything else touches the text, so a
        // '*' inside `*.orig` or a link-shaped string inside `code` is never
        // mistaken for markup or a URL. They go back in, verbatim, at the end.
        let (withoutCode, codeSpans) = extractCodeSpans(text)
        text = withoutCode

        // ![alt](url) -> nothing. Unlike a link there is no visible text
        // underneath to fall back to, so the whole picture - "!" included -
        // just isn't there.
        if text.range(of: #"!\[[^\]]*\]\([^)]*\)"#, options: .regularExpression) != nil {
            dropped = true
            text = text.replacingOccurrences(
                of: #"!\[[^\]]*\]\([^)]*\)"#, with: "",
                options: .regularExpression)
        }
        // [text](url) -> text. The words are the point; a URL read aloud is not.
        text = text.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1",
            options: .regularExpression)
        // A bare or <angle> URL has no words in it worth keeping at all. The
        // match stops short of trailing punctuation - '.', ')', etc - so a
        // URL at the end of a sentence or inside parentheses doesn't take
        // that punctuation down with it and merge two sentences together.
        let bareURLPattern = #"<?https?://[^\s<>]*[^\s<>.,;:!?)\]'"]>?"#
        if let re = try? NSRegularExpression(pattern: bareURLPattern) {
            let ns = text as NSString
            let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                dropped = true
                // THE BUG this walk fixes: a URL right before the sentence's
                // own full stop leaves that space stranded once it's gone -
                // "at ." instead of "at." A REGEX-ONLY fix - a lookahead for
                // the punctuation after a greedy `[^\s<>]*` - backtracks INTO
                // the URL looking for one and happily matches a '.' inside
                // the host name instead, truncating "github.com/x/y" down to
                // "github" and mangling unrelated text ("the .env file")
                // anywhere else in the reply, since a later global cleanup
                // pass couldn't tell that "." from any other. Walking the
                // matches instead means the leading space is only ever
                // dropped at the ONE site it came from.
                let sentenceEnders = Set(".,!?;:".utf16)
                var result = ""
                var cursor = 0
                for match in matches {
                    var start = match.range.location
                    let after = match.range.location + match.range.length
                    let nextIsSentenceEnd = after >= ns.length || sentenceEnders.contains(ns.character(at: after))
                    // A URL inside "(see URL)" or quotes keeps its leading
                    // space - nothing else closes that gap - so this only
                    // fires right before the sentence's own end.
                    if nextIsSentenceEnd, start > cursor, ns.character(at: start - 1) == 0x20 {
                        start -= 1
                    }
                    result += ns.substring(with: NSRange(location: cursor, length: start - cursor))
                    cursor = after
                }
                result += ns.substring(from: cursor)
                text = result
                // A quote or parenthesis pair left EMPTY once the URL inside
                // it is gone reads as a stray mark with nothing between it -
                // 'Open "" now.' - so the pair goes with it.
                text = text.replacingOccurrences(of: "()", with: "")
                text = text.replacingOccurrences(of: "\"\"", with: "")
                text = text.replacingOccurrences(of: "''", with: "")
            }
        }

        // Paired emphasis only, so a lone asterisk in "2*3=6" is arithmetic,
        // not markup left half-stripped. Bold before italic: on "**text**",
        // italic's single-asterisk pattern would otherwise match the inner
        // "*text*" and leave the outer pair behind unstripped. The italic
        // pair also needs a non-word, non-asterisk character (or the very
        // start/end of the text) on BOTH outer sides, and no space just
        // inside either mark - otherwise "2*3*4" and "*.tmp ... *.log" read
        // as emphasis wrapped around arithmetic or a shell glob.
        text = text.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?<![\w*])\*([^*\s](?:[^*]*[^*\s])?)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"~~(.+?)~~"#, with: "$1", options: .regularExpression)

        // A stray, unpaired backtick (an odd count on the line) gets left
        // dangling by extractCodeSpans above, which greedily pairs it with
        // whatever REAL backtick comes next rather than recognising it as
        // unmatched. Drop it here rather than let it stick to the next word.
        text = text.replacingOccurrences(of: "`", with: "")

        text = restoreCodeSpans(text, codeSpans)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let words = text.split(separator: " ")
        guard !words.isEmpty else { return allInTheChat }
        if words.count <= wordCap {
            return dropped ? ensureSentenceEnd(text) + " " + restIsInTheChat : text
        }

        // Cut at the last WORD that ends a sentence inside the cap - not the
        // last '.', '!' or '?' CHARACTER, which lands mid-decimal ("91.5") or
        // mid-number ("3.14.159"). With no such word, at the cap.
        let capped = Array(words.prefix(wordCap))
        if let cutIndex = capped.lastIndex(where: endsASentence) {
            return capped[...cutIndex].joined(separator: " ") + " " + restIsInTheChat
        }
        return capped.joined(separator: " ") + "…" + " " + restIsInTheChat
    }

    /// A line with its heading, bullet, number or quote marker taken off, and
    /// whether it had one.
    private static func unmarked(_ line: String) -> (String, Bool) {
        guard let r = line.range(of: #"^(#{1,6}|[-*+]|\d+[.)]|>)\s+"#, options: .regularExpression) else {
            return (line, false)
        }
        return (String(line[r.upperBound...]), true)
    }

    /// Adds a full stop unless the line already ends in one - checked after
    /// peeling off trailing emphasis marks, so "**Disk is fine.**" is not
    /// seen as ending in "*" and given a second stop on top of its own.
    private static func ensureSentenceEnd(_ line: String) -> String {
        var check = line
        while let last = check.last, "*_~`".contains(last) { check.removeLast() }
        guard let last = check.last, "!?.:".contains(last) else { return line + "." }
        return line
    }

    /// Whether this WORD ends a sentence: its final character, after peeling
    /// off a trailing closing quote or paren, is '.', '!' or '?'. Checking
    /// the whole word rather than scanning characters is what keeps a stray
    /// '.' inside "91.5" or "3.14.159" from being read as a sentence end.
    /// `SpeechChunks` cuts Kokoro's requests by the same rule.
    static func endsASentence(_ word: Substring) -> Bool {
        var w = word
        while let last = w.last, "\"')\u{201D}\u{2019}".contains(last) { w.removeLast() }
        guard let last = w.last else { return false }
        return ".!?".contains(last)
    }

    /// The character and run length of a fence marker (backtick or tilde,
    /// three or more) at the very start of this line, if it has one.
    private static func fenceMarker(_ line: String) -> (Character, Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        var count = 0
        for c in line {
            if c == first { count += 1 } else { break }
        }
        return count >= 3 ? (first, count) : nil
    }

    /// Three or more of '-', '*' or '_' and nothing else - a divider, not a
    /// list marker or bold text.
    private static func isHorizontalRule(_ line: String) -> Bool {
        guard line.count >= 3, let first = line.first, "-*_".contains(first) else { return false }
        return line.allSatisfy { $0 == first }
    }

    /// Pulls `code` spans out to private-use placeholders and returns their
    /// text (without the backticks) in match order, so emphasis stripping
    /// never sees what is inside one.
    private static func extractCodeSpans(_ text: String) -> (String, [String]) {
        guard let re = try? NSRegularExpression(pattern: "`([^`]+)`") else { return (text, []) }
        let ns = text as NSString
        var spans: [String] = []
        var result = ""
        var cursor = 0
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "\u{E000}\(spans.count)\u{E000}"
            spans.append(ns.substring(with: match.range(at: 1)))
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return (result, spans)
    }

    /// Puts code spans pulled out by `extractCodeSpans` back in, verbatim.
    ///
    /// ONE PASS over the text, like `extractCodeSpans` itself - a reply with
    /// thousands of spans used to rescan the WHOLE text once per span here
    /// (`replacingOccurrences` in a loop), which is quadratic. Matching every
    /// placeholder in a single regex scan and looking each one up keeps this
    /// linear in the text's length regardless of how many spans there are.
    private static func restoreCodeSpans(_ text: String, _ spans: [String]) -> String {
        guard !spans.isEmpty else { return text }
        guard let re = try? NSRegularExpression(pattern: "\u{E000}(\\d+)\u{E000}") else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if let index = Int(ns.substring(with: match.range(at: 1))), spans.indices.contains(index) {
                result += spans[index]
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
