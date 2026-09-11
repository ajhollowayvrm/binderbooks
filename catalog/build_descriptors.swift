// Fills the artwork signatures into catalog.sqlite.
//
// Text alone cannot separate two cards that share a number, read a Japanese
// name the catalog files in English, or see the foil pattern that is the whole
// difference between a 30 cent Snivy and an 18 dollar one. The phone answers
// all three by comparing the card in front of it against the artwork of the
// candidates. This is the job that puts that artwork in the catalog.
//
// It compiles ios/Sources/Scan/CardArtDescriptor.swift, the very file the app
// uses. Two implementations of the same arithmetic would drift, and the day
// they drifted every distance would quietly become noise.
//
// Runs on macOS, because Vision's feature print needs the neural engine.
//
//   swiftc -O catalog/build_descriptors.swift ios/Sources/Scan/CardArtDescriptor.swift \
//     -o /tmp/build-descriptors
//   /tmp/build-descriptors --catalog scripts/catalog.sqlite
//
// It is incremental: a product that already has a signature is skipped, so the
// daily run only pays for the cards that are new.

import Foundation
import ImageIO
import SQLite3

// MARK: - Arguments

struct Options {
    var catalog = "scripts/catalog.sqlite"
    var limit: Int?
    var groupId: Int?
    var workers = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
    var rebuild = false
    /// Stop after this long and let the caller publish what was signed.
    ///
    /// The first full pass is 76,000 cards and over an hour, and a job that is
    /// killed by its own timeout never reaches the publish step — so the work
    /// is thrown away and the next run starts from nothing, for ever. Stopping
    /// early is not a failure: signatures are written in batches as they are
    /// made, the ones already in the file are published, and tomorrow's run
    /// carries them forward and continues where this one stopped.
    var deadlineMinutes: Double?
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while let flag = arguments.first {
        arguments.removeFirst()
        func value() -> String {
            guard let next = arguments.first else {
                FileHandle.standardError.write(Data("\(flag) needs a value\n".utf8))
                exit(2)
            }
            arguments.removeFirst()
            return next
        }
        switch flag {
        case "--catalog": options.catalog = value()
        case "--limit": options.limit = Int(value())
        case "--group": options.groupId = Int(value())
        case "--workers": options.workers = Int(value()) ?? options.workers
        case "--rebuild": options.rebuild = true
        case "--deadline-minutes": options.deadlineMinutes = Double(value())
        default:
            FileHandle.standardError.write(Data("unknown flag \(flag)\n".utf8))
            exit(2)
        }
    }
    return options
}

// MARK: - SQLite

final class Catalog {
    private var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            throw Failure("cannot open \(path)")
        }
        // Not WAL. The app opens the shipped catalog read-only and its own note
        // says so: "journal_mode is DELETE in the shipped file. Read-only opens
        // create no sidecar." A file left in WAL needs a -wal companion that a
        // read-only open cannot create, and the catalog fails to open on the
        // phone. The signing job is the last thing to touch this file, so the
        // mode it leaves behind is the mode that ships.
        exec("PRAGMA journal_mode=DELETE")
        exec("PRAGMA synchronous=NORMAL")
    }

    deinit { sqlite3_close(handle) }

    /// Leave the file exactly as the app expects to find it.
    func finish() {
        exec("PRAGMA journal_mode=DELETE")
        exec("VACUUM")
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    func exec(_ sql: String) {
        sqlite3_exec(handle, sql, nil, nil, nil)
    }

    /// The table the app reads. One signature per product, and nothing else:
    /// the descriptor is derived data and is rebuilt, never edited.
    func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS productArt (
            productId  INTEGER PRIMARY KEY REFERENCES product(productId),
            descriptor BLOB NOT NULL
        );
        """)
    }

    /// The app refuses a catalog whose signatures it cannot reproduce, so the
    /// version the job built with is recorded beside them.
    func recordVersion() {
        exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        exec("""
        INSERT INTO meta (key, value) VALUES
            ('artFormatVersion', '\(CardArtDescriptor.formatVersion)'),
            ('artDimensions', '\(CardArtDescriptor.dimensions)')
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """)
    }

    struct Row {
        var productId: Int
        var imageUrl: String
    }

    /// Singles with an image and no signature yet. Sealed products are left
    /// out: nobody scans a booster box to find out what it is.
    func pending(limit: Int?, groupId: Int?, rebuild: Bool) throws -> [Row] {
        var sql = """
        SELECT p.productId, p.imageUrl FROM product p
        WHERE p.isSealed = 0 AND p.imageUrl IS NOT NULL
        """
        if !rebuild {
            sql += " AND NOT EXISTS (SELECT 1 FROM productArt a WHERE a.productId = p.productId)"
        }
        if let groupId { sql += " AND p.groupId = \(groupId)" }
        sql += " ORDER BY p.productId"
        if let limit { sql += " LIMIT \(limit)" }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure("cannot read the product table: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(Row(
                productId: Int(sqlite3_column_int64(statement, 0)),
                imageUrl: String(cString: sqlite3_column_text(statement, 1))
            ))
        }
        return rows
    }

    func write(_ signatures: [(productId: Int, descriptor: Data)]) throws {
        exec("BEGIN")
        var statement: OpaquePointer?
        let sql = "INSERT INTO productArt (productId, descriptor) VALUES (?, ?) ON CONFLICT(productId) DO UPDATE SET descriptor = excluded.descriptor"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure("cannot write: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }
        for signature in signatures {
            sqlite3_bind_int64(statement, 1, Int64(signature.productId))
            _ = signature.descriptor.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), nil)
            }
            if sqlite3_step(statement) != SQLITE_DONE {
                throw Failure("cannot write \(signature.productId): \(String(cString: sqlite3_errmsg(handle)))")
            }
            sqlite3_reset(statement)
        }
        exec("COMMIT")
    }

    func count(_ table: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT count(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }
}

// MARK: - Fetching

/// TCGplayer serves no image for a fair number of products — about one in forty
/// overall, and far more among the pattern printings. A 403 is an ordinary
/// answer, not an error: that card simply cannot be matched by artwork, and the
/// scan falls back to its text.
func download(_ urlString: String, session: URLSession) async -> Data? {
    guard let url = URL(string: urlString) else { return nil }
    var request = URLRequest(url: url)
    request.setValue("card-tracker-catalog-builder/1.0", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 30
    for attempt in 0..<3 {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 200 { return data }
            if http.statusCode == 403 || http.statusCode == 404 { return nil }
        } catch {
            // Fall through to the retry.
        }
        try? await Task.sleep(nanoseconds: UInt64(200_000_000 << attempt))
    }
    return nil
}

/// What one product's attempt produced. TCGplayer serving no image is an
/// ordinary outcome, not an error, and is counted separately from an image that
/// arrived and could not be read.
enum Signed: Sendable {
    case signature(Int, Data)
    case noImage
    case unreadable
}

/// Gathers results from threads that are all writing at once.
final class SignedCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [Signed] = []

    func add(_ result: Signed) {
        lock.lock()
        collected.append(result)
        lock.unlock()
    }

    var results: [Signed] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

// MARK: - Run

@main
struct Build {
    static func main() async {
        let options = parseOptions()
        do {
            try await run(options)
        } catch {
            FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ options: Options) async throws {
        guard CardArtDescriptor.isAvailable else {
            throw Catalog.Failure("Vision cannot sign artwork on this machine. The job needs macOS with a neural engine, not a simulator.")
        }

        let catalog = try Catalog(path: options.catalog)
        catalog.createSchema()
        catalog.recordVersion()

        let rows = try catalog.pending(limit: options.limit, groupId: options.groupId, rebuild: options.rebuild)
        guard !rows.isEmpty else {
            print("nothing to do: every product already has a signature")
            return
        }
        print("signing \(rows.count) products with \(options.workers) workers")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = options.workers
        let session = URLSession(configuration: configuration)

        var signatures: [(productId: Int, descriptor: Data)] = []
        var missing = 0
        var unreadable = 0
        let started = Date()

        // Download *and* sign in the same task, so both run wide.
        //
        // This used to fetch a batch in parallel and then sign it in a serial
        // loop, with a comment claiming Vision would not go faster in parallel.
        // That was wrong and the numbers said so: eight workers and twelve
        // workers both gave about seventeen cards a second, because the workers
        // were never the constraint — the one-at-a-time feature print was.
        // Vision builds its own request and handler per call, so there is
        // nothing to serialise around.
        let deadline = options.deadlineMinutes.map { started.addingTimeInterval($0 * 60) }
        var stoppedEarly = false

        var index = 0
        while index < rows.count {
            if let deadline, Date() >= deadline {
                stoppedEarly = true
                break
            }
            let batch = Array(rows[index..<min(index + options.workers, rows.count)])
            index += batch.count

            // Fetch on the cooperative pool, sign on real threads.
            //
            // Signing cannot go in the task group with the download, however
            // much it looks like it should. `featurePrint` is a blocking
            // synchronous call, and blocking a cooperative thread is forbidden:
            // with one task per core all sitting inside Vision, nothing is left
            // to resume the download continuations and the whole job deadlocks
            // at zero per cent CPU. Measured, not guessed — it hung for
            // twenty-four minutes on a batch the serial version did in thirty
            // seconds.
            let images = await withTaskGroup(of: (Int, Data?).self) { group -> [(Int, Data?)] in
                for row in batch {
                    group.addTask { (row.productId, await download(row.imageUrl, session: session)) }
                }
                var out: [(Int, Data?)] = []
                for await result in group { out.append(result) }
                return out
            }

            // `concurrentPerform` brings its own threads, so the blocking work
            // runs wide without ever touching the cooperative pool.
            let collector = SignedCollector()
            DispatchQueue.concurrentPerform(iterations: images.count) { position in
                let (productId, data) = images[position]
                guard let data else { return collector.add(.noImage) }
                guard let image = decode(data),
                      let raw = try? CardArtDescriptor.featurePrint(of: image),
                      let descriptor = CardArtDescriptor.make(fromRaw: raw)
                else { return collector.add(.unreadable) }
                collector.add(.signature(productId, CardArtDescriptor.data(from: descriptor)))
            }
            let signed = collector.results

            for result in signed {
                switch result {
                case .noImage: missing += 1
                case .unreadable: unreadable += 1
                case let .signature(productId, data): signatures.append((productId, data))
                }
            }

            if signatures.count >= 500 {
                try catalog.write(signatures)
                signatures.removeAll(keepingCapacity: true)
            }
            if index % 500 < options.workers {
                let rate = Double(index) / max(1, Date().timeIntervalSince(started))
                print(String(format: "  %d/%d  %.1f/s  no image: %d", index, rows.count, rate, missing))
            }
        }
        try catalog.write(signatures)
        catalog.finish()

        let elapsed = Date().timeIntervalSince(started)
        if stoppedEarly {
            print("stopped at the deadline with \(rows.count - index) still to sign. Tomorrow's run continues from here.")
        }
        print(String(format: """
        done in %.0f s
          signed        %d
          no image      %d
          unreadable    %d
          in the table  %d
        """, elapsed, catalog.count("productArt") , missing, unreadable, catalog.count("productArt")))
    }
}
