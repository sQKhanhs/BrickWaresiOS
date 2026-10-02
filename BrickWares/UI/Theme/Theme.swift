import SwiftUI
import UIKit

/// Localized string by key. Keys are shared with the Android app (see scripts/gen_strings.py), so
/// copy is edited once. Format args: `String` → `%@`, `Int` → `%lld`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    // No locale on purpose: a locale would group integers ("Oct 2.017"). Counts that want grouping
    // are pre-formatted with Money.count and passed as strings — same as Android's plain %d.
    return args.isEmpty ? format : String(format: format, arguments: args)
}

/// BrickWares design tokens (the Android `BwColors` light/dark pair). Each token is a dynamic color,
/// so it follows the effective color scheme — system, or the Settings override — with no plumbing.
enum Bw {
    // Brand (shared across light/dark)
    static let yellow = Color(hex: 0xFFD500)
    static let onYellow = Color(hex: 0x1A1A1A)
    static let error = Color(hex: 0xC0392B)

    static let success = dynamic(0x2F7D4F, 0x57C46E)
    static let gwp = dynamic(0x7A3E9D, 0xC79BE6)
    static let promo = dynamic(0x1E7F7B, 0x57C4BF)
    static let magazine = dynamic(0x2563A8, 0x6FA6E6)
    static let pending = dynamic(0xC2671C, 0xE89A54)

    static let bg = dynamic(0xFAF8F5, 0x18181B)
    static let surface = dynamic(0xF4F2EC, 0x242420)
    static let card = dynamic(0xFFFFFF, 0x2B2B27)
    static let text = dynamic(0x1A1A1A, 0xF3F1EA)
    static let textSecondary = dynamic(0x3A3A36, 0xD9D7CD)
    static let textMuted = dynamic(0x8A8A84, 0xA9A79D)
    static let textMuted2 = dynamic(0x6A6A64, 0xBCBAB0)
    static let textFaint = dynamic(0x9A9A94, 0x7D7B73)
    static let border = dynamic(light: UIColor(white: 0, alpha: 0.08), dark: UIColor(white: 1, alpha: 0.10))
    static let borderSoft = dynamic(light: UIColor(white: 0, alpha: 0.06), dark: UIColor(white: 1, alpha: 0.07))
    static let borderStrong = dynamic(light: UIColor(white: 0, alpha: 0.15), dark: UIColor(white: 1, alpha: 0.18))
    static let track = dynamic(light: UIColor(hex: 0xE6E4DC), dark: UIColor(white: 1, alpha: 0.12))
    static let link = dynamic(0x2F5FBF, 0x7AA8FF)
    static let link2 = dynamic(0x8A6D1E, 0xE0BB5A)
    static let placeholderA = dynamic(0xEEEEEE, 0x302F2B)
    static let placeholderB = dynamic(0xF7F7F5, 0x262521)

    static let cardRadius: CGFloat = 14
    static let gutter: CGFloat = 16

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        dynamic(light: UIColor(hex: light), dark: UIColor(hex: dark))
    }

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}

extension Availability {
    var label: String {
        switch self {
        case .available: L("status_available")
        case .pending: L("status_pending")
        case .exclusive: L("status_exclusive")
        case .gwp: L("status_gwp")
        case .promo: L("status_promotional")
        case .magazine: L("status_magazine")
        case .retired: L("status_retired")
        }
    }

    var color: Color {
        switch self {
        case .available: Bw.success
        case .pending: Bw.pending
        case .exclusive: Bw.link2
        case .gwp: Bw.gwp
        case .promo: Bw.promo
        case .magazine: Bw.magazine
        case .retired: Bw.error
        }
    }
}

// MARK: - Reusable styling

/// The rounded card container used across the app.
struct BwCard: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Bw.card, in: RoundedRectangle(cornerRadius: Bw.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Bw.cardRadius, style: .continuous).strokeBorder(Bw.border))
    }
}

extension View {
    func bwCard(padding: CGFloat = 14) -> some View { modifier(BwCard(padding: padding)) }

    /// Screen background + the standard side gutter.
    func bwScreen() -> some View {
        background(Bw.bg.ignoresSafeArea())
    }
}

/// The three sizes of a brand button.
/// - `regular`: a full-width call to action.
/// - `compact`: hugs its label (a card's inline actions, Retry, Sign in).
/// - `column`: an action stacked in a list card's price column — a size smaller, and as wide as the
///   column, so the buttons there are one line and all the same width (Android: 11 sp buttons filling a
///   fixed 120 dp column). The column must be `.priceColumn()` for the widths to line up.
enum BwButtonSize {
    case regular, compact, column

    fileprivate var font: Font {
        switch self {
        case .regular: .body.weight(.semibold)
        case .compact: .subheadline.weight(.semibold)
        case .column: .footnote.weight(.semibold)
        }
    }

    fileprivate var horizontalPadding: CGFloat {
        switch self {
        case .regular: 18
        case .compact: 12
        case .column: 10
        }
    }

    fileprivate var verticalPadding: CGFloat { self == .regular ? 12 : 7 }
    fileprivate var fillsWidth: Bool { self != .compact }
}

/// Icon and title side by side with a fixed gap. Brand buttons set this themselves rather than take the
/// context's default: inside a `List`, the system label style pushes the title away from the icon, and
/// on iOS 26 it reports no ideal width at all — so a `.priceColumn()` sized itself without the button
/// and the title was cut to "Se…".
private struct BwButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

private extension View {
    /// Label metrics shared by both brand button styles. A small button is always ONE line showing its
    /// whole title: it neither wraps ("Wish-/listed" used to double the pill's height in a narrow price
    /// column) nor shrinks or truncates — it takes the width its label needs.
    func bwButtonLabel(_ size: BwButtonSize) -> some View {
        labelStyle(BwButtonLabelStyle())
            .font(size.font)
            .lineLimit(size == .regular ? nil : 1)
            .fixedSize(horizontal: size != .regular, vertical: false)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(maxWidth: size.fillsWidth ? .infinity : nil)
    }
}

extension View {
    /// A list card's trailing price + actions column: exactly as wide as its widest line, so prices are
    /// never cut and `.column` buttons — which fill it — come out equal in width.
    func priceColumn() -> some View { fixedSize(horizontal: true, vertical: false) }
}

/// Primary brand button: yellow fill, dark text.
struct BwPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var size: BwButtonSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Bw.onYellow)
            .bwButtonLabel(size)
            .background(Bw.yellow.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45), in: Capsule())
    }
}

/// Secondary button: outlined capsule.
struct BwSecondaryButtonStyle: ButtonStyle {
    var size: BwButtonSize = .regular
    var tint: Color = Bw.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .bwButtonLabel(size)
            .background(Bw.surface.opacity(configuration.isPressed ? 0.6 : 1), in: Capsule())
            .overlay(Capsule().strokeBorder(Bw.borderStrong))
    }
}

extension ButtonStyle where Self == BwPrimaryButtonStyle {
    static var bwPrimary: BwPrimaryButtonStyle { .init() }
    static var bwPrimaryCompact: BwPrimaryButtonStyle { .init(size: .compact) }
    static var bwPrimaryColumn: BwPrimaryButtonStyle { .init(size: .column) }
}

extension ButtonStyle where Self == BwSecondaryButtonStyle {
    static var bwSecondary: BwSecondaryButtonStyle { .init() }
    static var bwSecondaryCompact: BwSecondaryButtonStyle { .init(size: .compact) }
    static var bwSecondaryColumn: BwSecondaryButtonStyle { .init(size: .column) }
}

/// "Oct 2017" / "2017" / "—" — localized month names.
func releaseLabel(year: Int, month: Int) -> String {
    guard year > 0 else { return "—" }
    guard (1...12).contains(month) else { return String(year) }
    let symbols = Calendar.current.shortStandaloneMonthSymbols
    return L("release_format", symbols[month - 1], year)
}
