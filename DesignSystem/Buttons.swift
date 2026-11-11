import SwiftUI

// MARK: - Primary (white capsule)

/// The main action on a screen: "Resume", "Import Files", "Continue".
/// Use only one per screen.
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = false
    /// 52 pt by default. The Continue card uses 44 pt (iPhone) and 56 pt (iPad).
    var height: CGFloat = Theme.Size.primaryButtonHeight

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.onPrimary)
            .padding(.horizontal, 24)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(Theme.primaryFill, in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryFullWidth: PrimaryButtonStyle { PrimaryButtonStyle(fullWidth: true) }
}

// For secondary capsule buttons ("Edit", "Open from Files App"),
// use Apple's built-in style: .buttonStyle(.glass)

// MARK: - Round glass icon button

/// A round glass button with one icon: back, settings, more (…), search.
struct GlassIconButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    var size: CGFloat = Theme.Size.iconButton
    var glass: Glass = .regular
    var foreground: Color = Theme.primaryText
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(glass.interactive(), in: .circle)
        .accessibilityLabel(Text(label))
    }
}

#Preview {
    VStack(spacing: 20) {
        Button("Resume", systemImage: "play.fill") {}
            .buttonStyle(.primary)
        Button("Edit", systemImage: "pencil") {}
            .buttonStyle(.glass)
        HStack {
            GlassIconButton(systemImage: "chevron.left", label: "Back") {}
            GlassIconButton(systemImage: "ellipsis", label: "More") {}
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ScreenBackground())
    .preferredColorScheme(.dark)
}
