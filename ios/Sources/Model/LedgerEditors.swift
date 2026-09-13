import Foundation
import SwiftData

/// The edits to a grading charge after it is on the books. The grader has its
/// own rule, `GraderCorrection`, because a new grader moves the cards with it.
@MainActor
enum GradingEditor {
    /// What the edit sheet changes.
    struct Details: Equatable {
        var submissionNumber: String
        var serviceLevel: String
        var declaredValueCents: Int
        var shippedAt: Date?
        var returnedAt: Date?
        var gradingFeesCents: Int
        var shipToGraderCents: Int
        var shipReturnCents: Int
        var insuranceCents: Int

        init(_ submission: GradingSubmission) {
            submissionNumber = submission.submissionNumber
            serviceLevel = submission.serviceLevel
            declaredValueCents = submission.declaredValueCents
            shippedAt = submission.shippedAt
            returnedAt = submission.returnedAt
            gradingFeesCents = submission.gradingFeesCents
            shipToGraderCents = submission.shipToGraderCents
            shipReturnCents = submission.shipReturnCents
            insuranceCents = submission.insuranceCents
        }

        var totalCostCents: Int {
            gradingFeesCents + shipToGraderCents + shipReturnCents + insuranceCents
        }
    }

    /// A new total splits again over the cards, and each card takes its share
    /// at once, as a send does. The split runs only when the total changes,
    /// so a new submission number does not overwrite a grading cost typed on
    /// a card.
    static func apply(_ details: Details, to submission: GradingSubmission, context: ModelContext) throws {
        let totalChanged = details.totalCostCents != submission.totalCostCents
        submission.submissionNumber = details.submissionNumber.trimmingCharacters(in: .whitespaces)
        submission.serviceLevel = details.serviceLevel.trimmingCharacters(in: .whitespaces)
        submission.declaredValueCents = details.declaredValueCents
        submission.shippedAt = details.shippedAt
        submission.returnedAt = details.returnedAt
        submission.gradingFeesCents = details.gradingFeesCents
        submission.shipToGraderCents = details.shipToGraderCents
        submission.shipReturnCents = details.shipReturnCents
        submission.insuranceCents = details.insuranceCents
        if totalChanged, !submission.entries.isEmpty {
            Allocation.allocate(submission)
            Allocation.capitalise(submission)
        }
        try context.save()
    }
}

/// The edits to a business expense after it is on the books.
@MainActor
enum ExpenseEditor {
    struct Details: Equatable {
        var date: Date
        var vendor: String
        var category: String
        var amountCents: Int
        var note: String

        init(_ expense: BusinessExpense) {
            date = expense.date
            vendor = expense.vendor
            category = expense.category
            amountCents = expense.amountCents
            note = expense.note
        }
    }

    static func apply(_ details: Details, to expense: BusinessExpense, context: ModelContext) throws {
        expense.date = details.date
        expense.vendor = details.vendor.trimmingCharacters(in: .whitespaces)
        expense.category = details.category.trimmingCharacters(in: .whitespaces)
        expense.amountCents = details.amountCents
        expense.note = details.note.trimmingCharacters(in: .whitespaces)
        try context.save()
    }
}
