import Foundation

/// Graded comps from pokemonpricetracker.com, called straight from the phone
/// with his key. One card per call, looked up by TCGplayer product id, so the
/// answer is that product and never a fuzzy neighbour.
///
/// A lookup with eBay data costs about two credits. The key sits in
/// `PPTKey`; without it nothing here runs.
struct PPTClient {
    var key: String
    var session: URLSession = .shared

    static let base = URL(string: "https://www.pokemonpricetracker.com/api/v2")!

    enum Failure: Error, Equatable {
        case noKey
        case throttled(retryAfterSeconds: Int?)
        case http(Int)
        case unreadable
    }

    /// The comps PPT holds for one product, keyed the way the app keys them
    /// ("PSA 10", "CGC 9.5"), in cents. Empty when PPT knows the card and has
    /// no graded sales. Nil when PPT does not know the card.
    func gradedComps(tcgPlayerId: Int, language: String) async throws -> [String: Int]? {
        guard !key.isEmpty else { throw Failure.noKey }
        var components = URLComponents(url: Self.base.appending(path: "cards"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "tcgPlayerId", value: String(tcgPlayerId)),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "includeEbay", value: "true"),
            URLQueryItem(name: "language", value: language.lowercased().hasPrefix("j") ? "japanese" : "english"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200: break
        case 429: throw Failure.throttled(retryAfterSeconds: http?.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) })
        case let code: throw Failure.http(code)
        }
        return try Self.parse(data, tcgPlayerId: tcgPlayerId)
    }

    // MARK: - Parsing

    /// An id lookup answers `{"data": {…}}` with one card under it. A search
    /// answers with a list, under `data` or `cards`. Both, and a bare object
    /// or list, are read — the wrapper is not contractual anywhere in PPT's
    /// docs, and the single-object form is what broke the first build.
    static func parse(_ data: Data, tcgPlayerId: Int) throws -> [String: Int]? {
        let decoder = JSONDecoder()
        var cards: [Card] = []
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            cards = envelope.all
        }
        if cards.isEmpty, let one = try? decoder.decode(Card.self, from: data), one.tcgPlayerId != nil {
            cards = [one]
        }
        if cards.isEmpty, let list = try? decoder.decode([Card].self, from: data) {
            cards = list
        }
        guard !cards.isEmpty else { throw Failure.unreadable }
        // Trust but verify: PPT once ignored the filter.
        guard let card = cards.first(where: { $0.tcgPlayerId?.value == tcgPlayerId }) else { return nil }
        return comps(from: card.ebay?.salesByGrade ?? [:])
    }

    static func comps(from buckets: [String: Bucket]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (rawKey, bucket) in buckets {
            guard let label = gradeLabel(forBucket: rawKey), let cents = bucket.cents else { continue }
            out[label] = cents
        }
        return out
    }

    /// "psa10" is "PSA 10" and "cgc9_5" is "CGC 9.5". The grader is whatever
    /// letters lead the key, not a list the app keeps: PPT tracks `ace` and
    /// `tag` alongside PSA and CGC, and an allowlist silently drops a grader
    /// the day they add one. A key with no number ("ungraded") is not a grade.
    ///
    /// Note PPT has **no Pristine bucket**: CGC Pristine 10 sales sit in
    /// `cgc10`, so a fetch never fills the app's "CGC Pristine 10" row.
    static func gradeLabel(forBucket key: String) -> String? {
        let lower = key.lowercased()
        let grader = String(lower.prefix { $0.isLetter })
        guard !grader.isEmpty else { return nil }
        let rest = lower.dropFirst(grader.count).replacingOccurrences(of: "_", with: ".")
        guard !rest.isEmpty, rest.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let grade = rest.hasSuffix(".0") ? String(rest.dropLast(2)) : rest
        return "\(grader.uppercased()) \(grade)"
    }

    struct Envelope: Decodable {
        var cards: [Card]?
        var data: Payload?

        /// `data` is one card on an id lookup and a list on a search.
        enum Payload: Decodable {
            case one(Card)
            case many([Card])

            init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                if let list = try? single.decode([Card].self) {
                    self = .many(list)
                } else {
                    self = .one(try single.decode(Card.self))
                }
            }

            var cards: [Card] {
                switch self {
                case .one(let card): return [card]
                case .many(let list): return list
                }
            }
        }

        var all: [Card] { (cards ?? []) + (data?.cards ?? []) }
    }

    struct Card: Decodable {
        var tcgPlayerId: LooseInt?
        var name: String?
        var ebay: Ebay?
    }

    struct Ebay: Decodable {
        var salesByGrade: [String: Bucket]?
    }

    /// One grade's sales. `smartMarketPrice` is PPT's recency-weighted figure;
    /// the plain averages skew low because they include months-old sales.
    struct Bucket: Decodable {
        var smartMarketPrice: SmartPrice?
        var marketPrice7Day: Decimal?
        var averagePrice: Decimal?
        var medianPrice: Decimal?
        var count: Int?

        struct SmartPrice: Decodable {
            var price: Decimal?
        }

        /// Dollars to cents through `Decimal`. No `Double` on the way.
        var cents: Int? {
            guard let dollars = smartMarketPrice?.price ?? marketPrice7Day ?? averagePrice ?? medianPrice, dollars > 0 else { return nil }
            return NSDecimalNumber(decimal: dollars * 100).rounding(accordingToBehavior: nil).intValue
        }
    }

    /// PPT writes ids as numbers on one route and strings on another.
    struct LooseInt: Decodable {
        var value: Int

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let n = try? single.decode(Int.self) {
                value = n
            } else if let s = try? single.decode(String.self), let n = Int(s) {
                value = n
            } else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "not an id")
            }
        }
    }
}

/// Where the key lives. His phone, his key; a settings field, not a server.
enum PPTKey {
    static let defaultsKey = "pptApiKey"

    static var value: String {
        get { UserDefaults.standard.string(forKey: defaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultsKey) }
    }

    static var isSet: Bool { !value.isEmpty }
}
