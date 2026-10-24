import Foundation
import SwiftData

/// Runs imports one file at a time and publishes the progress for the UI.
/// One instance for the whole app (KomaApp puts it in the environment), so
/// the picker now and "Open in" later (step 6) share one queue.
@MainActor @Observable
final class ImportController {
    struct Failure: Identifiable {
        let id = UUID()
        let fileName: String
        let reason: String
    }

    enum Phase { case idle, running, finished }

    private(set) var phase: Phase = .idle
    private(set) var total = 0
    private(set) var completed = 0
    private(set) var currentFileName = ""
    private(set) var currentFraction = 0.0
    private(set) var importedCount = 0
    private(set) var failures: [Failure] = []
    private(set) var wasCancelled = false

    /// The failure summary sheet. Shown at the end if at least one file failed.
    var showsSummary = false

    private var queue: [URL] = []
    private var task: Task<Void, Never>?
    private var currentWork: Task<ImportedVolume, any Error>?
    private var context: ModelContext?
    private let importer = ArchiveImporter()

    /// Files done plus the part of the current file, 0...1.
    var overallProgress: Double {
        guard total > 0 else { return 0 }
        return min((Double(completed) + currentFraction) / Double(total), 1)
    }

    /// Adds files to the queue. If an import is running, they join it.
    func start(_ urls: [URL], context: ModelContext) {
        guard !urls.isEmpty else { return }
        self.context = context
        if phase != .running {
            total = 0
            completed = 0
            importedCount = 0
            failures = []
            wasCancelled = false
            phase = .running
        }
        queue += urls
        total += urls.count
        if task == nil {
            task = Task { await run() }
        }
    }

    /// Stops after the current page. Files not started yet are skipped.
    func cancel() {
        guard phase == .running else { return }
        wasCancelled = true
        total -= queue.count
        queue.removeAll()
        currentWork?.cancel()
    }

    func dismissSummary() {
        showsSummary = false
        phase = .idle
    }

    // MARK: Work

    private func run() async {
        defer { task = nil }
        guard let context else { return }
        var linker: LibraryLinker
        do {
            linker = try LibraryLinker(context: context)
        } catch {
            for url in queue { fail(url, ImportError.writeFailed) }
            queue.removeAll()
            finish()
            return
        }

        while !queue.isEmpty {
            let url = queue.removeFirst()
            await importOne(url, linker: &linker)
            completed += 1
        }
        currentWork = nil
        finish()
    }

    private func importOne(_ url: URL, linker: inout LibraryLinker) async {
        currentFileName = url.lastPathComponent
        currentFraction = 0

        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
            Self.removeInboxCopy(url)
        }

        let index = completed
        let importer = importer
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in
                // A late update from the file before must not move the bar back.
                guard let self, self.completed == index else { return }
                self.currentFraction = fraction
            }
        }
        // A child task per file, so cancel() stops only this file
        // and the loop can go on with files added after it.
        let work = Task {
            try await importer.importArchive(at: url, progress: onProgress)
        }
        currentWork = work

        let imported: ImportedVolume
        do {
            imported = try await work.value
        } catch {
            let error = error as? ImportError ?? .writeFailed
            if error != .cancelled { fail(url, error) }   // Stopped by the user: not a failure.
            return
        }

        do {
            try linker.add(imported)
            importedCount += 1
        } catch {
            try? LibraryPaths.deleteFiles(for: imported.id)
            fail(url, .writeFailed)
        }
    }

    /// "Open in", the share sheet and AirDrop hand Koma a copy in Documents/Inbox.
    /// The pages are in the library now (or the import failed), so the copy can go.
    private static func removeInboxCopy(_ url: URL) {
        let inbox = URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory)
        guard url.standardizedFileURL.path.hasPrefix(inbox.standardizedFileURL.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func fail(_ url: URL, _ error: ImportError) {
        failures.append(Failure(fileName: url.lastPathComponent,
                                reason: error.errorDescription ?? ""))
    }

    private func finish() {
        currentFraction = 0
        phase = .finished
        if !failures.isEmpty {
            showsSummary = true
            return
        }
        // Success: the card shows "Imported…" for a moment, then goes away.
        let finishedTotal = total
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, self.phase == .finished, !self.showsSummary, self.total == finishedTotal else { return }
            self.phase = .idle
        }
    }
}
