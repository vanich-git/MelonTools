import SwiftUI
import AppKit

/// Melon Tools Design System.
/// Apple-style neutral grays, a single golden-melon accent, SF Pro / SF Mono,
/// solid card and button surfaces (no Liquid Glass).
enum MTTheme {

    // MARK: - Adaptive color plumbing

    private static func adaptive(_ name: String, dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name), dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        }))
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    // MARK: - Accent & Multi-Accent Palette (Apple Liquid Glass)

    /// The primary golden-melon accent.
    static let gold = Color(hex: 0xF59E0B)
    /// Golden melon alias for amber.
    static let amber = Color(hex: 0xF59E0B)
    /// Ink on gold/amber — for text and icons placed on prominent accent fills.
    static let onGold = Color(hex: 0x1A1A1C)

    /// Cyan / Electric Blue — network latency, throughput, gateway API, telemetry.
    static let cyan = Color(hex: 0x38BDF8)
    /// Emerald Green — usable/healthy accounts, active services, success states.
    static let emerald = Color(hex: 0x10B981)
    /// Ruby Red / Coral — quota exhaustion, errors, stopped services, destructive actions.
    static let ruby = Color(hex: 0xEF4444)
    /// Violet / Purple — AI models, Codex engine, accounts pool, deep intelligence.
    static let violet = Color(hex: 0xA855F7)

    // MARK: - Neutral palette (dark: deep obsidian glass, light: crystalline soft gray)

    /// Window background: deep graphite / light gray.
    ///
    /// One flat colour is painted behind both the sidebar and the card board, so
    /// the whole window reads as a single surface instead of two differently lit
    /// halves.
    static let background = adaptive("mt.background",
        dark: rgb(17, 17, 19),       // #111113
        light: rgb(233, 233, 237))   // #E9E9ED
    /// Card surface.
    static let cardBackground = adaptive("mt.card",
        dark: rgb(31, 31, 34),       // #1F1F22
        light: rgb(252, 252, 253))
    /// Chips, input wells, nested surfaces.
    static let cardSoft = adaptive("mt.cardSoft",
        dark: rgb(42, 42, 45),       // #2A2A2D
        light: rgb(240, 240, 244))   // #F0F0F4
    /// Hairline borders.
    static let borderColor = adaptive("mt.border",
        dark: rgb(58, 58, 62),       // #3A3A3E
        light: rgb(219, 219, 225))   // #DBDBE1

    /// Primary text.
    static let textPrimary = adaptive("mt.textPrimary",
        dark: rgb(245, 245, 247),    // #F5F5F7
        light: rgb(29, 29, 31))      // #1D1D1F
    /// Secondary text.
    static let textSecondary = adaptive("mt.textSecondary",
        dark: rgb(162, 162, 170),    // #A2A2AA
        light: rgb(110, 110, 115))   // #6E6E73
    /// Tertiary text / faint glyphs.
    static let textTertiary = adaptive("mt.textTertiary",
        dark: rgb(148, 148, 156),    // #94949C
        light: rgb(100, 100, 106))   // #64646A

    // MARK: - Semantic status

    static let ok = emerald
    static let warn = amber
    static let danger = ruby
    static let info = cyan

    // MARK: - Compatibility aliases (older call sites)

    static let paper = background
    static let ink = textPrimary
    static let muted = textSecondary
    static let hairline = borderColor
    static let surface = cardBackground
    static let nightBg = background
    static let nightSurface = cardBackground
    static let nightText = textPrimary
    static let nightMuted = textSecondary
    static let nightBorder = borderColor

    // MARK: - Spacing

    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24
    static let s6: CGFloat = 32

    // MARK: - Radius

    static let rSmall: CGFloat = 8
    static let rCard: CGFloat = 14
    static let rBento: CGFloat = 18
    static let rSidebar: CGFloat = 20
    static let rPill: CGFloat = 999

    // MARK: - Fonts (SF Pro / SF Mono)

    /// Maps the compact 8–13 pt design scale to Dynamic Type text styles.
    /// A fixed `.system(size:)` font ignores the user's preferred text size;
    /// the semantic style keeps the same visual size at the default setting
    /// and grows with accessibility sizes. Sizes outside the compact scale
    /// (titles, metric values) stay explicit and are scaled at the call site
    /// with `@ScaledMetric` when they need to grow.
    private static func textStyle(for size: CGFloat) -> Font.TextStyle? {
        switch size {
        case ...9: return .caption2
        case 10: return .caption
        case 11: return .subheadline
        case 12: return .callout
        case 13: return .body
        default: return nil
        }
    }

    /// Display font for page titles (SF Pro Semibold). Large display sizes
    /// keep their explicit point size; `MTMetricTile` scales its value with
    /// `@ScaledMetric`.
    static func display(_ size: CGFloat = 28, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    /// Body font (SF Pro).
    static func body(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        if let style = textStyle(for: size) {
            return .system(style, design: .default, weight: weight)
        }
        return .system(size: size, weight: weight, design: .default)
    }
    /// Monospace for data, tables, logs (SF Mono).
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        if let style = textStyle(for: size) {
            return .system(style, design: .monospaced, weight: weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Surfaces

extension View {
    /// Card surface: a neutral panel with a hairline border.
    ///
    /// The bento layout keeps its plates — what is gone is the decoration: no
    /// coloured accent stroke, no radial glow, no shadow, no backdrop blur. That
    /// is what made the board look heavy and made every scroll frame expensive.
    func mtLiquidGlass(
        cornerRadius: CGFloat = MTTheme.rCard,
        accent: Color? = nil,
        borderWidth: CGFloat = 1.0
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(MTTheme.cardBackground))
            .overlay(shape.strokeBorder(MTTheme.borderColor.opacity(0.55), lineWidth: borderWidth))
    }

    /// Bento Card: neutral plate with a hairline border.
    ///
    /// `accent`, `cornerRadius` and `glowIntensity` stay in the signature for the
    /// existing call sites; the plate itself is colourless.
    func mtBentoCard(
        accent: Color? = nil,
        cornerRadius: CGFloat = MTTheme.rBento,
        glowIntensity: Double = 0.08
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(MTTheme.cardBackground))
            .overlay(shape.strokeBorder(MTTheme.borderColor.opacity(0.55), lineWidth: 1.0))
    }

    /// Floating Left Sidebar: the same neutral plate as a card, so the window
    /// keeps one consistent surface behind the navigation and behind the board.
    func mtFloatingSidebar(
        cornerRadius: CGFloat = MTTheme.rSidebar
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(MTTheme.cardBackground))
            .overlay(shape.strokeBorder(MTTheme.borderColor.opacity(0.55), lineWidth: 1.0))
    }

    /// A solid card surface: filled panel with a hairline border.
    func mtCardSurface(cornerRadius: CGFloat = MTTheme.rCard) -> some View {
        self
            .background(MTTheme.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
            )
    }
}

/// Button size variant
enum MTButtonSize {
    case regular
    case small
}

/// Button chrome: solid capsule — golden fill for prominent, soft surface for secondary.
struct MTSolidButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var prominent = false
    var size: MTButtonSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, tint: tint, prominent: prominent, size: size)
    }

    /// A nested view is required to read `isEnabled`: a `ButtonStyle` itself is
    /// not a view, so an `@Environment` property on the style stays at its
    /// default and disabled buttons kept looking active.
    private struct Chrome: View {
        let configuration: Configuration
        let tint: Color?
        let prominent: Bool
        let size: MTButtonSize
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(MTTheme.body(size == .small ? 10.5 : 12, weight: prominent ? .semibold : .medium))
                .padding(.horizontal, size == .small ? 9 : 14)
                .padding(.vertical, size == .small ? 4 : 7)
                .foregroundStyle(prominent ? MTTheme.onGold : MTTheme.textPrimary)
                .background(
                    Capsule().fill(prominent ? (tint ?? MTTheme.gold) : MTTheme.cardSoft)
                )
                .overlay(
                    Capsule().strokeBorder(prominent ? Color.clear : MTTheme.borderColor, lineWidth: 0.75)
                )
                .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.78 : 1))
                .overlay(
                    Capsule().strokeBorder(
                        isFocused ? MTTheme.cyan.opacity(0.9) : Color.clear,
                        lineWidth: 2
                    )
                )
                .contentShape(Capsule())
        }
    }
}

/// Glass Button style: pill with a specular edge.
///
/// Prominent buttons are always painted in the golden melon accent — the call to
/// action of a screen is amber, not a per-screen colour. Secondary buttons stay on
/// the card surface so the primary action is the only amber thing in the row.
struct MTGlassButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var prominent: Bool = false
    var size: MTButtonSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, prominent: prominent, size: size)
    }

    private struct Chrome: View {
        let configuration: Configuration
        let prominent: Bool
        let size: MTButtonSize
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(MTTheme.body(size == .small ? 10.5 : 12, weight: prominent ? .semibold : .medium))
                .padding(.horizontal, size == .small ? 9 : 14)
                .padding(.vertical, size == .small ? 4 : 7)
                .foregroundStyle(prominent ? MTTheme.onGold : MTTheme.textPrimary)
                .background(
                    Capsule()
                        .fill(prominent ? MTTheme.gold : MTTheme.cardSoft)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            prominent
                                ? AnyShapeStyle(Color.white.opacity(0.28))
                                : AnyShapeStyle(MTTheme.borderColor),
                            lineWidth: 0.75
                        )
                )
                .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.78 : 1))
                .overlay(
                    Capsule().strokeBorder(
                        isFocused ? MTTheme.cyan.opacity(0.9) : Color.clear,
                        lineWidth: 2
                    )
                )
                .contentShape(Capsule())
        }
    }
}

// MARK: - Colors

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// Status semantic used across provider diagnostics, codex quotas, gateway health.
enum MTStatus: String, Codable {
    case ok, warn, error, absent, running, idle, info
    var color: Color {
        switch self {
        case .ok: return MTTheme.ok
        case .warn: return MTTheme.warn
        case .error: return MTTheme.danger
        case .running: return MTTheme.gold
        case .info: return MTTheme.info
        case .idle: return MTTheme.textTertiary
        case .absent: return MTTheme.textTertiary
        }
    }
}
