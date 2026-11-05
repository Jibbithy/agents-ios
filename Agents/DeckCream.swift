// Rack OS · Deck Cream for SwiftUI.
//
// Source of truth: rack-os-design/ios/DeckCream.swift.
// It mirrors web/deck.css token for token — change a value there, change it
// here, and re-run `node check.mjs` (the contrast numbers are shared).
// Apps take a COPY of this file plus ios/Fonts/*.ttf; edit here, re-copy.
//
// Fonts are registered at runtime (Deck.registerFonts() once at launch), so
// an app needs no Info.plist UIAppFonts entry — only the .ttf files in its
// bundle resources.

import CoreText
import SwiftUI
import UIKit

public enum Deck {

    // MARK: - Colour tokens (one light/dark pair each, like light-dark())

    public static let ground = pair(0xf3ead3, 0x1a1714)  // page
    public static let rail = pair(0xeadfc2, 0x221e1a)  // bars, table heads, sunk strips
    public static let surface = pair(0xfffdf6, 0x28231e)  // cards, fields, idle controls
    public static let ink = pair(0x141210, 0xf3ead3)  // text + the inverted fill
    public static let inkInverse = pair(0xf3ead3, 0x141210)  // text ON `ink`
    public static let muted = pair(0x5e5749, 0xb5aa92)  // secondary text, >=4.5 on every ground
    public static let hair = pair(0xe2d6ba, 0x3a332b)  // row separators, decorative only
    public static let line = pair(0x141210, 0xe9dfc6)  // every structural border
    public static let shadow = pair(0x141210, 0xe9dfc6)  // the hard offset shadow = border colour

    /// Fills are the same in both modes; text on them is ALWAYS `onFill`.
    public static let onFill = hex(0x141210)
    public static let accent = hex(0xff5c39)
    public static let ok = hex(0x20b552)
    public static let warn = hex(0xffb020)
    public static let crit = hex(0xef4a3c)
    public static let blue = hex(0x3d7fff)

    /// The same hues tuned to pass 4.5:1 AS TEXT on ground, rail and surface.
    public static let accentInk = pair(0xa33210, 0xff7a5c)
    public static let okInk = pair(0x126c33, 0x4fd27e)
    public static let warnInk = pair(0x7d5200, 0xffc05a)
    public static let critInk = pair(0xb8231c, 0xff7b6e)
    public static let blueInk = pair(0x2456c7, 0x7aa8ff)

    // MARK: - Geometry (no corner radii anywhere — that is the point)

    public static let borderWidth: CGFloat = 2
    public static let borderWidthLarge: CGFloat = 3
    public static let shadowSmall: CGFloat = 2
    public static let shadowMedium: CGFloat = 3
    public static let shadowLarge: CGFloat = 5

    // MARK: - Type

    public enum SansWeight: String { case regular = "SpaceGrotesk-Regular", medium = "SpaceGrotesk-Medium", bold = "SpaceGrotesk-Bold" }
    public enum MonoWeight: String { case regular = "IBMPlexMono-Regular", medium = "IBMPlexMono-Medium", semibold = "IBMPlexMono-SemiBold" }

    /// Space Grotesk. Scales with Dynamic Type relative to `style`.
    public static func sans(_ size: CGFloat, _ weight: SansWeight = .medium, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(weight.rawValue, size: size, relativeTo: style)
    }
    /// IBM Plex Mono. Scales with Dynamic Type relative to `style`.
    public static func mono(_ size: CGFloat, _ weight: MonoWeight = .medium, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(weight.rawValue, size: size, relativeTo: style)
    }

    public static let display = sans(32, .bold, relativeTo: .largeTitle)
    public static let title = sans(24, .bold, relativeTo: .title)
    public static let heading = sans(19, .bold, relativeTo: .title3)
    public static let body = sans(15, .medium, relativeTo: .body)
    public static let small = sans(12.5, .medium, relativeTo: .footnote)
    public static let label = mono(11, .semibold, relativeTo: .caption)
    public static let number = mono(15, .medium, relativeTo: .body)

    /// Registers every bundled .ttf once. Call from the App's init().
    /// Idempotent: a second call reports "already registered", which is ignored.
    public static func registerFonts(bundle: Bundle = .main) {
        let urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls where fontFiles.contains(url.deletingPathExtension().lastPathComponent) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
    static let fontFiles: Set<String> = [
        "SpaceGrotesk-Regular", "SpaceGrotesk-Medium", "SpaceGrotesk-Bold",
        "IBMPlexMono-Regular", "IBMPlexMono-Medium", "IBMPlexMono-SemiBold",
    ]

    // MARK: - Helpers

    static func hex(_ v: UInt32) -> Color { Color(uiColor: uiHex(v)) }
    static func pair(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? uiHex(dark) : uiHex(light) })
    }
    static func uiHex(_ v: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

// MARK: - Status (shape, not only colour — WCAG 1.4.1)

public enum DeckStatus { case ok, warn, crit, idle }

/// ok ● · warn ◆ · crit ■ · idle ○
public struct DeckDot: View {
    public var status: DeckStatus
    public var size: CGFloat = 8
    public init(_ status: DeckStatus, size: CGFloat = 8) {
        self.status = status
        self.size = size
    }
    public var body: some View {
        Group {
            switch status {
            case .ok: Circle().fill(Deck.okInk)
            case .warn: Rectangle().fill(Deck.warnInk).rotationEffect(.degrees(45)).scaleEffect(0.85)
            case .crit: Rectangle().fill(Deck.critInk)
            case .idle: Circle().strokeBorder(Deck.muted, lineWidth: 2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Surfaces

/// A bordered surface with the hard offset shadow. `large` = the 3px/5px card,
/// otherwise the 2px/3px tile.
public struct DeckBox: ViewModifier {
    var fill: Color
    var large: Bool
    public func body(content: Content) -> some View {
        let bw = large ? Deck.borderWidthLarge : Deck.borderWidth
        let sh = large ? Deck.shadowLarge : Deck.shadowMedium
        content
            .background(fill)
            .overlay(Rectangle().strokeBorder(Deck.line, lineWidth: bw))
            .background(Rectangle().fill(Deck.shadow).offset(x: sh, y: sh))
            .padding(.trailing, sh).padding(.bottom, sh)  // keep the shadow inside the layout box
    }
}

extension View {
    /// 3px border, 5px hard shadow, surface fill — the Deck card.
    public func deckCard(fill: Color = Deck.surface) -> some View { modifier(DeckBox(fill: fill, large: true)) }
    /// 2px border, 3px hard shadow — service tiles and list rows that act as buttons.
    public func deckTile(fill: Color = Deck.surface) -> some View { modifier(DeckBox(fill: fill, large: false)) }
    /// Mono, uppercase, tracked — section labels and table heads.
    public func deckLabel() -> some View {
        font(Deck.label).textCase(.uppercase).tracking(0.66).foregroundStyle(Deck.muted)
    }
    /// The page ground behind everything.
    public func deckGround() -> some View { background(Deck.ground.ignoresSafeArea()) }
}

// MARK: - Chip

public struct DeckChip: View {
    public enum Kind { case plain, ok, warn, crit, accent, ink }
    var text: String
    var kind: Kind
    var status: DeckStatus?
    public init(_ text: String, kind: Kind = .plain, status: DeckStatus? = nil) {
        self.text = text
        self.kind = kind
        self.status = status
    }
    public var body: some View {
        HStack(spacing: 6) {
            if let status { DeckDot(status).foregroundStyle(fg) }
            Text(text).font(Deck.label).textCase(.uppercase).tracking(0.44)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(bg)
        .overlay(Rectangle().strokeBorder(Deck.line, lineWidth: Deck.borderWidth))
        .background(Rectangle().fill(Deck.shadow).offset(x: Deck.shadowSmall, y: Deck.shadowSmall))
    }
    var bg: Color {
        switch kind {
        case .plain: Deck.surface
        case .ok: Deck.ok
        case .warn: Deck.warn
        case .crit: Deck.crit
        case .accent: Deck.accent
        case .ink: Deck.ink
        }
    }
    var fg: Color {
        switch kind {
        case .plain: Deck.ink
        case .ink: Deck.inkInverse
        default: Deck.onFill
        }
    }
}

// MARK: - Buttons
// Press = the shadow collapses and the button moves into where it was.
// Disabled = dashed edge, no shadow — distinguishable without colour.

public struct DeckButtonStyle: ButtonStyle {
    public enum Kind { case plain, primary, ink, danger, ghost }
    var kind: Kind
    var small: Bool
    @Environment(\.isEnabled) private var isEnabled
    public init(_ kind: Kind = .plain, small: Bool = false) {
        self.kind = kind
        self.small = small
    }

    public func makeBody(configuration: Configuration) -> some View {
        let sh: CGFloat = kind == .ghost || !isEnabled ? 0 : (small ? Deck.shadowSmall : Deck.shadowMedium)
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .font(Deck.sans(small ? 11.5 : 13, .bold, relativeTo: .callout))
            .textCase(.uppercase).tracking(0.4)
            .foregroundStyle(isEnabled ? fg : Deck.muted)
            .padding(.horizontal, small ? 10 : 15).padding(.vertical, small ? 6 : 10)
            .frame(minHeight: small ? 28 : 44)  // 44pt tap target at regular size
            .background(isEnabled ? bg : Deck.rail)
            .overlay(border)
            .background(Rectangle().fill(Deck.shadow).offset(x: pressed ? 0 : sh, y: pressed ? 0 : sh).opacity(sh == 0 ? 0 : 1))
            .offset(x: pressed ? sh : 0, y: pressed ? sh : 0)
            .padding(.trailing, sh).padding(.bottom, sh)
            .animation(.easeOut(duration: 0.09), value: pressed)
    }
    @ViewBuilder var border: some View {
        if !isEnabled {
            Rectangle().strokeBorder(Deck.muted, style: StrokeStyle(lineWidth: Deck.borderWidth, dash: [5, 4]))
        } else if kind == .ghost {
            EmptyView()
        } else {
            Rectangle().strokeBorder(Deck.line, lineWidth: Deck.borderWidth)
        }
    }
    var bg: Color {
        switch kind {
        case .plain: Deck.surface
        case .primary: Deck.accent
        case .ink: Deck.ink
        case .danger: Deck.crit
        case .ghost: .clear
        }
    }
    var fg: Color {
        switch kind {
        case .plain, .ghost: Deck.ink
        case .ink: Deck.inkInverse
        case .primary, .danger: Deck.onFill
        }
    }
}

extension ButtonStyle where Self == DeckButtonStyle {
    public static var deck: DeckButtonStyle { DeckButtonStyle() }
    public static var deckPrimary: DeckButtonStyle { DeckButtonStyle(.primary) }
    public static var deckInk: DeckButtonStyle { DeckButtonStyle(.ink) }
    public static var deckDanger: DeckButtonStyle { DeckButtonStyle(.danger) }
    public static var deckGhost: DeckButtonStyle { DeckButtonStyle(.ghost) }
}

// MARK: - Segmented control
// One bordered strip; the selected cell is inverted. Replaces the system
// segmented Picker, whose rounded pill cannot be restyled into this.

public struct DeckSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(Value, String)]
    public init(selection: Binding<Value>, options: [(Value, String)]) {
        _selection = selection
        self.options = options
    }
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                let on = opt.0 == selection
                Button {
                    selection = opt.0
                } label: {
                    Text(opt.1).font(Deck.mono(12, .semibold, relativeTo: .footnote))
                        .textCase(.uppercase).tracking(0.5)
                        .frame(maxWidth: .infinity, minHeight: 44)  // 44pt tap target
                        .foregroundStyle(on ? Deck.inkInverse : Deck.ink)
                        // [] - a colour background otherwise runs on into any
                        // safe area the strip touches (under the home
                        // indicator, the selected cell became a tall block).
                        .background(on ? Deck.ink : Deck.surface, ignoresSafeAreaEdges: [])
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                if i < options.count - 1 { Rectangle().fill(Deck.line).frame(width: Deck.borderWidth) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(Rectangle().strokeBorder(Deck.line, lineWidth: Deck.borderWidth))
        .background(Rectangle().fill(Deck.shadow).offset(x: Deck.shadowSmall, y: Deck.shadowSmall))
        .padding(.trailing, Deck.shadowSmall).padding(.bottom, Deck.shadowSmall)
    }
}

// MARK: - Text field

public struct DeckFieldStyle: TextFieldStyle {
    var invalid: Bool
    /// Mono for machine strings — tokens, URLs, usernames — where 0/O and l/1 matter.
    var mono: Bool
    @FocusState private var focused: Bool
    public init(invalid: Bool = false, mono: Bool = false) {
        self.invalid = invalid
        self.mono = mono
    }
    public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .focused($focused)
            .font(mono ? Deck.number : Deck.body)
            .foregroundStyle(Deck.ink)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(Deck.surface)
            .overlay(Rectangle().strokeBorder(invalid ? Deck.critInk : Deck.line, lineWidth: Deck.borderWidth))
            .background(
                Rectangle().fill(invalid ? Deck.crit : Deck.accent)
                    .offset(x: 3, y: 3).opacity(focused || invalid ? 1 : 0)
            )
            .padding(.trailing, 3).padding(.bottom, 3)
    }
}

// MARK: - Empty state (dashed = "nothing here yet", distinct from a loaded card)

public struct DeckEmpty<Action: View>: View {
    var label: String
    var title: String
    var message: String
    var action: Action
    public init(label: String, title: String, message: String, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.label = label
        self.title = title
        self.message = message
        self.action = action()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).deckLabel()
            Text(title).font(Deck.sans(17, .bold, relativeTo: .headline)).foregroundStyle(Deck.ink)
            Text(message).font(Deck.body).foregroundStyle(Deck.muted)
            action
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .overlay(Rectangle().strokeBorder(Deck.line, style: StrokeStyle(lineWidth: Deck.borderWidth, dash: [6, 4])))
    }
}

// MARK: - Theme (the web's data-theme; specimen.html's Auto · Cream · Dark)
//
// Web: no data-theme on <html> = follow the system; "light"/"dark" pins it.
// Here: `.auto` sets no override, `.light`/`.dark` pin every window. Every
// token above is a trait-driven pair, so pinning the WINDOW is the whole switch.
//
// WINDOW-LEVEL, NOT `.preferredColorScheme`. UIKit chrome - UITabBar and
// UINavigationBar appearances built from dynamic UIColors, sheets, alerts,
// menus, the keyboard - resolves against the window's trait collection, and
// the SwiftUI modifier is not guaranteed to reach it (or to hand it back to
// the system on nil). Setting overrideUserInterfaceStyle on the window flips
// the SwiftUI environment AND every UIKit bar in one move.
//
// Wiring, two lines per app: `.deckTheme()` on the root view inside the
// WindowGroup (applies the saved choice at launch), and `DeckThemePicker()`
// wherever the app keeps its settings.

public enum DeckTheme: String, CaseIterable, Identifiable {
    case auto, light, dark

    /// UserDefaults key, shared by `.deckTheme()` and `DeckThemePicker`.
    public static let storageKey = "deck.theme"

    public var id: Self { self }

    /// The specimen's labels. Light is "Cream": Deck Cream IS the light theme.
    public var label: String {
        switch self {
        case .auto: "Auto"
        case .light: "Cream"
        case .dark: "Dark"
        }
    }

    /// For a menu or an icon that shows the current choice.
    public var systemImage: String {
        switch self {
        case .auto: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    public var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .auto: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Stamps this choice on every window of every connected scene.
    @MainActor
    public func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where window.overrideUserInterfaceStyle != interfaceStyle {
                window.overrideUserInterfaceStyle = interfaceStyle
            }
        }
    }
}

/// Applies the saved theme when the root view appears (so on launch, and on
/// every new scene) and whenever the saved value changes.
public struct DeckThemeRoot: ViewModifier {
    @AppStorage(DeckTheme.storageKey) private var theme: DeckTheme = .auto
    public func body(content: Content) -> some View {
        content
            .onAppear { theme.apply() }
            .onChange(of: theme) { _, now in now.apply() }
    }
}

extension View {
    /// Put on the root view inside the WindowGroup. See DeckTheme.
    public func deckTheme() -> some View { modifier(DeckThemeRoot()) }
}

/// Auto · Cream · Dark as a DeckSegmented strip - the specimen's theme switch.
/// Applies on tap, so it needs no Save: it is a device preference, not data.
public struct DeckThemePicker: View {
    @AppStorage(DeckTheme.storageKey) private var theme: DeckTheme = .auto
    public init() {}
    public var body: some View {
        DeckSegmented(
            selection: Binding(
                get: { theme },
                set: {
                    theme = $0
                    $0.apply()
                }),
            options: DeckTheme.allCases.map { ($0, $0.label) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme")
    }
}
