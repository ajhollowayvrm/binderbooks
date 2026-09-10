import CoreGraphics
import Foundation

/// What one look at a card yielded: the strings that matter, nothing else.
struct ScanObservation: Equatable, Sendable {
    var number: String?
    /// The best guess at the card's name, and the first of `nameCandidates`.
    var name: String?
    /// Every line on the card that could be its name, best first.
    ///
    /// The frame cannot tell a card name from an attack name by looking: both
    /// are short, both are set large, and a blocklist of the words attacks use
    /// never ends. The catalog can tell them apart, because it holds every card
    /// name there is, so the matcher gets the shortlist and decides.
    var nameCandidates: [String] = []
    /// From a slab label barcode. Set alone; slabs are read by barcode, not OCR.
    var certNumber: String?
    var grader: String?

    var isEmpty: Bool { number == nil && name == nil && certNumber == nil }
}

/// A recognized text item, reduced to what the interpreter needs. The VisionKit
/// item is not constructible in tests, so the coordinator maps to this.
struct RecognizedText: Equatable, Sendable {
    var id: UUID
    var transcript: String
    /// Top edge, 0 at the top of the viewfinder, 1 at the bottom.
    var top: CGFloat
    /// Height as a fraction of the viewfinder.
    var height: CGFloat
}

/// Turns the text items in a frame into an observation.
///
/// A card frame holds many strings: name, HP, attacks, flavor text, the number.
/// The number is the strongest key, so find it by shape. The name is the
/// tallest string near the top of the card. Everything else is noise.
enum FrameInterpreter {
    private static let numberPatterns: [Regex<AnyRegexOutput>] = [
        try! Regex(#"\b\d{1,3}\s*/\s*\d{1,3}\b"#),
        try! Regex(#"\b\d{1,3}\s*/\s*[A-Z]{1,3}-?[A-Z]{0,3}\b"#),
        try! Regex(#"\b(?:SWSH|SVP|SM|XY|BW|DP|HGSS|MEP|ME)\s?\d{1,3}[a-z]?\b"#),
        try! Regex(#"\b(?:BT|EX|ST|LM|RB|P)-?\d{1,2}-\d{3}\b"#),
        try! Regex(#"\b[A-Z]{2,3}\d{2}[A-Z]{2}/[A-Z]{2,5}-\d{1,2}-(?:AP)?\d{2,3}\b"#),
    ]

    /// Digits, optionally with a space around the slash. OCR reads "114/ 084".
    static func number(in transcripts: [String]) -> (index: Int, value: String)? {
        for (index, raw) in transcripts.enumerated() {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            for pattern in numberPatterns {
                if let match = text.firstMatch(of: pattern) {
                    let value = String(text[match.range]).replacingOccurrences(of: " ", with: "")
                    return (index, value)
                }
            }
        }
        return nil
    }

    /// How many lines the matcher is asked to consider. Four covers a card
    /// whose name was missed, its attacks, and an ability, without turning one
    /// match into a dozen searches.
    static let nameCandidateLimit = 4

    static func interpret(_ items: [RecognizedText]) -> (observation: ScanObservation, numberItemID: UUID?) {
        var observation = ScanObservation()
        var numberID: UUID?

        let transcripts = items.map(\.transcript)
        if let found = number(in: transcripts) {
            observation.number = found.value
            numberID = items[found.index].id
        }

        observation.nameCandidates = nameCandidates(items, excluding: numberID)
        observation.name = observation.nameCandidates.first
        return (observation, numberID)
    }

    /// The name shares its line with the HP on a Pokémon card, and VisionKit
    /// often returns that line as one item: "Articuno HP 110". Strip the HP
    /// and keep the rest.
    private static let hpLine = #/^(?<name>.+?)\s*(?:HP\s*\d{2,3}|\d{2,3}\s*HP)\s*$/#.ignoresCase()

    /// How close to the tallest line a line must be to count as name-sized.
    static let nameHeightTolerance = 0.85

    /// The card's name. A line that carries the HP wins outright. Otherwise the
    /// **tallest** plausible line, and the topmost of those that tie.
    ///
    /// Topmost alone was wrong. A still holds the whole scene — his desk, a
    /// keyboard, a cable — so "highest in the frame" is not "highest on the
    /// card", and when the name was missed the attack name won instead. On a
    /// Pokémon card the name is set larger than the attacks: on the Sableye
    /// that failed, "Sableye" measured 0.043 of the frame and "Scratch" 0.032.
    static func nameCandidate(_ items: [RecognizedText], excluding numberID: UUID?) -> String? {
        nameCandidates(items, excluding: numberID).first
    }

    /// Every line that could be the name, best first: a line carrying the HP
    /// leads, then the tallest, then the highest. The matcher checks them
    /// against the catalog and takes the one that is a real card.
    static func nameCandidates(_ items: [RecognizedText], excluding numberID: UUID?) -> [String] {
        var withHP: [(String, CGFloat)] = []
        var plain: [RecognizedText] = []
        for item in items where item.id != numberID {
            let text = item.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if let m = text.wholeMatch(of: hpLine) {
                let name = String(m.name).trimmingCharacters(in: .whitespaces)
                if isPlausibleName(name) { withHP.append((name, item.top)) }
                continue
            }
            if isPlausibleName(text) { plain.append(item) }
        }
        var ordered: [String] = []
        // A line carrying the HP is the card's name and nothing else is.
        for (name, _) in withHP.sorted(by: { $0.1 < $1.1 }) where !ordered.contains(name) {
            ordered.append(name)
        }
        // Then by height, tallest first, and by position within a tie. The name
        // is set larger than the attacks, but not on every card, so this orders
        // the shortlist rather than settling it.
        let tallest = plain.map(\.height).max() ?? 0
        let byLikelihood = plain.sorted { left, right in
            let leftSized = left.height >= tallest * nameHeightTolerance
            let rightSized = right.height >= tallest * nameHeightTolerance
            if leftSized != rightSized { return leftSized }
            if leftSized { return left.top < right.top }
            return left.height > right.height
        }
        for item in byLikelihood {
            let text = item.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            // "Leafeon V 200": the HP without its label. Drop the trailing number.
            let name = text.wholeMatch(of: trailingNumber).map { String($0.name) } ?? text
            if !ordered.contains(name) { ordered.append(name) }
        }
        return Array(ordered.prefix(nameCandidateLimit))
    }

    private static let trailingNumber = #/^(?<name>.+?)\s+\d{2,3}$/#

    static func isPlausibleName(_ text: String) -> Bool {
        guard text.count >= 3, text.count <= 32 else { return false }
        let letters = text.filter(\.isLetter).count
        guard letters >= 3, letters * 2 >= text.count else { return false }
        let upper = text.uppercased()
        if upper.hasPrefix("BASIC") || upper.hasPrefix("STAGE") || upper.hasPrefix("TRAINER") || upper.hasPrefix("ILLUS") { return false }
        if upper.contains("POKÉMON") || upper.contains("POKEMON") { return false }
        if upper.hasPrefix("©") || upper.contains("NINTENDO") || upper.contains("CREATURES") || upper.contains("GAME FREAK") { return false }
        if upper.hasPrefix("ABILITY") || upper.hasPrefix("WEAKNESS") || upper.hasPrefix("RESISTANCE") || upper.hasPrefix("RETREAT") { return false }
        return true
    }

    /// PSA and CGC labels carry the cert number in a barcode. Newer labels use
    /// a QR code with a URL; older ones a Code 128 of the number.
    static func cert(fromBarcode payload: String) -> (cert: String, grader: String)? {
        let lower = payload.lowercased()
        let grader: String
        if lower.contains("psacard") {
            grader = "psa"
        } else if lower.contains("cgc") {
            grader = "cgc"
        } else {
            grader = "unknown"
        }
        let digits = payload.split(whereSeparator: { !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 6 }
        guard let cert = digits.last else { return nil }
        return (cert, grader)
    }
}
