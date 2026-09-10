import Foundation

/// The parts of a collector number the scanner and the search match on.
/// Mirrors `parse_number` in catalog/build_catalog.py. Keep the two in step.
struct CollectorNumber: Equatable, Sendable {
    var numberNum: Int?
    var setTotal: Int?
    var setCode: String?

    var isEmpty: Bool { numberNum == nil && setCode == nil }

    private static let numSlashNum = #/^(\d+)\s*/\s*(\d+)\b/#
    private static let numSlashCode = #/^(\d+)\s*/\s*([A-Za-z][A-Za-z0-9\-]*)$/#
    private static let codeSlashTail = #/^([A-Za-z0-9]+)/(.+)$/#
    private static let codeDashNum = #/^([A-Za-z]+\d*[A-Za-z]*)-(\d+)/#
    private static let codeNum = #/^([A-Za-z]+)\s*(\d+)[a-z]?$/#
    private static let bareNum = #/^(\d+)$/#
    private static let trailingDigits = #/(\d+)\s*$/#

    static func parse(_ raw: String?) -> CollectorNumber {
        guard let raw else { return CollectorNumber() }
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return CollectorNumber() }

        if let m = text.firstMatch(of: numSlashNum) {
            return CollectorNumber(numberNum: Int(m.1), setTotal: Int(m.2))
        }
        if let m = text.wholeMatch(of: numSlashCode) {
            return CollectorNumber(numberNum: Int(m.1), setCode: m.2.uppercased())
        }
        if let m = text.wholeMatch(of: codeSlashTail) {
            let tail = String(m.2)
            let num = tail.firstMatch(of: trailingDigits).flatMap { Int($0.1) }
            return CollectorNumber(numberNum: num, setCode: m.1.uppercased())
        }
        if let m = text.firstMatch(of: codeDashNum) {
            return CollectorNumber(numberNum: Int(m.2), setCode: m.1.uppercased())
        }
        if let m = text.wholeMatch(of: codeNum) {
            return CollectorNumber(numberNum: Int(m.2), setCode: m.1.uppercased())
        }
        if let m = text.wholeMatch(of: bareNum) {
            return CollectorNumber(numberNum: Int(m.1))
        }
        return CollectorNumber()
    }

    /// True when the text reads as a collector number rather than a name.
    /// A bare integer counts only when it has three or more digits, so "ex" or
    /// "10" still search names.
    static func looksLikeNumber(_ text: String) -> Bool {
        let parsed = parse(text)
        if parsed.setTotal != nil || parsed.setCode != nil { return true }
        if let n = parsed.numberNum, text.trimmingCharacters(in: .whitespaces).count >= 3 {
            return n >= 0
        }
        return false
    }
}

enum NameCleaner {
    /// Lowercase, no diacritics, no punctuation, single spaces.
    /// Mirrors `clean_name` in catalog/build_catalog.py.
    static func clean(_ name: String) -> String {
        let decomposed = name.replacingOccurrences(of: "&", with: " and ").decomposedStringWithCompatibilityMapping
        var out = ""
        out.reserveCapacity(decomposed.count)
        var lastWasSpace = true
        for scalar in decomposed.unicodeScalars {
            let props = scalar.properties
            switch props.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                continue
            default:
                break
            }
            let keep = props.isAlphabetic || props.numericType != nil || scalar == "_"
            if keep {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
