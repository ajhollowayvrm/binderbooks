import Foundation

/// Where the catalog lives on disk.
///
/// Application Support, excluded from backup. The file is re-downloadable, so a
/// device backup has no reason to carry it. The collection store, which arrives
/// in step 3, lives elsewhere and is backed up.
struct CatalogLocations: Sendable {
    let directory: URL

    /// The live, read-only catalog. Never mutated in place.
    var live: URL { directory.appendingPathComponent("catalog.sqlite") }
    /// The manifest of the installed catalog. Written after a successful swap.
    var installedManifest: URL { directory.appendingPathComponent("installed-manifest.json") }
    /// A verified catalog that waits for a scan session to end before it swaps in.
    var pending: URL { directory.appendingPathComponent("pending.sqlite") }
    var pendingManifest: URL { directory.appendingPathComponent("pending-manifest.json") }
    /// Scratch space for downloads and decompression. Cleared on every start.
    var scratch: URL { directory.appendingPathComponent("scratch", isDirectory: true) }

    static func standard() throws -> CatalogLocations {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return CatalogLocations(directory: support.appendingPathComponent("Catalog", isDirectory: true))
    }

    func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.removeItem(at: scratch)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)

        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func readInstalledManifest() -> CatalogManifest? {
        guard let data = try? Data(contentsOf: installedManifest) else { return nil }
        return try? JSONDecoder().decode(CatalogManifest.self, from: data)
    }

    func readPendingManifest() -> CatalogManifest? {
        guard let data = try? Data(contentsOf: pendingManifest) else { return nil }
        return try? JSONDecoder().decode(CatalogManifest.self, from: data)
    }
}
