import Foundation

/// Fetches the manifest, downloads a new catalog, verifies it, and stages it for
/// the swap. All file work happens off the main actor.
actor CatalogUpdater {
    enum Stage: Equatable, Sendable {
        case checking
        case downloading(Double)
        case verifying
    }

    let locations: CatalogLocations

    init(locations: CatalogLocations) {
        self.locations = locations
    }

    func fetchManifest() async throws -> CatalogManifest {
        var request = URLRequest(url: CatalogManifest.manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.badResponse(http.statusCode)
        }
        let manifest = try JSONDecoder().decode(CatalogManifest.self, from: data)
        try CatalogSanity.checkManifest(manifest)
        return manifest
    }

    /// Download, verify the checksum, decompress, open, and check the file.
    /// Returns the verified SQLite file in scratch space. The caller swaps it in.
    func download(
        _ manifest: CatalogManifest,
        previousProductCount: Int?,
        progress: @escaping @Sendable (Stage) -> Void
    ) async throws -> URL {
        let gz = locations.scratch.appendingPathComponent("catalog.sqlite.gz")
        let sqlite = locations.scratch.appendingPathComponent("catalog.sqlite")

        progress(.downloading(0))
        let downloader = Downloader(destination: gz) { fraction in progress(.downloading(fraction)) }
        try await downloader.run(manifest.url)

        progress(.verifying)
        let actual = try Checksum.sha256(of: gz)
        guard actual == manifest.sha256.lowercased() else {
            throw CatalogError.checksumMismatch(expected: manifest.sha256, actual: actual)
        }

        try Gunzip.decompress(from: gz, to: sqlite)
        try? FileManager.default.removeItem(at: gz)

        let database = try CatalogDatabase(path: sqlite.path)
        let meta = try database.meta()
        try database.close()
        try CatalogSanity.checkFile(meta: meta, manifest: manifest, previousProductCount: previousProductCount)
        return sqlite
    }

    /// Move a verified file into the live slot. Atomic on the same volume.
    func install(verified: URL, manifest: CatalogManifest) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: locations.live.path) {
            _ = try fm.replaceItemAt(locations.live, withItemAt: verified)
        } else {
            try fm.moveItem(at: verified, to: locations.live)
        }
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: locations.installedManifest, options: .atomic)
        try? fm.removeItem(at: locations.pending)
        try? fm.removeItem(at: locations.pendingManifest)
    }

    /// Park a verified file until the live catalog is free to change.
    func stage(verified: URL, manifest: CatalogManifest) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: locations.pending.path) {
            _ = try fm.replaceItemAt(locations.pending, withItemAt: verified)
        } else {
            try fm.moveItem(at: verified, to: locations.pending)
        }
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: locations.pendingManifest, options: .atomic)
    }
}
