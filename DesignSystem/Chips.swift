import SwiftUI

/// Library filter: "All", "Reading", "Unread", "Finished".
/// Selected = white capsule. Not selected = glass capsule.
struct FilterChip: View {
    let title: LocalizedStringResource
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.onPrimary : Theme.bodyText)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background {
                    if isSelected { Capsule().fill(Theme.primaryFill) }
                }
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .identity : .regular.interactive(), in: .capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A tag on the series page: "Fantasy", "Ongoing".
struct TagChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.bodyText)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .glassEffect(.regular, in: .capsule)
    }
}

/// The dashed "+ Tag" chip.
struct AddTagChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Tag", systemImage: "plus")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .overlay {
                    Capsule().strokeBorder(Theme.dashStroke,
                                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add tag")
    }
}

/// Small dark label on a cover: "8 vols", "NEW", "Finished".
struct CoverBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: .capsule)
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1) }
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack {
            FilterChip(title: "All", isSelected: true) {}
            FilterChip(title: "Reading", isSelected: false) {}
        }
        HStack {
            TagChip(name: "Fantasy")
            TagChip(name: "Ongoing")
            AddTagChip {}
        }
        CoverBadge(text: "8 vols")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ScreenBackground())
    .preferredColorScheme(.dark)
}
