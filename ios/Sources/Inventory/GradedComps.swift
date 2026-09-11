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

    /// The best figure he has for that grader at that grade number.
    ///
    /// "CGC Pristine 10" and "CGC 10" are both grade 10, so the better of the
    /// two wins. That is what "everything 10s or Pristines" means, and it is why
    /// this matches on the parsed number rather than on a key from `cgcGrades`:
    /// no card in his store carries a "CGC Pristine 10" figure, so a lookup
    /// keyed on the head of that ladder would answer nil for every CGC card.
    ///
    /// Nil when he has entered nothing at that grade. A caller must count that
    /// card as unpriced, never fall back to the raw print's price — a slab
    /// projection and an ungraded catalogue price are not the same number.
    static func value(at grade: Double, for grader: String, in comps: [String: Int]) -> Int? {
        let prefix = grader.lowercased() + " "
        return comps.compactMap { key, cents -> Int? in
            guard key.lowercased().hasPrefix(prefix), gradeNumber(key) == grade else { return nil }
            return cents
        }.max()
    }

    /// His lowest figure for that grader, whatever grade it hangs off. The
    /// worst case he has actually priced.
    static func lowest(for grader: String, in comps: [String: Int]) -> Int? {
        values(for: grader, in: comps).min()
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
