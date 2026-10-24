import SwiftUI

/// The sheet at the end of an import with at least one failure.
/// Same look as the Settings sheet: dark gradient, section card, rows,
/// and one white "Done" button.
struct ImportSummaryView: View {
    let importedCount: Int
    let failures: [ImportController.Failure]
    var onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                failureSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button("Done", action: onDone)
                .buttonStyle(.primaryFullWidth)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 8)
                // Rows scroll under the button. Fade them out so the text does not clash.
                .background {
                    LinearGradient(colors: [Theme.sheetBottom.opacity(0), Theme.sheetBottom],
                                   startPoint: .top, endPoint: .init(x: 0.5, y: 0.45))
                        .ignoresSafeArea()
                }
        }
        .presentationBackground(Theme.sheetGradient)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(spacing: 10) {
            GlassIconTile(systemImage: importedCount > 0 ? "exclamationmark.triangle" : "xmark.octagon")
                .padding(.bottom, 8)
            Text(importedCount > 0 ? "Import Finished" : "Import Failed")
                .font(.title2.bold())
                .foregroundStyle(Theme.primaryText)
            Text("\(importedCount) imported · \(failures.count) failed")
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var failureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Could Not Import")
                .font(.title3.bold())
                .foregroundStyle(Theme.primaryText)
                .padding(.bottom, 4)

            ForEach(failures) { failure in
                FailureRow(failure: failure)
            }
        }
        .sectionCard()
    }
}

private struct FailureRow: View {
    let failure: ImportController.Failure

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 18))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 44, height: 44)
                .background(Theme.iconWellFill, in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(failure.fileName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(failure.reason)
                    .font(.subheadline)
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.sectionFill, in: .rect(cornerRadius: Theme.Radius.row))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    Color.black
        .sheet(isPresented: .constant(true)) {
            ImportSummaryView(
                importedCount: 4,
                failures: [
                    .init(fileName: "潮汐圣徒 第9卷.zip",
                          reason: ImportError.damaged.errorDescription ?? ""),
                    .init(fileName: "Night Bus 404 - Extras.cbz",
                          reason: ImportError.noImages.errorDescription ?? "")
                ],
                onDone: {}
            )
        }
        .preferredColorScheme(.dark)
}
