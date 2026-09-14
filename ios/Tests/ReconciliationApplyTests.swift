import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// Applies the purchase reconciliation of 2026-09-13 to his phone backup and
/// writes a corrected collection file for a Replace import.
///
/// Runs only when `build/corrections/plan.json` is on the Mac. `build/` is never
/// committed: the plan and the backup hold his real purchases.
///
/// Every change goes through the app's own code, so a changed total splits over
/// the cards the way the purchase editor splits it on the phone.
@Suite struct ReconciliationApplyTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let planURL = root.appendingPathComponent("build/corrections/plan.json")

    struct Plan: Decodable {
        struct Update: Decodable { var id: UUID; var date: Double; var vendor: String; var itemCostCents: Int; var why: String }
        struct Removal: Decodable { var id: UUID; var why: String }
        struct Move: Decodable { var fromId: UUID; var toId: UUID; var why: String }
        struct Addition: Decodable { var id: UUID; var date: Double; var vendor: String; var note: String; var itemCostCents: Int; var sourceRef: String }
        struct Expense: Decodable { var id: UUID; var date: Double; var category: String; var vendor: String; var amountCents: Int; var note: String }
        struct Note: Decodable { var id: UUID; var append: String }
        var backup: String
        var updates: [Update]
        var removals: [Removal]
        var moves: [Move]
        var additions: [Addition]
        var expenses: [Expense]
        var notes: [Note]
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: planURL.path)))
    @MainActor func applyThePlanToHisBackup() throws {
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: Self.planURL))
        let backup = try CollectionExport.decode(Data(contentsOf: Self.root.appendingPathComponent(plan.backup)))

        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext
        try CollectionExport.apply(backup, to: context, mode: .replace)

        func purchase(_ id: UUID) throws -> Purchase {
            try #require(try context.fetch(FetchDescriptor<Purchase>(predicate: #Predicate { $0.id == id })).first, "no purchase \(id)")
        }
        func cardCost(_ p: Purchase) -> Int { p.items.flatMap(\.cards).reduce(0) { $0 + $1.acquisitionBasisCents } }
        func money(_ cents: Int) -> String { String(format: "%.2f", Double(cents) / 100) }
        let day = Date.FormatStyle(date: .numeric, time: .omitted, timeZone: TimeZone(identifier: "UTC")!)

        let cardsBefore = try context.fetchCount(FetchDescriptor<OwnedCard>())
        let salesBefore = try context.fetchCount(FetchDescriptor<Sale>())
        let linesBefore = try context.fetchCount(FetchDescriptor<SaleLine>())
        let gradingBefore = try context.fetchCount(FetchDescriptor<GradingSubmission>())
        let purchasesBefore = try context.fetch(FetchDescriptor<Purchase>())
        let totalBefore = purchasesBefore.reduce(0) { $0 + $1.landedCostCents }
        var report: [String] = []

        for update in plan.updates {
            let p = try purchase(update.id)
            let before = "\(p.date.formatted(day)) \(p.vendor) \(money(p.landedCostCents)) cards \(money(cardCost(p)))"
            var details = PurchaseEditor.Details(p)
            details.date = Date(timeIntervalSinceReferenceDate: update.date)
            details.vendor = update.vendor
            details.itemCostCents = update.itemCostCents
            try PurchaseEditor.apply(details, to: p, context: context)
            report.append("UPDATE \(before) -> \(p.date.formatted(day)) \(p.vendor) \(money(p.landedCostCents)) cards \(money(cardCost(p))) | \(update.why)")
        }

        for move in plan.moves {
            let from = try purchase(move.fromId)
            let to = try purchase(move.toId)
            let moved = from.items.flatMap(\.cards).count
            for item in from.items { item.purchase = to }
            try context.save()
            PurchaseEditor.resplitIfSafe(to)
            #expect(from.items.isEmpty)
            context.delete(from)
            try context.save()
            report.append("MOVE \(moved) cards to \(to.date.formatted(day)) \(to.vendor) \(money(to.landedCostCents)), cards now \(to.items.flatMap(\.cards).count) costing \(money(cardCost(to))) | \(move.why)")
        }

        for note in plan.notes {
            let p = try purchase(note.id)
            p.note += note.append
            report.append("NOTE \(p.date.formatted(day)) \(p.vendor) \(money(p.landedCostCents)) \(p.note)")
        }

        for removal in plan.removals {
            let p = try purchase(removal.id)
            // Deleting a purchase deletes its cards. The plan removes only empty ones.
            try #require(p.items.flatMap(\.cards).isEmpty, "purchase \(removal.id) still has cards")
            report.append("REMOVE \(p.date.formatted(day)) \(p.vendor) \(money(p.landedCostCents)) \(p.note) | \(removal.why)")
            context.delete(p)
        }

        for addition in plan.additions {
            let p = Purchase(date: Date(timeIntervalSinceReferenceDate: addition.date), vendor: addition.vendor, note: addition.note, itemCostCents: addition.itemCostCents)
            p.id = addition.id
            p.sourceRef = addition.sourceRef
            context.insert(p)
            report.append("ADD \(p.date.formatted(day)) \(p.vendor) \(money(p.landedCostCents)) \(p.note)")
        }

        for expense in plan.expenses {
            let e = BusinessExpense(date: Date(timeIntervalSinceReferenceDate: expense.date), category: expense.category, vendor: expense.vendor, amountCents: expense.amountCents, note: expense.note)
            e.id = expense.id
            context.insert(e)
            report.append("EXPENSE \(e.date.formatted(day)) \(e.vendor) \(money(e.amountCents)) \(e.note)")
        }
        try context.save()

        // Nothing but purchases may change.
        #expect(try context.fetchCount(FetchDescriptor<OwnedCard>()) == cardsBefore)
        #expect(try context.fetchCount(FetchDescriptor<Sale>()) == salesBefore)
        #expect(try context.fetchCount(FetchDescriptor<SaleLine>()) == linesBefore)
        #expect(try context.fetchCount(FetchDescriptor<GradingSubmission>()) == gradingBefore)
        let purchasesAfter = try context.fetch(FetchDescriptor<Purchase>())
        #expect(purchasesAfter.count == purchasesBefore.count - plan.removals.count - plan.moves.count + plan.additions.count)

        let data = try CollectionExport.exportData(context)
        let roundTrip = try CollectionExport.decode(data)
        #expect(roundTrip.cards.count == cardsBefore)

        let out = Self.root.appendingPathComponent("build/corrections")
        try data.write(to: out.appendingPathComponent("card-tracker-corrected-2026-09-13.json"))
        let totalAfter = purchasesAfter.reduce(0) { $0 + $1.landedCostCents }
        report.insert("purchases \(purchasesBefore.count) -> \(purchasesAfter.count); purchase total \(money(totalBefore)) -> \(money(totalAfter)); cards \(cardsBefore) -> \(roundTrip.cards.count); sales \(salesBefore); grading \(gradingBefore)", at: 0)
        try report.joined(separator: "\n").write(to: out.appendingPathComponent("apply-report.txt"), atomically: true, encoding: .utf8)
    }
}
