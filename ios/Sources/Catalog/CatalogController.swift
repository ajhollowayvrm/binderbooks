import Foundation
import Observation

/// Owns the live catalog and drives download, verification, and swap.
///
/// The swap rule: the live file never changes while a scan session runs. A
/// session calls `beginExclusiveUse()`. A catalog verified during that time is
/// staged, and it swaps in when the last session ends.
@MainActor
@Observable
final class CatalogController {
    enum State: Equatable {
        /// Nothing installed yet. The app is unusable until a download finishes.
        case missing
        case working(CatalogUpdater.Stage)
        case ready
        /// An error with no catalog installed. With one installed, errors go to `lastError`.
        case failed(String)
    }

    private(set) var state: State = .missing
    private(set) var database: CatalogDatabase?
    private(set) var meta: CatalogMeta?
    private(set) var installedManifest: CatalogManifest?
    private(set) var pendingManifest: CatalogManifest?
    private(set) var lastCheckedAt: Date?
    private(set) var lastError: String?
    /// Every signed card in the catalog, searchable by artwork.
    ///
    /// Built on demand and held for the life of the open catalog, because it
    /// costs nine megabytes and a second to build and the scanner asks for it
    /// once per card. Dropped when the catalog file is replaced: the
    /// signatures in it belong to that file.
    private(set) var artIndex: ArtIndex?
    /// The Simplified Chinese catalog he imported, if any. See `ChineseCatalog`.
    private(set) var chinese: ChineseCatalog.Info?
    /// True while an import or a removal rewrites the live catalog.
    private(set) var isChangingChinese = false

    private var artIndexTask: Task<ArtIndex?, Never>?
    private var locations: CatalogLocations?
    private var updater: CatalogUpdater?
    private var exclusiveUsers = 0
    private var checkTask: Task<Void, Never>?

    var isReady: Bool { database != nil }

    /// Open the installed catalog, then look for a newer one.
    func start() async {
        do {
            let locations = try CatalogLocations.standard()
            try locations.prepare()
            self.locations = locations
            self.updater = CatalogUpdater(locations: locations)
            try openInstalled()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        loadChineseInfo()
        await mergeChineseIfMissing()
        await applyPendingIfPossible()
        await check()
    }

    /// Fetch the manifest and install a newer catalog if one exists.
    func check() async {
        if let checkTask {
            await checkTask.value
            return
        }
        let task = Task { await runCheck() }
        checkTask = task
        await task.value
        checkTask = nil
    }

    /// Build the artwork index, or hand back the one already built.
    ///
    /// The scanner calls this when a session opens, so the first card of the
    /// stack does not pay for it. Nil when no catalog is open, or when the
    /// catalog carries no signatures.
    @discardableResult
    func loadArtIndex() async -> ArtIndex? {
        if let artIndex { return artIndex }
        if let artIndexTask { return await artIndexTask.value }
        guard let database else { return nil }
        let task = Task<ArtIndex?, Never> {
            try? await database.asyncRead { db in try ArtIndex.load(db) }
        }
        artIndexTask = task
        let built = await task.value
        artIndexTask = nil
        // A catalog swapped in while this was building invalidates it.
        guard self.database === database else { return nil }
        if let built, !built.isEmpty { artIndex = built }
        return artIndex
    }

    func beginExclusiveUse() {
        exclusiveUsers += 1
    }

    func endExclusiveUse() {
        exclusiveUsers = max(0, exclusiveUsers - 1)
        if exclusiveUsers == 0 {
            Task { await applyPendingIfPossible() }
        }
    }

    // MARK: - Simplified Chinese

    /// Take a Chinese catalog from Files, keep a copy, and add its cards to the
    /// live catalog. A file imported before is replaced.
    func importChinese(from source: URL) async {
        guard let locations else { return }
        guard exclusiveUsers == 0 else {
            lastError = "End the scan session, then import the Chinese catalog."
            return
        }
        isChangingChinese = true
        defer { isChangingChinese = false }
        lastError = nil
        let staged = locations.scratch.appendingPathComponent("chinese-import.sqlite")
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.copyFromFiles(source, to: staged)
                _ = try ChineseCatalog.inspect(staged)
            }.value
            let fm = FileManager.default
            if fm.fileExists(atPath: locations.chinese.path) {
                _ = try fm.replaceItemAt(locations.chinese, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: locations.chinese)
            }
            loadChineseInfo()
            // The kept copy is the source of truth. If the rewrite fails, the
            // next launch finds the live catalog without these cards and
            // merges them then.
            try await rewriteLive(with: locations.chinese)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Take the Chinese cards out of the live catalog and forget the file.
    ///
    /// Cards he already logged keep their product ids. They show as not
    /// identified until a Chinese catalog is imported again.
    func removeChinese() async {
        guard let locations else { return }
        guard exclusiveUsers == 0 else {
            lastError = "End the scan session, then remove the Chinese cards."
            return
        }
        isChangingChinese = true
        defer { isChangingChinese = false }
        lastError = nil
        do {
            try await rewriteLive(with: nil)
            try? FileManager.default.removeItem(at: locations.chinese)
            chinese = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Private

    private func openInstalled() throws {
        guard let locations, FileManager.default.fileExists(atPath: locations.live.path) else {
            state = .missing
            return
        }
        let db = try CatalogDatabase(path: locations.live.path)
        meta = try db.meta()
        database = db
        installedManifest = locations.readInstalledManifest()
        pendingManifest = locations.readPendingManifest()
        state = .ready
    }

    private func runCheck() async {
        guard let updater else { return }
        lastError = nil
        let hadCatalog = isReady
        if !hadCatalog { state = .working(.checking) }

        do {
            let manifest = try await updater.fetchManifest()
            lastCheckedAt = Date()
            guard CatalogSanity.isNewer(manifest, than: installedManifest) else {
                if hadCatalog { state = .ready }
                return
            }
            if let pendingManifest, pendingManifest.sha256 == manifest.sha256 {
                // Already downloaded and waiting for the session to end.
                if hadCatalog { state = .ready }
                return
            }

            if !hadCatalog { state = .working(.downloading(0)) }
            let previous = meta?.productCount
            let verified = try await updater.download(manifest, previousProductCount: previous) { [weak self] stage in
                Task { @MainActor [weak self] in
                    guard let self, !self.isReady else { return }
                    self.state = .working(stage)
                }
            }

            if exclusiveUsers > 0 {
                try await updater.stage(verified: verified, manifest: manifest)
                pendingManifest = manifest
                state = .ready
                return
            }
            try await swap(in: verified, manifest: manifest)
        } catch {
            lastError = error.localizedDescription
            state = hadCatalog ? .ready : .failed(error.localizedDescription)
        }
    }

    private func applyPendingIfPossible() async {
        guard exclusiveUsers == 0, let locations,
              let pending = locations.readPendingManifest(),
              FileManager.default.fileExists(atPath: locations.pending.path)
        else { return }
        do {
            let verified = locations.scratch.appendingPathComponent("catalog.sqlite")
            try? FileManager.default.removeItem(at: verified)
            try FileManager.default.moveItem(at: locations.pending, to: verified)
            try await swap(in: verified, manifest: pending)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Close the live handle, replace the file, reopen. Nothing reads the catalog
    /// between close and reopen. Callers on the main actor see `database == nil`
    /// for that moment only.
    ///
    /// A downloaded catalog holds no Chinese cards. `mergingChinese` adds the
    /// ones he imported before the file goes live, so the catalog is never
    /// without them.
    private func swap(in verified: URL, manifest: CatalogManifest, mergingChinese: Bool = true) async throws {
        guard let updater else { return }
        if mergingChinese, let locations, FileManager.default.fileExists(atPath: locations.chinese.path) {
            let chineseFile = locations.chinese
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ChineseCatalog.apply(chineseFile, to: verified)
                }.value
            } catch {
                // The catalog installs without them, and the next launch
                // merges them again.
                lastError = "The Chinese cards did not merge: \(error.localizedDescription)"
            }
        }
        let old = database
        database = nil
        artIndex = nil
        artIndexTask?.cancel()
        artIndexTask = nil
        try old?.close()
        do {
            try await updater.install(verified: verified, manifest: manifest)
        } catch {
            // Reopen whatever is on disk so the app keeps working.
            try? openInstalled()
            throw error
        }
        pendingManifest = nil
        try openInstalled()
    }

    private func loadChineseInfo() {
        guard let locations, FileManager.default.fileExists(atPath: locations.chinese.path) else {
            chinese = nil
            return
        }
        chinese = try? ChineseCatalog.inspect(locations.chinese)
    }

    /// A catalog installed before the import, or one whose merge failed, lacks
    /// the cards in the kept Chinese file. Add them.
    private func mergeChineseIfMissing() async {
        guard let database, let chinese, let locations, exclusiveUsers == 0 else { return }
        let merged = try? await database.asyncRead { db in try ChineseCatalog.mergedBuiltAt(db) }
        guard merged != chinese.builtAt else { return }
        do {
            try await rewriteLive(with: locations.chinese)
        } catch {
            lastError = "The Chinese cards did not merge: \(error.localizedDescription)"
        }
    }

    /// Copy the live catalog, replace its Chinese rows, and swap the copy in.
    private func rewriteLive(with chineseFile: URL?) async throws {
        guard let locations, let manifest = installedManifest,
              FileManager.default.fileExists(atPath: locations.live.path)
        else { throw ChineseCatalog.Failure.noCatalog }
        let copy = locations.scratch.appendingPathComponent("catalog-rewrite.sqlite")
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try? fm.removeItem(at: copy)
            try fm.copyItem(at: locations.live, to: copy)
            try ChineseCatalog.apply(chineseFile, to: copy)
        }.value
        try await swap(in: copy, manifest: manifest, mergingChinese: false)
    }

    /// Files hands over a URL outside the sandbox, and Box may still have to
    /// download the file. The coordinator waits for the bytes.
    nonisolated private static func copyFromFiles(_ source: URL, to destination: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        var coordination: NSError?
        var copying: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordination) { url in
            do {
                try fm.copyItem(at: url, to: destination)
            } catch {
                copying = error
            }
        }
        if let coordination { throw coordination }
        if let copying { throw copying }
    }
}
