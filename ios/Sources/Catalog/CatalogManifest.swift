import Foundation

/// The schema version this build of the app can read. The build job writes the
/// same number into `meta.schemaVersion`. A manifest with a higher number is
/// refused, and the installed catalog stays in place.
let supportedCatalogSchemaVersion = 1

/// `catalog-manifest.json`, as the build job writes it.
struct CatalogManifest: Codable, Equatable, Sendable {
    struct CategoryCount: Codable, Equatable, Sendable {
        var categoryId: Int
        var name: String
        var productCount: Int
    }

    var schemaVersion: Int
    var builtAt: String
    var sourceDate: String
    var sizeBytes: Int64
    var sha256: String
    var productCount: Int
    var categories: [CategoryCount]
    var url: URL

    /// Where the daily job publishes. The release tag is rolling. Every successful
    /// build replaces both assets under the same URLs.
    static let manifestURL = URL(string: "https://github.com/ajhollowayvrm/binderbooks/releases/download/catalog-latest/catalog-manifest.json")!

    var builtAtDate: Date? {
        ISO8601DateFormatter().date(from: builtAt)
    }
}

/// The `meta` table of an installed catalog.
struct CatalogMeta: Equatable, Sendable {
    var schemaVersion: Int
    var builtAt: String
    var sourceDate: String
    var productCount: Int
    var categories: [CatalogManifest.CategoryCount]

    init(rows: [String: String]) throws {
        guard
            let schema = rows["schemaVersion"].flatMap(Int.init),
            let builtAt = rows["builtAt"],
            let sourceDate = rows["sourceDate"],
            let count = rows["productCount"].flatMap(Int.init),
            let categoriesJSON = rows["categories"]?.data(using: .utf8)
        else {
            throw CatalogError.metaIncomplete(Array(rows.keys).sorted())
        }
        self.schemaVersion = schema
        self.builtAt = builtAt
        self.sourceDate = sourceDate
        self.productCount = count
        self.categories = try JSONDecoder().decode([CatalogManifest.CategoryCount].self, from: categoriesJSON)
    }

    init(schemaVersion: Int, builtAt: String, sourceDate: String, productCount: Int, categories: [CatalogManifest.CategoryCount]) {
        self.schemaVersion = schemaVersion
        self.builtAt = builtAt
        self.sourceDate = sourceDate
        self.productCount = productCount
        self.categories = categories
    }
}

enum CatalogError: LocalizedError, Equatable {
    case metaIncomplete([String])
    case schemaTooNew(manifest: Int, supported: Int)
    case schemaMismatch(file: Int, supported: Int)
    case checksumMismatch(expected: String, actual: String)
    case productCountMismatch(manifest: Int, file: Int)
    case productCountDropped(previous: Int, new: Int)
    case badResponse(Int)
    case gunzip(String)

    var errorDescription: String? {
        switch self {
        case .metaIncomplete(let keys):
            return "The catalog file has an incomplete meta table. Keys present: \(keys.joined(separator: ", "))."
        case .schemaTooNew(let manifest, let supported):
            return "The published catalog uses schema \(manifest). This app reads schema \(supported). Update the app."
        case .schemaMismatch(let file, let supported):
            return "The downloaded catalog file has schema \(file). This app reads schema \(supported)."
        case .checksumMismatch:
            return "The downloaded catalog did not match its checksum."
        case .productCountMismatch(let manifest, let file):
            return "The manifest promises \(manifest) products. The file holds \(file)."
        case .productCountDropped(let previous, let new):
            return "The new catalog holds \(new) products. The installed one holds \(previous). The drop is too large to trust."
        case .badResponse(let status):
            return "The catalog server answered HTTP \(status)."
        case .gunzip(let message):
            return "The catalog file did not decompress: \(message)"
        }
    }
}
