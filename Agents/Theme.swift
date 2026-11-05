import SwiftUI

/// The app's own metrics, type roles and agent colours, on top of Deck Cream.
///
/// EVERY COLOUR IS A `Deck.*` TOKEN, used directly at the call site - there is
/// no second palette in this file to drift from the shared one. The previous
/// Theme was a port of the old web dashboard's glass palette; Deck Cream
/// replaced that on every Rack OS surface, and a local copy of retired hexes
/// is exactly how two apps stop looking like one product.
///
/// What stays here is what only this app decides: spacing steps, which Deck
/// face a chat line is set in, and which Deck fill stands for which agent box.
enum Theme {

    // MARK: - spacing

    /// Named rather than inlined so a gap and a padding that are meant to
    /// match cannot drift by a point.
    static let sp1: CGFloat = 4
    static let sp2: CGFloat = 8
    static let sp3: CGFloat = 12
    static let sp4: CGFloat = 16

    /// The width of the agent-colour edge down the leading side of an agent's
    /// message. Narrower than the 5px accent bar Deck uses for a SELECTED
    /// row, so the two never read as the same signal.
    static let agentEdge: CGFloat = 4

    // MARK: - type
    //
    // Deck faces only, each relative to a text style so Dynamic Type scales
    // them. Space Grotesk is what people wrote; IBM Plex Mono is what machines
    // wrote - code, tool calls, tool output, node names, times.

    /// A message body, yours or an agent's.
    static let message = Deck.body
    /// A fenced code block, and a tool's output.
    static let code = Deck.mono(13, .regular, relativeTo: .callout)
    /// `inline code` inside a message. A point under `message`, because Plex
    /// Mono sets wider than Space Grotesk at the same size.
    static let inlineCode = Deck.mono(14, .regular, relativeTo: .body)
    /// A tool call's one-line header.
    static let toolLine = Deck.mono(12, .medium, relativeTo: .footnote)
    /// A conversation title in the history drawer.
    static let rowTitle = Deck.sans(15, .bold, relativeTo: .body)
    /// The machine / source / time line under it.
    static let meta = Deck.mono(11.5, .medium, relativeTo: .caption)

    /// What the scrim behind the open drawer is tinted with. `onFill`, not
    /// `ink`: ink flips to cream in dark mode, and a cream scrim would LIGHTEN
    /// the chat it is meant to push back. `onFill` is the one near-black that
    /// stays near-black in both modes. The strength is DrawerState's call.
    static let scrim = Deck.onFill

    // MARK: - agents

    /// ONE DECK FILL PER AGENT BOX, so which machine is answering can be seen
    /// before it is read - and ALWAYS BESIDE THE MACHINE'S NAME, never alone:
    /// three hues are three chances for a colour-blind reader to lose the
    /// signal, and the name is what carries it for them (WCAG 1.4.1).
    ///
    /// Atlas keeps orange because Claude was orange before; Hermes keeps blue
    /// for the same reason. Calypso takes green, the one fill left that is
    /// not already a warning. A box outside the table gets `muted`, which is
    /// deliberately no identity at all rather than a borrowed one.
    ///
    /// Keyed on the hub's NODE, not the agent kind: two Hermes boxes are two
    /// machines and must not share a colour.
    static func agentColour(node: String) -> Color {
        switch node {
        case "atlas": Deck.accent
        case "hermes": Deck.blue
        case "calypso": Deck.ok
        default: Deck.muted
        }
    }
}

extension Agent {
    /// The hub node this agent runs on. The same answer `AgentChoice.node`
    /// gives, for the same reason: `.claude` carries no node because atlas is
    /// the only box running it.
    var deckNode: String {
        switch self {
        case .claude: "atlas"
        case .hermes(let n): n
        }
    }

    /// The machine name as a person reads it - "Atlas", "Hermes", "Calypso",
    /// which is what `AgentChoice.all` shows in the picker.
    var deckName: String { deckNode.capitalized }

    var deckColour: Color { Theme.agentColour(node: deckNode) }
}

/// The small square that stands for an agent box: its Deck fill inside a hard
/// ink edge, so it holds its shape on a surface that is nearly its own colour.
/// Decorative - every place it appears also prints the machine's name.
struct AgentSwatch: View {
    let colour: Color
    var side: CGFloat = 10

    var body: some View {
        Rectangle()
            .fill(colour)
            .frame(width: side, height: side)
            .overlay(Rectangle().strokeBorder(Deck.line, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

/// Swatch plus machine name - the label over an agent's message.
struct AgentTag: View {
    let agent: Agent

    var body: some View {
        HStack(spacing: 6) {
            AgentSwatch(colour: agent.deckColour, side: 9)
            Text(agent.deckName)
                .font(Deck.label)
                .textCase(.uppercase)
                .tracking(0.66)
                .foregroundStyle(Deck.ink)
        }
        .accessibilityElement(children: .combine)
    }
}
