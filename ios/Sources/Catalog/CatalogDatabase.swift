import Foundation
import GRDB

/// A read-only handle on one catalog file.
///
/// Search lands here in step 3. Step 2 only reads `meta`.
final class CatalogDatabase: Sendable {
    let path: String
    private let queue: DatabaseQueue

    init(path: String) throws {
        var configuration = Configuration()
        configuration.readonly = true
        // journal_mode is DELETE in the shipped file. Read-only opens create no sidecar.
        self.path = path
        self.queue = try DatabaseQueue(path: path, configuration: configuration)
    }

    func meta() throws -> CatalogMeta {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM meta")
            var map: [String: String] = [:]
            for row in rows {
                map[row["key"]] = row["value"]
            }
            return try CatalogMeta(rows: map)
        }
    }

    func read<T>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try queue.read(block)
    }

    /// Releases the file. Call before replacing the file on disk.
    func close() throws {
        try queue.close()
    }
}
