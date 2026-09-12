import Foundation
import SwiftData

/// Fixes a submission recorded against the wrong grader.
///
/// The grader lives in three places, and a fix that changes one leaves the
/// other two wrong. The submission names it for the ledger. A card still out
/// carries "at PSA" or "at CGC", and the Summary tab's projection reads the
/// grader from that label. A card that came back carries `graderRaw` on its
/// slab, which the return sheet copied from the submission.
///
/// His comps stay where they are. A figure he typed as "PSA 10" is a PSA price,
/// and it is not a CGC 10 price.
@MainActor
enum GraderCorrection {
    static func change(_ submission: GradingSubmission, to grader: String, context: ModelContext) {
        let new = grader.lowercased().trimmingCharacters(in: .whitespaces)
        let old = submission.graderRaw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { return }

        submission.graderRaw = new
        let editor = CardTagEditor(context: context)
        for card in submission.entries.compactMap(\.card) {
            if ReservedTag.allAtGrader.contains(where: { CardTagIndex.has($0, on: card) }) {
                for label in ReservedTag.allAtGrader { editor.remove(label, from: [card]) }
                editor.add(ReservedTag.atGrader(new), to: [card])
            }
            // Only the slab this submission labelled. A card marked graded by
            // hand, with another grader, is a separate fact.
            if card.graderRaw?.lowercased() == old {
                card.graderRaw = new
            }
        }
        try? context.save()
    }
}
