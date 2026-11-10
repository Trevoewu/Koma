import Foundation
import Observation
import ZIPFoundation

/// A source repository that the user added: a folder on the web with an index.min.json.
nonisolated struct SourceRepository: Codable, Hashable, Identifiable, Sendable {
    /// The folder URL, with a trailing slash. Paths in the index are relative to it.
    var url: URL
    var name: String

    var id: URL { url }
}

/// One source in a repository index.
nonisolated struct RepositorySource: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var version: Int
    var iconURL: String?
    var downloadURL: String
    var languages: [String]?
    /// 0 safe, 1 contains NSFW, 2 primarily NSFW.
    var contentRating: Int?
    var baseURL: String?
    var minAppVersion: String?

    enum CodingKeys: String, CodingKey {
        case id, name, version, languages, contentRating, minAppVersion
        case iconURL, downloadURL, baseURL
        // Older indexes used "file" and "icon" names.
        case file, icon
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(Int.self, forKey: .version)
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
            ?? container.decodeIfPresent(String.self, forKey: .icon).map { "icons/\($0)" }
        if let url = try container.decodeIfPresent(String.self, forKey: .downloadURL) {
            downloadURL = url
        } else {
            downloadURL = "sources/" + (try container.decode(String.self, forKey: .file))
        }
        languages = try container.decodeIfPresent([String].self, forKey: .languages)
        contentRating = try container.decodeIfPresent(Int.self, forKey: .contentRating)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        minAppVersion = try container.decodeIfPresent(String.self, forKey: .minAppVersion)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(iconURL, forKey: .iconURL)
        try container.encode(downloadURL, forKey: .downloadURL)
        try container.encodeIfPresent(languages, forKey: .languages)
        try container.encodeIfPresent(contentRating, forKey: .contentRating)
        try container.encodeIfPresent(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(minAppVersion, forKey: .minAppVersion)
    }

    /// Koma never lists or installs sources that are mainly adult content.
    var isAllowed: Bool { (contentRating ?? 0) < 2 }
}

nonisolated enum SourceInstallError: LocalizedError {
    case invalidAddress
    case notARepository
    case badPackage
    case notAllowed
    case incompatible

    var errorDescription: String? {
        switch self {
        case .invalidAddress: String(localized: "Enter a web address that starts with https://.")
        case .notARepository: String(localized: "No source list was found at this address.")
        case .badPackage: String(localized: "The source package is damaged or is not a source.")
        case .notAllowed: String(localized: "Koma does not install sources for adult content.")
        case .incompatible: String(localized: "This source uses a format that Koma does not support.")
        }
    }
}

/// Installed sources, repositories, and one running plugin per source.
@MainActor
@Observable
final class SourceManager {
    /// Sources that Koma suggests on first use: only sources with public-domain or
    /// licensed content that we checked. Empty until such a source is verified.
    static let verifiedRepositories: [SourceRepository] = []

    private static let repositoriesKey = "sources.repositories"

    private(set) var repositories: [SourceRepository] = []
    private(set) var indexes: [URL: [RepositorySource]] = [:]
    private(set) var installed: [SourceInfo] = []
    /// Source ids with an install or update in progress.
    private(set) var installing: Set<String> = []

    @ObservationIgnored private var runners: [String: SourceRunner] = [:]
    @ObservationIgnored private var loadingRunners: [String: Task<SourceRunner, any Error>] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.repositoriesKey),
           let saved = try? JSONDecoder().decode([SourceRepository].self, from: data) {
            repositories = saved
        } else {
            repositories = Self.verifiedRepositories
        }
        reloadInstalled()
    }

    // MARK: Installed sources

    func reloadInstalled() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: SourcePaths.root, includingPropertiesForKeys: nil)) ?? []
        installed = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "source.json")) else { return nil }
            return try? SourceInfo(json: data)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func iconURL(for id: String) -> URL? {
        let url = SourcePaths.folder(for: id).appending(path: "icon.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The languages a source is set to read (its "languages" setting).
    func selectedLanguages(of id: String) -> [String] {
        guard let bytes = SourceDefaults(sourceID: id).get("languages") else { return [] }
        var reader = PostcardReader(bytes)
        return (try? reader.stringList()) ?? []
    }

    /// The languages an installed source shows: its setting, else all it has.
    func readingLanguages(_ source: SourceInfo) -> [String] {
        let selected = selectedLanguages(of: source.id)
        return selected.isEmpty ? source.languages : selected
    }

    func installedVersion(of id: String) -> Int? {
        installed.first { $0.id == id }?.version
    }

    /// The running plugin for a source. Loads it off the main actor the first time.
    func runner(for id: String) async throws -> SourceRunner {
        if let runner = runners[id] { return runner }
        if let task = loadingRunners[id] { return try await task.value }
        let folder = SourcePaths.folder(for: id)
        let task = Task.detached(priority: .userInitiated) { try SourceRunner(folder: folder) }
        loadingRunners[id] = task
        defer { loadingRunners[id] = nil }
        let runner = try await task.value
        runners[id] = runner
        return runner
    }

    func uninstall(_ id: String) {
        runners[id] = nil
        try? FileManager.default.removeItem(at: SourcePaths.folder(for: id))
        SourceDefaults(sourceID: id).removeAll()
        reloadInstalled()
    }

    // MARK: Repositories

    /// Adds a repository from an address the user typed.
    /// "https://example.com/sources" and ".../index.min.json" both work.
    func addRepository(address: String) async throws {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var url = URL(string: text), url.scheme?.lowercased() == "https", url.host() != nil else {
            throw SourceInstallError.invalidAddress
        }
        if url.pathExtension.lowercased() == "json" { url.deleteLastPathComponent() }
        let folder = url.absoluteString.hasSuffix("/") ? url : URL(string: url.absoluteString + "/")!
        guard !repositories.contains(where: { $0.url == folder }) else { return }

        let (name, sources) = try await Self.fetchIndex(folder)
        repositories.append(SourceRepository(url: folder, name: name ?? folder.host() ?? folder.absoluteString))
        indexes[folder] = sources
        saveRepositories()
    }

    func removeRepository(_ repository: SourceRepository) {
        repositories.removeAll { $0.id == repository.id }
        indexes[repository.url] = nil
        saveRepositories()
    }

    /// Loads the source lists of all repositories again.
    func refreshIndexes() async {
        await withTaskGroup(of: (URL, [RepositorySource]?).self) { group in
            for repository in repositories {
                group.addTask { (repository.url, try? await Self.fetchIndex(repository.url).sources) }
            }
            for await (url, sources) in group {
                if let sources { indexes[url] = sources }
            }
        }
    }

    /// Installed sources that a repository has in a newer version.
    var updates: [(RepositorySource, SourceRepository)] {
        repositories.flatMap { repository in
            (indexes[repository.url] ?? []).compactMap { source in
                guard let version = installedVersion(of: source.id), source.version > version else { return nil }
                return (source, repository)
            }
        }
    }

    private func saveRepositories() {
        if let data = try? JSONEncoder().encode(repositories) {
            UserDefaults.standard.set(data, forKey: Self.repositoriesKey)
        }
    }

    nonisolated private static func fetchIndex(_ folder: URL) async throws -> (name: String?, sources: [RepositorySource]) {
        struct Index: Decodable {
            var name: String?
            var sources: [RepositorySource]
        }
        for file in ["index.min.json", "index.json"] {
            guard let (data, response) = try? await URLSession.shared.data(from: folder.appending(path: file)),
                  (response as? HTTPURLResponse)?.statusCode == 200
            else { continue }
            if let index = try? JSONDecoder().decode(Index.self, from: data) {
                return (index.name, index.sources.filter(\.isAllowed))
            }
            // The old format is a plain list.
            if let sources = try? JSONDecoder().decode([RepositorySource].self, from: data) {
                return (nil, sources.filter(\.isAllowed))
            }
        }
        throw SourceInstallError.notARepository
    }

    // MARK: Install

    func install(_ source: RepositorySource, from repository: SourceRepository) async throws {
        guard source.isAllowed else { throw SourceInstallError.notAllowed }
        guard let packageURL = URL(string: source.downloadURL, relativeTo: repository.url)?.absoluteURL,
              packageURL.scheme?.lowercased() == "https"
        else { throw SourceInstallError.badPackage }
        installing.insert(source.id)
        defer { installing.remove(source.id) }

        let id = source.id
        try await Task.detached(priority: .userInitiated) {
            let (download, response) = try await URLSession.shared.download(from: packageURL)
            defer { try? FileManager.default.removeItem(at: download) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SourceInstallError.badPackage }
            try Self.unpack(download, expectedID: id)
        }.value

        runners[id] = nil
        reloadInstalled()
    }

    /// Copies the known files from Payload/ into the source folder.
    /// Paths from the zip are never used to write files.
    nonisolated private static func unpack(_ package: URL, expectedID: String) throws {
        let archive: Archive
        do { archive = try Archive(url: package, accessMode: .read) } catch { throw SourceInstallError.badPackage }

        let staging = FileManager.default.temporaryDirectory.appending(path: "source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        for entry in archive where entry.type == .file {
            let parts = entry.path.split(separator: "/")
            guard parts.count == 2, parts[0] == "Payload", SourcePaths.packageFiles.contains(String(parts[1])),
                  entry.uncompressedSize < 50_000_000
            else { continue }
            _ = try archive.extract(entry, to: staging.appending(path: String(parts[1])))
        }

        guard let infoData = try? Data(contentsOf: staging.appending(path: "source.json")),
              let info = try? SourceInfo(json: infoData), info.id == expectedID,
              FileManager.default.fileExists(atPath: staging.appending(path: "main.wasm").path)
        else { throw SourceInstallError.badPackage }
        guard info.contentRating < 2 else { throw SourceInstallError.notAllowed }

        // Load it once, so a source that Koma cannot run is not installed.
        do { _ = try SourceRunner(folder: staging) } catch { throw SourceInstallError.incompatible }

        try FileManager.default.createDirectory(at: SourcePaths.root, withIntermediateDirectories: true)
        let destination = SourcePaths.folder(for: info.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }
}
