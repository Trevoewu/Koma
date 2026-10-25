import SwiftUI
import SwiftData
import UIKit

/// Changes made from the series page and the Edit sheet.
enum SeriesActions {
    /// Reuses a tag with the same name (case and width do not matter), else makes one.
    static func tag(named name: String, in context: ModelContext) -> Tag {
        let key = TitleNormalizer.key(name)
        let all = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        if let existing = all.first(where: { TitleNormalizer.key($0.name) == key }) { return existing }
        let tag = Tag(name: name)
        context.insert(tag)
        return tag
    }

    /// Replaces the tags of a series. A tag no series uses stays in the tag pool;
    /// Settings → Tags deletes it.
    static func setTags(_ names: [String], on series: Series, in context: ModelContext) {
        series.tags = names.map { tag(named: $0, in: context) }
    }

    /// Renames a tag in the pool. If another tag has the new name (case and width
    /// do not matter), the two become one.
    static func rename(_ tag: Tag, to name: String, in context: ModelContext) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let key = TitleNormalizer.key(name)
        let all = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        if let other = all.first(where: { $0 !== tag && TitleNormalizer.key($0.name) == key }) {
            for series in tag.series ?? [] where !(series.tags ?? []).contains(where: { $0 === other }) {
                series.tags = (series.tags ?? []) + [other]
            }
            context.delete(tag)
        } else {
            tag.name = name
        }
        try? context.save()
    }

    /// Makes tags with the same name (case and width do not matter) one tag,
    /// so the pool shows each name once. Older data can have duplicates.
    static func mergeDuplicateTags(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        var keep: [String: Tag] = [:]
        var changed = false
        for tag in all {
            let key = TitleNormalizer.key(tag.name)
            guard let first = keep[key] else { keep[key] = tag; continue }
            for series in tag.series ?? [] where !(series.tags ?? []).contains(where: { $0 === first }) {
                series.tags = (series.tags ?? []) + [first]
            }
            context.delete(tag)
            changed = true
        }
        if changed { try? context.save() }
    }

    /// Deletes a tag from the pool and from every series that has it.
    static func delete(_ tag: Tag, in context: ModelContext) {
        context.delete(tag)
        try? context.save()
    }

    /// Backfills existing imports once, so user-removed tags stay removed.
    static func extractFilenameTags(for series: Series, in context: ModelContext) {
        let pending = (series.volumes ?? []).filter { !$0.filenameTagsExtracted }
        guard !pending.isEmpty else { return }
        var tags = series.tags ?? []
        var keys = Set(tags.map { TitleNormalizer.key($0.name) })
        for volume in pending {
            for name in FileNameParser.tags(in: volume.title) {
                guard keys.insert(TitleNormalizer.key(name)).inserted else { continue }
                tags.append(tag(named: name, in: context))
            }
            volume.filenameTagsExtracted = true
        }
        series.tags = tags
        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }

    static func markUnread(_ volume: Volume) {
        volume.isFinished = false
        volume.currentPage = 0
        volume.lastReadAt = nil
        try? volume.modelContext?.save()
    }

    static func markAll(_ series: Series, read: Bool) {
        for volume in series.volumes ?? [] {
            if read { LibraryActions.markFinished(volume) } else { markUnread(volume) }
        }
        if !read { series.lastReadAt = nil }
        try? series.modelContext?.save()
    }

    /// Deletes one volume and its files. Returns true if that was the last volume,
    /// so the caller deletes the whole series.
    static func delete(_ volume: Volume, in context: ModelContext) -> Bool {
        guard let series = volume.series, series.volumeCount > 1 else { return true }
        try? LibraryPaths.deleteFiles(for: volume.id)
        context.delete(volume)
        try? context.save()
        return false
    }
}

extension Series {
    /// "Rin Aoyama, Kai Mori" → ["Rin Aoyama", "Kai Mori"]
    var authorNames: [String] {
        (author ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

extension Volume {
    /// "Vol. 3 · p. 42"
    var shortProgressText: String {
        String(localized: "\(displayName) · p. \(currentPage + 1)")
    }
}

/// The colors behind the series page, taken from the cover (the Series board tints
/// the gradient with the cover color: #24466E → #142A42 → near black).
/// Light mode uses the same hue, pale, fading to the light background.
struct SeriesTint: Equatable {
    var hue: Double
    var saturation: Double

    static let neutral = SeriesTint(hue: 0, saturation: 0)

    func top(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hue: hue, saturation: saturation, brightness: 0.43)
                        : Color(hue: hue, saturation: saturation * 0.35, brightness: 0.95)
    }

    func middle(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hue: hue, saturation: saturation, brightness: 0.26)
                        : Color(hue: hue, saturation: saturation * 0.18, brightness: 0.98)
    }

    /// From the cover's average color. Placeholder covers use their palette color.
    static func load(for series: Series) async -> SeriesTint {
        let fallback = UIColor(CoverPalette.for(series.title).base)
        guard let url = series.coverURL else { return make(from: fallback) }
        let average = await Task.detached(priority: .utility) { averageColor(of: url) }.value
        return make(from: average ?? fallback)
    }

    /// Keeps the hue and limits the saturation, so text stays readable on any cover.
    static func make(from color: UIColor) -> SeriesTint {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return SeriesTint(hue: hue, saturation: min(saturation, 0.65))
    }

    /// The average color of an image file, from a 32 px thumbnail drawn into 1 pixel.
    nonisolated static func averageColor(of url: URL) -> UIColor? {
        guard let image = ImageDownsampler.downsample(url, maxPixelSize: 32)?.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}

struct SeriesBackground: View {
    var tint: SeriesTint
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(stops: [
            .init(color: tint.top(scheme), location: 0),
            .init(color: tint.middle(scheme), location: 0.28),
            .init(color: .dynamic(light: 0xF7F7F9, dark: 0x050608), location: 0.6),
            .init(color: .dynamic(light: 0xEFEFF2, dark: 0x000000), location: 1)
        ], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.4), value: tint)
    }
}

/// Lays out views in rows that wrap, each row centered. For the tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
