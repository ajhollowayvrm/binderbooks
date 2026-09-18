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

    /// Goes up by one on every swap. The live file keeps its path through a
    /// swap, so a cache keyed on the path would never see the new catalog.
    private(set) var version = 0

    /// Whether TCGCSV has prices newer than the ones on his cards.
    enum PriceState: Equatable {
        case unknown
        case checking
        /// Nothing newer. TCGCSV's last update, "2026-09-17".
        case current(String)
        /// TCGCSV is newer than the oldest price on his cards.
        case available(source: String, oldest: String)
        case refreshing(done: Int, total: Int)
        case failed(String)
    }

    private(set) var priceState: PriceState = .unknown
    private(set) var pricesCheckedAt: Date?

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

    // MARK: - Prices

    /// Asks TCGCSV for its last update and compares it with the oldest price
    /// on these products. Cheap: one small request and one query.
    func checkPrices(for productIds: [Int]) async {
        if case .refreshing = priceState { return }
        guard let database else { return }
        priceState = .checking
        do {
            let source = try await PriceRefresh.sourceDate()
            let ids = productIds
            let oldest = try await database.asyncRead { db in try PriceRefresh.oldestPriceDate(db, productIds: ids) }
            pricesCheckedAt = Date()
            if let oldest, source > oldest {
                priceState = .available(source: source, oldest: oldest)
            } else {
                priceState = .current(source)
            }
        } catch {
            priceState = .failed(error.localizedDescription)
        }
    }

    /// New prices for every set these products are in. Runs only when the
    /// last check found TCGCSV newer, because otherwise it returns the same
    /// prices it replaces.
    func refreshPrices(for productIds: [Int]) async {
        guard case .available(let source, _) = priceState else { return }
        guard exclusiveUsers == 0 else {
            priceState = .failed("End the scan session, then refresh the prices.")
            return
        }
        guard let database, let locations else { return }
        do {
            let ids = productIds
            let groups = try await database.asyncRead { db in try PriceRefresh.groups(db, productIds: ids) }
            priceState = .refreshing(done: 0, total: groups.count)
            var rows: [PriceRefresh.PriceRow] = []
            try await withThrowingTaskGroup(of: [PriceRefresh.PriceRow].self) { tasks in
                var next = groups.makeIterator()
                for _ in 0..<PriceRefresh.parallelDownloads {
                    guard let group = next.next() else { break }
                    tasks.addTask { try await PriceRefresh.prices(for: group) }
                }
                var done = 0
                while let found = try await tasks.next() {
                    rows += found
                    done += 1
                    priceState = .refreshing(done: done, total: groups.count)
                    if let group = next.next() {
                        tasks.addTask { try await PriceRefresh.prices(for: group) }
                    }
                }
            }

            // A scan may have started while the prices downloaded.
            guard exclusiveUsers == 0 else {
                priceState = .failed("End the scan session, then refresh the prices.")
                return
            }
            let copy = locations.scratch.appendingPathComponent("catalog-prices.sqlite")
            let fetched = rows
            let copied = version
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try? fm.removeItem(at: copy)
                try fm.copyItem(at: locations.live, to: copy)
                try PriceRefresh.apply(fetched, groups: groups, asOf: source, to: copy)
            }.value
            // A download that swapped in during the copy would be undone by
            // this swap. The copy is of the old file, so it must not go live.
            guard version == copied, let manifest = installedManifest else {
                priceState = .failed("The catalog changed during the refresh. Refresh again.")
                return
            }
            try await swap(in: copy, manifest: manifest)
            priceState = .current(source)
            pricesCheckedAt = Date()
        } catch {
            priceState = .failed(error.localizedDescription)
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
    private func swap(in verified: URL, manifest: CatalogManifest) async throws {
        guard let updater else { return }
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
        version += 1
    }
}
