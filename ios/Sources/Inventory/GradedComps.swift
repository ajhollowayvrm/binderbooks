import Foundation

/// Reads over `OwnedCard.gradedCompCents`. The keys are the grade as
/// printed with the grader in front: "PSA 10", "CGC Pristine 10". The
/// imported ledger left bare grades ("10", "9.5") with no grader; those
/// belong to no grader and never make a range.
enum GradedComps {
    static let psaGrades = ["PSA 10", "PSA 9", "PSA 8"]
    static let cgcGrades = ["CGC Pristine 10", "CGC 10", "CGC 9", "CGC 8"]

    /// The graders the app knows, in the order they show.
    static let graders = ["psa", "cgc"]

    /// Every comp for one grader, in cents.
    static func values(for grader: String, in comps: [String: Int]) -> [Int] {
        let prefix = grader.lowercased() + " "
        return comps.compactMap { key, cents in
            key.lowercased().hasPrefix(prefix) ? cents : nil
        }
    }

    /// Lowest to highest comp for the grader, or nil when he entered none.
    static func range(for grader: String, in comps: [String: Int]) -> ClosedRange<Int>? {
        let values = values(for: grader, in: comps)
        guard let low = values.min(), let high = values.max() else { return nil }
        return low...high
    }

    /// The comps key for a grade a card actually carries: "cgc" and
    /// "Pristine 10" name the "CGC Pristine 10" figure.
    static func compKey(grader: String, grade: String) -> String {
        "\(grader.uppercased()) \(grade)"
    }

    /// What the card is worth at the grade it came back at, if he has a
    /// figure for it. This is the realized value, not a projection.
    static func value(grader: String?, grade: String?, in comps: [String: Int]) -> Int? {
        guard let grader, let grade else { return nil }
        let wanted = TagKey.of(compKey(grader: grader, grade: grade))
        return comps.first { TagKey.of($0.key) == wanted }?.value
    }

    /// The grader a card is out at, read from its labels. "at PSA" is psa.
    static func graderAtGrader(tags: [String]) -> String? {
        for tag in tags {
            let key = TagKey.of(tag)
            for grader in graders where key == TagKey.of(ReservedTag.atGrader(grader)) {
                return grader
            }
        }
        return nil
    }

    /// The number in a key, for sorting: "CGC Pristine 10" is 10, "9.5" is 9.5.
    static func gradeNumber(_ label: String) -> Double? {
        label.split(whereSeparator: \.isWhitespace).reversed().lazy.compactMap { Double($0) }.first
    }

    /// "$40.00–$120.00", or one figure when the comps agree.
    static func rangeText(_ range: ClosedRange<Int>) -> String {
        range.lowerBound == range.upperBound
            ? range.lowerBound.asCurrency
            : "\(range.lowerBound.asCurrency)–\(range.upperBound.asCurrency)"
    }
}
