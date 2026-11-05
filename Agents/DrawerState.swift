import CoreGraphics

/// Whether the history drawer is open, how far a finger has dragged it, and
/// the two numbers that follow from those.
///
/// A VALUE TYPE WITH NO SwiftUI IN IT, deliberately. Every interesting rule
/// here - the clamp, the zero-width guard, and above all "a closed drawer must
/// not take touches" - is arithmetic, and arithmetic that lives in a `View` can
/// only be checked by launching a simulator and looking at it.
struct DrawerState: Equatable, Sendable {
    private(set) var isOpen = false

    /// The live finger translation while a drag is in progress, reset to 0 the
    /// moment the drag ends and `isOpen` takes over.
    ///
    /// SEALED LIKE `isOpen`, and more urgently than it. A stale `drag` is the
    /// value that re-creates the tap-eating bug: left over after a gesture it
    /// parks a strip of panel over the chat and holds `isInteractive` true on a
    /// drawer that is shut. Writable only through `track(_:)` and clearable
    /// only by `open()`/`close()`, that invariant is structural rather than
    /// something every future caller has to remember.
    private(set) var drag: CGFloat = 0

    /// The scrim's darkness once the panel is all the way in. The only purely
    /// visual number in the file.
    private static let maxScrimOpacity: Double = 0.35

    /// Feeds the live gesture translation in, mid-drag.
    ///
    /// An intent-named door rather than a settable property, because the
    /// counterpart matters just as much: the gesture MUST end in `open()` or
    /// `close()`, whose reset of `drag` is the whole point. A direct write
    /// could set the value without anything ever clearing it.
    mutating func track(_ translation: CGFloat) { drag = translation }

    mutating func open() {
        isOpen = true
        drag = 0
    }
    mutating func close() {
        isOpen = false
        drag = 0
    }
    mutating func toggle() { isOpen ? close() : open() }

    /// The panel's x-offset. Closed is fully off-screen to the left.
    ///
    /// CLAMPED AT BOTH ENDS. A fling past flush would otherwise slide the panel
    /// off the right-hand side of the screen, and a fling the other way would
    /// leave a gap of wallpaper where the chat should be.
    func offset(width: CGFloat) -> CGFloat {
        let base = isOpen ? 0 : -width
        return min(0, max(-width, base + drag))
    }

    /// How dark the scrim over the chat is, tracking the panel rather than
    /// snapping - so a half-finished drag looks half-open.
    func scrimOpacity(width: CGFloat) -> Double {
        // A zero width happens for one frame during layout. Dividing by it
        // gives NaN, and SwiftUI renders a NaN opacity as a black screen.
        guard width > 0 else { return 0 }
        let travelled = 1 + offset(width: width) / width  // 0 closed, 1 open
        return Double(travelled) * Self.maxScrimOpacity
    }

    /// Whether the drawer layer should receive touches at all.
    ///
    /// THE WHOLE REASON THIS IS A COMPUTED PROPERTY AND NOT `isOpen`. A closed
    /// drawer still occupies its place in the `ZStack`; if its scrim takes hit
    /// testing it silently swallows every tap meant for the chat underneath -
    /// the composer simply stops responding, with nothing on screen to say why.
    /// A drag in progress must still receive the finger, hence the second term.
    var isInteractive: Bool { isOpen || drag != 0 }
}
