import SwiftUI
import SwiftData

/// The cover grid: 3 columns on iPhone, about 7 on an iPad in landscape.
/// Tapping a cover opens the series. A long press offers Delete.
struct SeriesGrid: View {
    let series: [Series]
    var isWide = false
    var onDelete: (Series) -> Void

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: isWide ? 22 : 16) {
            ForEach(series) { item in
                NavigationLink(value: item) {
                    SeriesCell(series: item, isWide: isWide)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    NavigationLink(value: item) {
                        Label("Show Series", systemImage: "rectangle.stack")
                    }
                    Button("Delete Series…", systemImage: "trash", role: .destructive) {
                        onDelete(item)
                    }
                }
            }
        }
    }

    private var columns: [GridItem] {
        if isWide {
            [GridItem(.adaptive(minimum: 128), spacing: 18, alignment: .top)]
        } else {
            Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
        }
    }
}

struct SeriesCell: View {
    let series: Series
    var isWide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(title: series.title, imageURL: series.coverURL,
                      cornerRadius: isWide ? 16 : Theme.Radius.cover,
                      badge: series.badgeText)
            // The iPad design shows covers only. VoiceOver reads the title from the cover.
            if !isWide {
                VStack(alignment: .leading, spacing: 1) {
                    Text(series.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(series.author ?? " ")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .lineLimit(1)
                .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
    }
}

/// A row card with a small cover, title, "Vol. 3 · Page 42 of 186" and when it was read.
/// Used in the iPad "Recently Read" row and in History.
struct RecentlyReadCard: View {
    let volume: Volume
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                CoverView(title: volume.series?.title ?? volume.title,
                          imageURL: volume.coverURL,
                          cornerRadius: Theme.Radius.smallCover)
                    .frame(width: 56)
                    .shadow(radius: 0)

                VStack(alignment: .leading, spacing: 4) {
                    Text(volume.series?.title ?? volume.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(volume.progressText)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                    if let date = volume.lastReadAt {
                        Text(date, format: .relative(presentation: .named))
                            .font(.footnote)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Theme.sectionFill, in: .rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.sectionStroke, lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// A section title with an icon, like "All Series  14".
struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isWide = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: isWide ? 10 : 8) {
            Image(systemName: systemImage)
                .font(.system(size: isWide ? 20 : 17, weight: .semibold))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: isWide ? 26 : 22, weight: .bold))
            Spacer()
            trailing()
        }
        .foregroundStyle(Theme.primaryText)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, systemImage: String, isWide: Bool = false) {
        self.init(title: title, systemImage: systemImage, isWide: isWide) { EmptyView() }
    }
}
