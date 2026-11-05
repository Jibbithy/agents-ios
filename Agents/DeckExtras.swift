import SwiftUI

// Rack OS · Deck Cream — SwiftUI extras: the rest of the dk- components
// (icon button, bars, table rows, check, meter, alert, error/hint, form
// section, sheet). Written against DeckCream.swift tokens only; each piece
// names the web/deck.css component it mirrors. Source of truth:
// rack-os-design/ios/DeckExtras.swift — apps take a COPY.

// MARK: - Icon button (dk-btn--icon)

/// A square, icon-only Deck button: the `.deck` button's border, fill and
/// press-into-the-shadow, at a fixed side so it is a 44pt tap target however
/// small the glyph is.
struct DeckIconButtonStyle: ButtonStyle {
    enum Kind { case plain, primary, ink, ghost }
    var kind: Kind
    var side: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    init(_ kind: Kind = .plain, side: CGFloat = 44) {
        self.kind = kind
        self.side = side
    }

    func makeBody(configuration: Configuration) -> some View {
        let sh: CGFloat = kind == .ghost || !isEnabled ? 0 : Deck.shadowSmall
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .font(.system(size: side * 0.36, weight: .semibold))
            .foregroundStyle(isEnabled ? fg : Deck.muted)
            .frame(width: side, height: side)
            .background(isEnabled ? bg : Deck.rail)
            .overlay(border)
            .background(
                Rectangle().fill(Deck.shadow)
                    .offset(x: pressed ? 0 : sh, y: pressed ? 0 : sh)
                    .opacity(sh == 0 ? 0 : 1)
            )
            .offset(x: pressed ? sh : 0, y: pressed ? sh : 0)
            .padding(.trailing, sh).padding(.bottom, sh)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.09), value: pressed)
    }

    @ViewBuilder private var border: some View {
        if !isEnabled {
            Rectangle().strokeBorder(
                Deck.muted,
                style: StrokeStyle(lineWidth: Deck.borderWidth, dash: [5, 4]))
        } else if kind != .ghost {
            Rectangle().strokeBorder(Deck.line, lineWidth: Deck.borderWidth)
        }
    }

    private var bg: Color {
        switch kind {
        case .plain: Deck.surface
        case .primary: Deck.accent
        case .ink: Deck.ink
        case .ghost: .clear
        }
    }

    private var fg: Color {
        switch kind {
        case .plain, .ghost: Deck.ink
        case .primary: Deck.onFill
        case .ink: Deck.inkInverse
        }
    }
}

// MARK: - Bars (dk-side on a phone: the rail strip with a 3px edge)

extension View {
    /// A rail-coloured bar with the 3px structural edge on the side that
    /// faces the page. `.top` is a header (edge below it, rail running up
    /// under the status bar); `.bottom` is a footer (edge above it, rail
    /// running down under the home indicator).
    func deckBar(_ edge: VerticalEdge) -> some View {
        background(Deck.rail.ignoresSafeArea(edges: edge == .top ? .top : .bottom))
            .overlay(alignment: edge == .top ? .bottom : .top) {
                Rectangle().fill(Deck.line).frame(height: Deck.borderWidthLarge)
            }
    }
}

// MARK: - Table (dk-table: rail head, surface rows, hair between rows)

/// A 2px structural rule (dk-rule) - the top and bottom edge of a table.
struct DeckRule: View {
    var body: some View {
        Rectangle().fill(Deck.line).frame(height: Deck.borderWidth)
            .accessibilityHidden(true)
    }
}

/// A table head strip: mono label on the rail, ruled above and below.
struct DeckTableHead: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .deckLabel()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Deck.rail)
            .overlay(alignment: .top) { DeckRule() }
            .overlay(alignment: .bottom) { DeckRule() }
            .accessibilityAddTraits(.isHeader)
    }
}

/// One table row.
///
/// Surface fill, a 2px hair above every row but the first, and the selected
/// treatment from the specimen: rail fill plus a 5px accent bar on the
/// leading edge. The bar is the shape cue - selection never rides on the fill
/// colour alone.
struct DeckRow: ViewModifier {
    var isSelected: Bool
    var separator: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(isSelected ? Deck.rail : Deck.surface)
            .overlay(alignment: .leading) {
                if isSelected { Rectangle().fill(Deck.accent).frame(width: 5) }
            }
            .overlay(alignment: .top) {
                if separator { Rectangle().fill(Deck.hair).frame(height: Deck.borderWidth) }
            }
    }
}

extension View {
    func deckRow(selected: Bool = false, separator: Bool = true) -> some View {
        modifier(DeckRow(isSelected: selected, separator: separator))
    }
}

// MARK: - Checkbox (dk-check)

/// A square checkbox. Checked is the inverted ink fill with an accent square
/// in it; unavailable is a dashed edge - both readable without colour.
struct DeckCheck: View {
    enum Mark { case off, on, unavailable }
    var state: Mark
    var side: CGFloat = 20

    var body: some View {
        ZStack {
            switch state {
            case .off:
                Rectangle().fill(Deck.surface)
                Rectangle().strokeBorder(Deck.line, lineWidth: Deck.borderWidth)
            case .on:
                Rectangle().fill(Deck.ink)
                Rectangle().fill(Deck.accent).frame(width: side * 0.44, height: side * 0.44)
            case .unavailable:
                Rectangle().strokeBorder(
                    Deck.muted,
                    style: StrokeStyle(lineWidth: Deck.borderWidth, dash: [3, 3]))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

// MARK: - Meter (dk-meter)

/// A bordered progress bar: surface track, solid fill with a hard ink edge
/// where it stops.
struct DeckMeter: View {
    var fraction: Double
    var fill: Color = Deck.accent
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let inner = max(0, geo.size.width - Deck.borderWidth * 2)
            let w = inner * CGFloat(min(1, max(0, fraction)))
            ZStack(alignment: .leading) {
                Rectangle().fill(Deck.surface)
                Rectangle().fill(fill)
                    .frame(width: w)
                    .overlay(alignment: .trailing) {
                        if w > 0 && w < inner {
                            Rectangle().fill(Deck.line).frame(width: Deck.borderWidth)
                        }
                    }
                    .padding(Deck.borderWidth)
            }
            .overlay(Rectangle().strokeBorder(Deck.line, lineWidth: Deck.borderWidth))
        }
        .frame(height: height)
    }
}

// MARK: - Alert (dk-alert)

/// A message box: surface, ink border, hard shadow, and a 10px edge in the
/// status fill. The status is also carried by the dot's SHAPE (● ◆ ■ ○), so
/// the edge colour is never the only signal.
struct DeckAlert<Action: View>: View {
    var status: DeckStatus
    var title: String?
    var message: String
    var action: Action

    init(
        _ status: DeckStatus, title: String? = nil, message: String,
        @ViewBuilder action: () -> Action = { EmptyView() }
    ) {
        self.status = status
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            DeckDot(status, size: 9)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title)
                        .font(Deck.sans(17, .bold, relativeTo: .headline))
                        .foregroundStyle(Deck.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(message)
                    .font(Deck.body)
                    .foregroundStyle(Deck.ink)
                    .fixedSize(horizontal: false, vertical: true)
                action
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10 + 12)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Deck.surface)
        .overlay(Rectangle().strokeBorder(Deck.line, lineWidth: Deck.borderWidth))
        .overlay(alignment: .leading) { Rectangle().fill(edge).frame(width: 10) }
        .background(Rectangle().fill(Deck.shadow).offset(x: Deck.shadowMedium, y: Deck.shadowMedium))
        .padding(.trailing, Deck.shadowMedium).padding(.bottom, Deck.shadowMedium)
    }

    private var edge: Color {
        switch status {
        case .ok: Deck.ok
        case .warn: Deck.warn
        case .crit: Deck.crit
        case .idle: Deck.blue
        }
    }
}

// MARK: - Inline messages (dk-error, dk-hint)

/// An error line: crit-ink text behind a ■, so it reads as an error in
/// greyscale too.
struct DeckErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            DeckDot(.crit, size: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            Text(text)
                .font(Deck.sans(12.5, .bold, relativeTo: .footnote))
                .foregroundStyle(Deck.critInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A hint or status line: small, muted, no marker.
struct DeckHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Deck.small)
            .foregroundStyle(Deck.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Form section (dk-section + dk-tile)

/// A labelled group of form rows: a mono label over a bordered tile, with a
/// hair between each child. The separators are inserted here, so a row does
/// not have to know whether it is first.
struct DeckFormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .deckLabel()
                .padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Rectangle().fill(Deck.hair).frame(height: Deck.borderWidth)
                        }
                        row
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .deckTile()
        }
    }
}

/// A table edge inside a `List`: the 2px rule as a row of its own, with the
/// list's insets, background and separator all taken off - so a `List` (kept
/// for its swipe actions) closes like every other Deck table.
struct DeckTableEdgeRow: View {
    var body: some View {
        DeckRule()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

// MARK: - Sheets (dk-dialog)

extension View {
    /// Presentation chrome for a sheet: the ground behind it, square corners
    /// instead of the system's rounded card, and the accent-ink tint - which
    /// a sheet does not reliably inherit from the view that raised it.
    func deckSheet() -> some View {
        presentationBackground(Deck.ground)
            .presentationCornerRadius(0)
            .tint(Deck.accentInk)
    }
}
