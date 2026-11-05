import SwiftUI

// App-local Deck pieces the shared DeckCream/DeckExtras copies do not have.
// Written against Deck.* tokens only. Candidates for rack-os-design/ios if a
// second app needs them: DeckDisclosureStyle and DeckCodeBlock.

// MARK: - Message text: prose and fenced code

/// Splits an agent's message into prose and fenced code blocks, so the code
/// can be set in Plex Mono on the rail instead of arriving as literal
/// backticks inside a paragraph.
///
/// A PURE FUNCTION OF THE TEXT, re-run on every body evaluation, which is what
/// keeps it right while an answer streams in: an opening fence with no closing
/// one yet is a code block that is still being written, and it renders as one
/// immediately rather than flashing as prose until the fence closes.
enum ChatText {
    enum Segment: Equatable {
        case prose(String)
        /// `language` is whatever followed the opening fence, possibly "".
        case code(language: String, body: String)
    }

    static func segments(_ text: String) -> [Segment] {
        // THE COMMON CASE IS UNTOUCHED. A message with no fence comes back as
        // the exact string it went in as - no trimming, no re-joining - so
        // every answer without code renders byte-for-byte as it did before.
        guard text.contains("```") else { return [.prose(text)] }

        var out: [Segment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var language: String?  // non-nil while inside a fence

        func flushProse() {
            // Only the blank lines hugging a fence go - the box's own padding
            // is the gap now, and a paragraph break on top of it is a hole.
            let s = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !s.isEmpty { out.append(.prose(s)) }
            prose = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lang = language {
                    out.append(.code(language: lang, body: code.joined(separator: "\n")))
                    code = []
                    language = nil
                } else {
                    flushProse()
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else if language != nil {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if let lang = language {
            // Still streaming, or the agent never closed it.
            out.append(.code(language: lang, body: code.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return out
    }

    /// A prose segment as styled text: `NoteView.markdown`'s inline Markdown,
    /// with `inline code` runs moved onto Plex Mono on the rail.
    ///
    /// NOT DONE INSIDE NoteView, which stays a byte-for-byte copy of
    /// rack-control-ios's - see the comment on that type.
    ///
    /// THE `.code` INTENT IS REMOVED, not merely overridden. Left in place,
    /// SwiftUI answers it by asking the run's font for its monospaced variant,
    /// and a custom face has none - so the run falls back to SF Mono and the
    /// Plex font set here is silently discarded.
    static func prose(_ s: String) -> AttributedString {
        var a = NoteView.markdown(s)
        let codeRuns = a.runs
            .filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map(\.range)
        for r in codeRuns {
            a[r].inlinePresentationIntent?.remove(.code)
            a[r].font = Theme.inlineCode
            a[r].backgroundColor = Deck.rail
        }
        return a
    }
}

// MARK: - Code block

/// A fenced code block: Plex Mono on the rail inside a 2px ink edge, with the
/// fence's language, when there was one, as a mono label on a ruled head.
///
/// SUNK, NOT RAISED - no hard shadow. It is part of the message it sits in,
/// not a control, and a shadow would make it read as something to press.
///
/// WRAPS rather than scrolling sideways. A horizontal ScrollView inside the
/// transcript is a second horizontal-drag surface next to the drawer's edge
/// gesture, and a code line hidden past the edge is one nobody scrolls to.
struct DeckCodeBlock: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .deckLabel()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Deck.line).frame(height: Deck.borderWidth)
                    .accessibilityHidden(true)
            }
            Text(code)
                .font(Theme.code)
                .foregroundStyle(Deck.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Deck.rail)
        .overlay(Rectangle().strokeBorder(Deck.line, lineWidth: Deck.borderWidth))
    }
}

// MARK: - Disclosure (a tool call)

/// A `DisclosureGroup` as a Deck strip: rail fill, 2px ink edge, a 44pt header
/// row, and the content under a ruled line when open.
///
/// A STYLE, NOT A HAND-ROLLED BUTTON AND `if`. The call site keeps a real
/// `DisclosureGroup(isExpanded:)`, so its state and its meaning are exactly
/// what they were; this only draws it. The header is a Button, and VoiceOver
/// is told the state in words, because the chevron's rotation is the only
/// visual cue and it says nothing to a reader who cannot see it.
struct DeckDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    configuration.label
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Deck.ink)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(configuration.isExpanded ? "Hides the output" : "Shows the output")

            if configuration.isExpanded {
                Rectangle().fill(Deck.line).frame(height: Deck.borderWidth)
                    .accessibilityHidden(true)
                configuration.content
                    .padding(10)
            }
        }
        .background(Deck.rail)
        .overlay(Rectangle().strokeBorder(Deck.line, lineWidth: Deck.borderWidth))
    }
}
