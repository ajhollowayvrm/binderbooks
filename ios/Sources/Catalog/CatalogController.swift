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

    func beginExclusiveUse() {
        exclusiveUsers += 1
    }

    func endExclusiveUse() {
        exclusiveUsers = max(0, exclusiveUsers - 1)
        if exclusiveUsers == 0 {
            Task { await applyPendingIfPossible() }
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
}
