import Foundation
import SwiftData

/// Removes page folders that no volume uses. They are left behind when the app
/// quits during an import or a chapter download.
enum OrphanCleanup {
    /// Runs once per launch. Only folders from before this launch are removed,
    /// so an import or download that starts now is never touched.
    static func run(in context: ModelContext) async {
        let launch = Date.now
        var descriptor = FetchDescriptor<Volume>()
        descriptor.propertiesToFetch = [\.id]
        // A failed fetch, or an empty library, could mean the store did not load.
        // Then deleting files would be dangerous, so do nothing.
        guard let volumes = try? context.fetch(descriptor), !volumes.isEmpty else { return }
        let used = Set(volumes.map(\.id))
        await Task.detached(priority: .background) {
            removeFolders(notIn: used, olderThan: launch)
        }.value
    }

    nonisolated private static func removeFolders(notIn used: Set<UUID>, olderThan date: Date) {
        let files = FileManager.default
        let folders = (try? files.contentsOfDirectory(
            at: LibraryPaths.root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent), !used.contains(id),
                  let values = try? folder.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate, modified < date
            else { continue }
            try? files.removeItem(at: folder)
        }
    }
}
