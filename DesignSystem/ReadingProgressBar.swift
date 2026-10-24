import SwiftUI

/// Thin progress bar.
/// For right-to-left manga, set fillsFromTrailing = true, so the bar grows
/// in the same direction as the reader moves.
struct ReadingProgressBar: View {
    var value: Double                 // 0...1
    var fillsFromTrailing = false
    var height: CGFloat = 4
    var tint: Color = Theme.primaryFill
    var track: Color = Theme.track

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: fillsFromTrailing ? .trailing : .leading) {
                Capsule().fill(track)
                Capsule().fill(tint)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}

#Preview {
    VStack(spacing: 24) {
        ReadingProgressBar(value: 0.23)
        ReadingProgressBar(value: 0.23, fillsFromTrailing: true)
    }
    .padding(40)
    .background(ScreenBackground())
}
