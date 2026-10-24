import SwiftUI
import SwiftData

/// The History tab: volumes the user opened, most recent first.
struct HistoryView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(filter: #Predicate<Volume> { $0.lastReadAt != nil },
           sort: \Volume.lastReadAt, order: .reverse)
    private var volumes: [Volume]

    @State private var readingVolume: Volume?

    var body: some View {
        NavigationStack {
            Group {
                if volumes.isEmpty {
                    EmptyStateView(systemImage: "clock",
                                   title: "No History Yet",
                                   message: "Volumes you open appear here.")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(volumes) { volume in
                                RecentlyReadCard(volume: volume) { readingVolume = volume }
                            }
                        }
                        .padding(.horizontal, sizeClass == .regular ? 40 : 16)
                        .padding(.vertical, 8)
                    }
                }
            }
            .background(ScreenBackground())
            .navigationTitle("History")
        }
        .fullScreenCover(item: $readingVolume) { ReaderView(volume: $0) }
    }

    private var columns: [GridItem] {
        sizeClass == .regular
            ? [GridItem(.adaptive(minimum: 320), spacing: 18)]
            : [GridItem(.flexible())]
    }
}

/// Glass icon tile, title and one line of text, centered. For empty tabs.
struct EmptyStateView: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 10) {
            GlassIconTile(systemImage: systemImage, size: 72)
                .padding(.bottom, 10)
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(Theme.primaryText)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
