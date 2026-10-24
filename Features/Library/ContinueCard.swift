import SwiftUI
import SwiftData

/// The glass "Continue" card at the top of the library.
///
/// iPhone: cover left, "Continue" pill, title, author, "Vol. 3 · Page 42 of 186",
/// progress, white Resume and a glass "…".
/// iPad (`isWide`): larger cover and title, the reading mode in a white pill,
/// "author · tags", and Resume / Edit / "…" buttons.
struct ContinueCard: View {
    let series: Series
    let volume: Volume
    let readingMode: ReadingMode
    var isWide = false
    var onResume: () -> Void
    var onShowSeries: () -> Void

    var body: some View {
        if isWide { wide } else { compact }
    }

    // MARK: iPhone

    private var compact: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverView(title: series.title, imageURL: volume.coverURL)
                .frame(width: 104)

            VStack(alignment: .leading, spacing: 5) {
                pill(Text("Continue"), filled: false)
                Text(series.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                if let author = series.author {
                    Text(author)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Text(volume.progressText)
                    .font(.footnote)
                    .foregroundStyle(Theme.bodyText)
                    .lineLimit(2)
                ReadingProgressBar(value: volume.progress)
                    .padding(.top, 2)

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    resumeButton(height: 44)
                    moreMenu(size: 44, shape: .circle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glassCard()
    }

    // MARK: iPad

    private var wide: some View {
        HStack(spacing: 36) {
            CoverView(title: series.title, imageURL: volume.coverURL, cornerRadius: 18)
                .frame(width: 170)

            VStack(alignment: .leading, spacing: 10) {
                pill(Text(readingMode.title), filled: true)
                Text(series.title)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if !detailLine.isEmpty {
                    Text(detailLine)
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.bodyText)
                        .lineLimit(1)
                }
                HStack(spacing: 14) {
                    Text(volume.progressText)
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                    ReadingProgressBar(value: volume.progress)
                        .frame(width: 240)
                }
                .padding(.top, 4)

                HStack(spacing: 12) {
                    resumeButton(height: 56)
                        .fixedSize()
                    Button("Edit", systemImage: "pencil", action: onShowSeries)
                        .font(.system(size: 18, weight: .semibold))
                        .buttonStyle(.glass)
                        .controlSize(.extraLarge)
                    moreMenu(size: 56, shape: .rect(cornerRadius: 18))
                }
                .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(26)
        .glassEffect(.regular, in: .rect(cornerRadius: 34))
    }

    /// "Rin Aoyama · Fantasy · Seafaring · Drama"
    private var detailLine: String {
        ([series.author].compactMap { $0 } + series.sortedTagNames.prefix(3)).joined(separator: " · ")
    }

    // MARK: Parts

    private func pill(_ text: Text, filled: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .frame(width: filled ? 6 : 5, height: filled ? 6 : 5)
            text
        }
        .font(.system(size: filled ? 14 : 12, weight: .semibold))
        .foregroundStyle(filled ? Theme.onPrimary : Theme.primaryText)
        .padding(.horizontal, filled ? 12 : 10)
        .frame(height: filled ? 30 : 24)
        .background(filled ? Theme.primaryFill : Theme.iconWellFill, in: .capsule)
    }

    private func resumeButton(height: CGFloat) -> some View {
        Button(action: onResume) {
            Label("Resume", systemImage: "play.fill")
                .padding(.horizontal, isWide ? 10 : 0)
        }
        .buttonStyle(PrimaryButtonStyle(fullWidth: !isWide, height: height))
    }

    private func moreMenu<S: Shape>(size: CGFloat, shape: S) -> some View {
        Menu {
            Button("Show Series", systemImage: "rectangle.stack", action: onShowSeries)
            Button("Mark Volume as Finished", systemImage: "checkmark.circle") {
                LibraryActions.markFinished(volume)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .frame(width: size, height: size)
                .contentShape(shape)
        }
        .glassEffect(.regular.interactive(), in: shape)
        .accessibilityLabel("More")
    }
}
