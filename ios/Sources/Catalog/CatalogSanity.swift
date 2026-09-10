import Foundation

/// The checks a downloaded catalog must pass before it replaces the live one.
/// Pure functions, so the tests need no network and no files.
enum CatalogSanity {
    /// Refuse a manifest the app cannot read. The installed catalog stays.
    static func checkManifest(_ manifest: CatalogManifest) throws {
        if manifest.schemaVersion > supportedCatalogSchemaVersion {
            throw CatalogError.schemaTooNew(manifest: manifest.schemaVersion, supported: supportedCatalogSchemaVersion)
        }
    }

    /// Compare the file's own meta table with the manifest and the installed catalog.
    static func checkFile(meta: CatalogMeta, manifest: CatalogManifest, previousProductCount: Int?) throws {
        if meta.schemaVersion != supportedCatalogSchemaVersion {
            throw CatalogError.schemaMismatch(file: meta.schemaVersion, supported: supportedCatalogSchemaVersion)
        }
        if meta.productCount != manifest.productCount {
            throw CatalogError.productCountMismatch(manifest: manifest.productCount, file: meta.productCount)
        }
        // A build that lost half its rows is truncated, not smaller. The job refuses
        // to publish an empty category, so a real drop this large does not happen.
        if let previous = previousProductCount, previous > 0, meta.productCount * 2 < previous {
            throw CatalogError.productCountDropped(previous: previous, new: meta.productCount)
        }
    }

    /// True when the published build differs from the installed one.
    static func isNewer(_ manifest: CatalogManifest, than installed: CatalogManifest?) -> Bool {
        guard let installed else { return true }
        return manifest.sha256 != installed.sha256
    }
}
