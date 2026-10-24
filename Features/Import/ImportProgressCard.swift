import SwiftUI

/// The floating glass card at the bottom while files import:
///
///   [icon]  Importing 2 of 5                 (x)
///           Tidewater Saints v03.cbz
///           ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
///
/// After a clean import it shows "Imported 5 volumes" for a moment.
struct ImportProgressCard: View {
    let controller: ImportController

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 44, height: 44)
                .background(Theme.iconWellFill, in: .circle)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                    .contentTransition(.numericText())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isRunning {
                    ReadingProgressBar(value: controller.overallProgress)
                        .padding(.top, 6)
                        .animation(.linear(duration: 0.2), value: controller.overallProgress)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if isRunning {
                GlassIconButton(systemImage: "xmark", label: "Stop Import") {
                    controller.cancel()
                }
            }
        }
        .glassCard()
        .frame(maxWidth: 520)
    }

    private var isRunning: Bool { controller.phase == .running }

    private var iconName: String {
        if isRunning { return "arrow.down.doc" }
        return controller.wasCancelled ? "stop.fill" : "checkmark"
    }

    private var title: LocalizedStringKey {
        if isRunning {
            let current = min(controller.completed + 1, controller.total)
            return "Importing \(current) of \(controller.total)"
        }
        return controller.wasCancelled ? "Import Stopped" : "Imported \(controller.importedCount) volumes"
    }

    private var subtitle: LocalizedStringKey {
        if isRunning { return "\(controller.currentFileName)" }
        return controller.wasCancelled
            ? "\(controller.importedCount) volumes added to your library"
            : "Added to your library"
    }
}
