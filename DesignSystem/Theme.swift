import SwiftUI

/// Colors and sizes from the prototype. Change them here, not in each screen.
///
/// Every color has a dark value (the prototype) and a light value (Settings →
/// Appearance). In light mode the "white" primary button becomes near-black,
/// so there is still one high-contrast button per screen.
enum Theme {
    static let backgroundGradient = LinearGradient(
        colors: [.dynamic(light: 0xFFFFFF, dark: 0x1C1C1E),
                 .dynamic(light: 0xF5F5F7, dark: 0x0B0B0C),
                 .dynamic(light: 0xEFEFF2, dark: 0x000000)],
        startPoint: .top, endPoint: .bottom
    )

    /// Titles and main text.
    static let primaryText = Color.dynamic(light: 0x000000, dark: 0xFFFFFF)

    /// The fill of primary buttons and selected chips (white in dark mode).
    static let primaryFill = Color.dynamic(light: 0x1C1C1E, dark: 0xF2F2F2)
    static let onPrimary = Color.dynamic(light: 0xFFFFFF, dark: 0x000000)

    /// Body text on cards: "Vol. 3 · Page 42 of 186", unselected chips.
    static let bodyText = Color.dynamic(light: 0x3A3A3C, dark: 0xD1D1D6)
    /// Light values keep 4.5:1 contrast on the light background.
    static let secondaryText = Color.dynamic(light: 0x545458, dark: 0xAEAEB2)
    static let tertiaryText = Color.dynamic(light: 0x6E6E73, dark: 0x8E8E93)

    /// Empty part of progress bars and sliders.
    static let track = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.16)

    /// Behind sheets such as Settings and the import summary.
    static let sheetGradient = LinearGradient(
        colors: [sheetTop, .dynamic(light: 0xF2F2F7, dark: 0x141416), sheetBottom],
        startPoint: .top, endPoint: .bottom
    )
    static let sheetTop = Color.dynamic(light: 0xF9F9FB, dark: 0x232325)
    static let sheetBottom = Color.dynamic(light: 0xEFEFF4, dark: 0x0E0E10)

    /// Fill of a section card and of the rows inside it.
    static let sectionFill = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.05)
    /// Cards and grouped lists: solid, not a grey tint (white in light mode).
    static let cardFill = Color.dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let sectionStroke = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
    /// Round icon well in a row (44 pt), and small pills.
    static let iconWellFill = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.10)
    /// Switches that are on. The app tint is white, which would hide the knob.
    static let switchOn = Color(hex: 0x34C759)
    /// The dashed outline of the "+ Tag" chip.
    static let dashStroke = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.30, darkAlpha: 0.32)

    /// Glass for the reader controls. Tinted dark, so white text stays readable
    /// over a white page (plain glass turns light there).
    static let readerGlass: Glass = .regular.tint(Color(hex: 0x1E1E20).opacity(0.62))

    /// The reader is always dark, whatever Settings → Appearance says. Dynamic colors
    /// follow the window's light/dark trait, which a SwiftUI view cannot override,
    /// so the reader uses these fixed dark values.
    enum Reader {
        static let primaryText = Color.white
        static let secondaryText = Color(hex: 0xAEAEB2)
        static let tertiaryText = Color(hex: 0x8E8E93)
        static let fill = Color(hex: 0xF2F2F2)
    }

    enum Radius {
        static let card: CGFloat = 28
        static let section: CGFloat = 26
        static let iconTile: CGFloat = 26
        static let row: CGFloat = 18
        static let cover: CGFloat = 14
        static let smallCover: CGFloat = 10
    }

    enum Size {
        static let iconButton: CGFloat = 44
        static let primaryButtonHeight: CGFloat = 52
        /// Side margin of grouped lists, so cards line up on every screen and sheet.
        static let listMargin: CGFloat = 20
    }
}

/// The gradient behind every screen except the reader.
struct ScreenBackground: View {
    var body: some View {
        Theme.backgroundGradient.ignoresSafeArea()
    }
}

extension View {
    /// A rounded glass card, like the "Continue" hero card.
    func glassCard(cornerRadius: CGFloat = Theme.Radius.card, padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    /// A grouped section inside a sheet, like "Reading" and "Storage" in Settings.
    func sectionCard() -> some View {
        self
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: .rect(cornerRadius: Theme.Radius.section))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.section)
                    .strokeBorder(Theme.sectionStroke, lineWidth: 1)
            }
    }
}

/// The large rounded glass tile with one icon, on the first-launch screen
/// and at the top of the import summary.
struct GlassIconTile: View {
    let systemImage: String
    var size: CGFloat = 88

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42))
            .foregroundStyle(Theme.secondaryText)
            .frame(width: size, height: size)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.iconTile))
            .accessibilityHidden(true)
    }
}

extension Color {
    /// A color with one value for light mode and one for dark mode.
    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let hex = isDark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    /// Color(hex: 0xF2F2F2)
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
