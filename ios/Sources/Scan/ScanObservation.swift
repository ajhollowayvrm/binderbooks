import CoreGraphics
import Foundation

/// What one look at a card yielded: the strings that matter, nothing else.
struct ScanObservation: Equatable, Sendable {
    var number: String?
    var name: String?
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

    static func interpret(_ items: [RecognizedText]) -> (observation: ScanObservation, numberItemID: UUID?) {
        var observation = ScanObservation()
        var numberID: UUID?

        let transcripts = items.map(\.transcript)
        if let found = number(in: transcripts) {
            observation.number = found.value
            numberID = items[found.index].id
        }

        observation.name = nameCandidate(items, excluding: numberID)
        return (observation, numberID)
    }

    /// The tallest plausible name in the top part of the frame.
    static func nameCandidate(_ items: [RecognizedText], excluding numberID: UUID?) -> String? {
        let plausible = items.filter { item in
            guard item.id != numberID else { return false }
            let text = item.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 3, text.count <= 32 else { return false }
            let letters = text.filter(\.isLetter).count
            guard letters >= 3, letters * 2 >= text.count else { return false }
            let upper = text.uppercased()
            if upper.contains("HP") && text.filter(\.isNumber).count >= 2 { return false }
            if upper.hasPrefix("BASIC") || upper.hasPrefix("STAGE") || upper.hasPrefix("TRAINER") || upper.hasPrefix("ILLUS") { return false }
            if upper.contains("POKÉMON") || upper.contains("POKEMON") { return false }
            if upper.hasPrefix("©") || upper.contains("NINTENDO") || upper.contains("CREATURES") { return false }
            return true
        }
        guard !plausible.isEmpty else { return nil }
        // Height dominates; being higher on the card breaks ties.
        let best = plausible.max { lhs, rhs in
            score(lhs) < score(rhs)
        }
        return best?.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func score(_ item: RecognizedText) -> CGFloat {
        item.height * (1.5 - min(max(item.top, 0), 1))
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
