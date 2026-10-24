import Foundation

/// Where the app stores extracted pages and covers.
///
///   Application Support/MangaLibrary/
///     <volume id>/
///       cover.jpg
///       pages/0001.jpg, 0002.png, ...
///
/// We store only the volume id in SwiftData, never a full path,
/// because the app container path can change between launches.
enum LibraryPaths {
    nonisolated static let root: URL = URL.applicationSupportDirectory
        .appending(path: "MangaLibrary", directoryHint: .isDirectory)

    nonisolated static func volumeFolder(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    nonisolated static func pagesFolder(for id: UUID) -> URL {
        volumeFolder(for: id).appending(path: "pages", directoryHint: .isDirectory)
    }

    nonisolated static func coverURL(for id: UUID) -> URL {
        volumeFolder(for: id).appending(path: "cover.jpg")
    }

    nonisolated static func createRootIfNeeded() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    nonisolated static func deleteFiles(for id: UUID) throws {
        let folder = volumeFolder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }
}
