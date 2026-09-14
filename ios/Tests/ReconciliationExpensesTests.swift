import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// The second pass of the 2026-09-13 reconciliation: it puts back two purchases
/// the first pass removed by mistake, corrects grading to what the graders
/// charged, puts real postage on sales, and adds business expenses.
///
/// Runs only when `build/corrections2/plan.json` is on the Mac. `build/` is
/// never committed. Every change goes through the app's own editors, except
/// postage on an estimated sale: `SaleEditor` clears the estimate flag, and the
/// fees on those sales are still estimates.
@Suite struct ReconciliationExpensesTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let planURL = root.appendingPathComponent("build/corrections2/plan.json")

    struct Plan: Decodable {
        struct Restore: Decodable { var purchase: CollectionExport.PurchaseDTO; var items: [CollectionExport.PurchaseItemDTO]; var why: String }
        struct Move: Decodable { var itemIds: [UUID]; var toId: UUID; var resplitIds: [UUID]; var why: String }
        struct Update: Decodable { var id: UUID; var date: Double; var vendor: String; var note: String; var itemCostCents: Int; var why: String }
        struct Removal: Decodable { var id: UUID; var why: String }
        struct Addition: Decodable { var id: UUID; var date: Double; var vendor: String; var note: String; var itemCostCents: Int; var sourceRef: String }
        struct Grading: Decodable { var id: UUID; var submissionNumber: String; var serviceLevel: String; var feesCents: Int; var shipToGraderCents: Int; var shipReturnCents: Int; var insuranceCents: Int; var why: String }
        struct NewGrading: Decodable { var id: UUID; var grader: String; var submissionNumber: String; var serviceLevel: String; var shippedAt: Double; var feesCents: Int; var shipToGraderCents: Int; var shipReturnCents: Int; var insuranceCents: Int; var sourceRef: String }
        struct SaleShipping: Decodable { var saleId: UUID; var old: Int; var new: Int; var why: String }
        struct Expense: Decodable { var id: UUID; var date: Double; var category: String; var vendor: String; var amountCents: Int; var note: String }
        var backup: String
        var restores: [Restore]
        var moves: [Move]
        var updates: [Update]
        var removals: [Removal]
        var additions: [Addition]
        var grading: [Grading]
        var newGrading: [NewGrading]
        var sales: [SaleShipping]
        var expenses: [Expense]
        struct NewItem: Decodable { var id: UUID; var purchaseId: UUID; var productId: Int; var quantity: Int; var isSealed: Bool; var isRipped: Bool }
        struct LineMove: Decodable { var newItem: NewItem; var cardIds: [UUID]; var why: String }
        struct ItemDelete: Decodable { var id: UUID; var why: String }
        struct LineReassign: Decodable { var itemId: UUID; var purchaseId: UUID; var productId: Int; var quantity: Int; var why: String }
        var lineMoves: [LineMove]
        var itemDeletes: [ItemDelete]
        var lineReassigns: [LineReassign]
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: planURL.path)))
    @MainActor func applyTheSecondPlan() throws {
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: Self.planURL))
        let backup = try CollectionExport.decode(Data(contentsOf: Self.root.appendingPathComponent(plan.backup)))
        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext
        try CollectionExport.apply(backup, to: context, mode: .replace)

        func one<T: PersistentModel>(_ type: T.Type, _ predicate: Predicate<T>, _ what: String) throws -> T {
            try #require(try context.fetch(FetchDescriptor<T>(predicate: predicate)).first, "no \(what)")
        }
        func purchase(_ id: UUID) throws -> Purchase { try one(Purchase.self, #Predicate { $0.id == id }, "purchase \(id)") }
        func money(_ cents: Int) -> String { String(format: "%.2f", Double(cents) / 100) }
        func cardCost(_ p: Purchase) -> Int { p.items.flatMap(\.cards).reduce(0) { $0 + $1.acquisitionBasisCents } }
        let day = Date.FormatStyle(date: .numeric, time: .omitted, timeZone: TimeZone(identifier: "UTC")!)

        let cardsBefore = try context.fetchCount(FetchDescriptor<OwnedCard>())
        let salesBefore = try context.fetchCount(FetchDescriptor<Sale>())
        let linesBefore = try context.fetchCount(FetchDescriptor<SaleLine>())
        let gradingBefore = try context.fetchCount(FetchDescriptor<GradingSubmission>())
        let expensesBefore = try context.fetchCount(FetchDescriptor<BusinessExpense>())
        let purchasesBefore = try context.fetchCount(FetchDescriptor<Purchase>())
        var report: [String] = []

        for restore in plan.restores {
            let dto = restore.purchase
            let p = Purchase(date: dto.date, vendor: dto.vendor, note: dto.note, itemCostCents: dto.itemCostCents, shippingCents: dto.shippingCents, taxCents: dto.taxCents, feesCents: dto.feesCents)
            p.id = dto.id
            p.allocationMethodRaw = dto.allocationMethodRaw
            p.sourceRef = dto.sourceRef ?? ""
            context.insert(p)
            for itemDTO in restore.items {
                let item = PurchaseItem(productId: itemDTO.productId, quantity: itemDTO.quantity, isSealed: itemDTO.isSealed)
                item.id = itemDTO.id
                item.allocatedCostCents = itemDTO.allocatedCostCents
                item.isRipped = itemDTO.isRipped
                context.insert(item)
                item.purchase = p
            }
            report.append("RESTORE \(p.date.formatted(day)) \(p.vendor) \(money(p.landedCostCents)) \(p.note) | \(restore.why)")
        }
        try context.save()

        for move in plan.moves {
            let to = try purchase(move.toId)
            for itemId in move.itemIds {
                let item = try one(PurchaseItem.self, #Predicate { $0.id == itemId }, "item \(itemId)")
                item.purchase = to
            }
            try context.save()
            for id in move.resplitIds {
                let p = try purchase(id)
                PurchaseEditor.resplitIfSafe(p)
                report.append("MOVE/RESPLIT \(p.date.formatted(day)) \(p.vendor) \(money(p.landedCostCents)): \(p.items.flatMap(\.cards).count) cards costing \(money(cardCost(p))) | \(move.why)")
            }
            try context.save()
        }

        for move in plan.lineMoves {
            let p = try purchase(move.newItem.purchaseId)
            let item = PurchaseItem(productId: move.newItem.productId, quantity: move.newItem.quantity, isSealed: move.newItem.isSealed)
            item.id = move.newItem.id
            item.isRipped = move.newItem.isRipped
            context.insert(item)
            item.purchase = p
            for cardId in move.cardIds {
                let card = try one(OwnedCard.self, #Predicate { $0.id == cardId }, "card \(cardId)")
                card.sourceItem = item
                // These pulls never took a split: no cost and no flag. Without the
                // flag the purchase editor will not split onto them.
                if card.acquisitionBasisCents == 0, !card.basisIsManual, !card.isBulk {
                    card.basisIsAllocated = true
                }
            }
            try context.save()
            let resplit = PurchaseEditor.resplitIfSafe(p)
            try context.save()
            report.append("LINE \(p.date.formatted(day)) \(p.vendor) \(money(p.landedCostCents)): \(move.cardIds.count) cards moved, split again \(resplit), cards now cost \(money(cardCost(p))) | \(move.why)")
        }

        // A line a scan session rips from must not be deleted: the session would
        // point at nothing. Such a line moves to its real purchase instead.
        for reassign in plan.lineReassigns {
            let itemId = reassign.itemId
            let item = try one(PurchaseItem.self, #Predicate { $0.id == itemId }, "item \(itemId)")
            let p = try purchase(reassign.purchaseId)
            item.purchase = p
            item.productId = reassign.productId
            item.quantity = reassign.quantity
            for card in item.cards where card.acquisitionBasisCents == 0 && !card.basisIsManual && !card.isBulk {
                card.basisIsAllocated = true
            }
            try context.save()
            let resplit = PurchaseEditor.resplitIfSafe(p)
            try context.save()
            report.append("LINE \(p.date.formatted(day)) \(p.vendor) \(money(p.landedCostCents)): line \(itemId) moved here with \(item.cards.count) cards, split again \(resplit), cards now cost \(money(cardCost(p))) | \(reassign.why)")
        }

        for delete in plan.itemDeletes {
            let id = delete.id
            let item = try one(PurchaseItem.self, #Predicate { $0.id == id }, "item \(id)")
            // A line owns its cards. Delete it only when nothing is left on it.
            try #require(item.cards.isEmpty, "item \(id) still has cards")
            context.delete(item)
            try context.save()
            report.append("DELETE LINE \(id) | \(delete.why)")
        }

        for update in plan.updates {
            let p = try purchase(update.id)
            let before = "\(p.date.formatted(day)) \(p.vendor) \(money(p.landedCostCents))"
            var details = PurchaseEditor.Details(p)
            details.date = Date(timeIntervalSinceReferenceDate: update.date)
            details.vendor = update.vendor
            details.note = update.note
            details.itemCostCents = update.itemCostCents
            try PurchaseEditor.apply(details, to: p, context: context)
            report.append("UPDATE \(before) -> \(p.date.formatted(day)) \(p.vendor) \(money(p.landedCostCents)) \(p.note) | \(update.why)")
        }

        for removal in plan.removals {
            let p = try purchase(removal.id)
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
        try context.save()

        for change in plan.grading {
            let id = change.id
            let submission = try one(GradingSubmission.self, #Predicate { $0.id == id }, "submission \(id)")
            let before = "\(submission.graderRaw) \(submission.submissionNumber) \(money(submission.totalCostCents)), cards \(money(submission.entries.compactMap(\.card).reduce(0) { $0 + $1.gradingBasisCents }))"
            var details = GradingEditor.Details(submission)
            details.submissionNumber = change.submissionNumber
            if !change.serviceLevel.isEmpty { details.serviceLevel = change.serviceLevel }
            details.gradingFeesCents = change.feesCents
            details.shipToGraderCents = change.shipToGraderCents
            details.shipReturnCents = change.shipReturnCents
            details.insuranceCents = change.insuranceCents
            try GradingEditor.apply(details, to: submission, context: context)
            let after = submission.entries.compactMap(\.card).reduce(0) { $0 + $1.gradingBasisCents }
            report.append("GRADING \(before) -> \(submission.submissionNumber) \(money(submission.totalCostCents)), cards \(money(after)) | \(change.why)")
        }

        for new in plan.newGrading {
            let submission = GradingSubmission(graderRaw: new.grader, shippedAt: Date(timeIntervalSinceReferenceDate: new.shippedAt), gradingFeesCents: new.feesCents)
            submission.id = new.id
            submission.submissionNumber = new.submissionNumber
            submission.serviceLevel = new.serviceLevel
            submission.shipToGraderCents = new.shipToGraderCents
            submission.shipReturnCents = new.shipReturnCents
            submission.insuranceCents = new.insuranceCents
            submission.sourceRef = new.sourceRef
            context.insert(submission)
            report.append("NEW GRADING \(new.grader) \(new.submissionNumber) \(money(submission.totalCostCents))")
        }
        try context.save()

        for change in plan.sales {
            let id = change.saleId
            let sale = try one(Sale.self, #Predicate { $0.id == id }, "sale \(id)")
            #expect(sale.shippingCostCents == change.old, "sale \(id) postage moved since the backup")
            if sale.costsEstimated {
                sale.shippingCostCents = change.new
            } else {
                var details = SaleEditor.Details(sale)
                details.shippingCostCents = change.new
                try SaleEditor.apply(details, to: sale, context: context)
            }
            report.append("POSTAGE \(sale.soldAt.formatted(day)) \(sale.channelRaw) \(money(change.old)) -> \(money(sale.shippingCostCents)) estimated=\(sale.costsEstimated) | \(change.why)")
        }

        for expense in plan.expenses {
            let e = BusinessExpense(date: Date(timeIntervalSinceReferenceDate: expense.date), category: expense.category, vendor: expense.vendor, amountCents: expense.amountCents, note: expense.note)
            e.id = expense.id
            context.insert(e)
            report.append("EXPENSE \(e.date.formatted(day)) \(e.category) \(e.vendor) \(money(e.amountCents)) \(e.note)")
        }
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<OwnedCard>()) == cardsBefore)
        #expect(try context.fetchCount(FetchDescriptor<Sale>()) == salesBefore)
        #expect(try context.fetchCount(FetchDescriptor<SaleLine>()) == linesBefore)
        #expect(try context.fetchCount(FetchDescriptor<GradingSubmission>()) == gradingBefore + plan.newGrading.count)
        #expect(try context.fetchCount(FetchDescriptor<BusinessExpense>()) == expensesBefore + plan.expenses.count)
        let purchases = try context.fetch(FetchDescriptor<Purchase>())
        #expect(purchases.count == purchasesBefore + plan.restores.count + plan.additions.count - plan.removals.count)

        let data = try CollectionExport.exportData(context)
        let roundTrip = try CollectionExport.decode(data)
        #expect(roundTrip.cards.count == cardsBefore)
        let out = Self.root.appendingPathComponent("build/corrections2")
        try data.write(to: out.appendingPathComponent("card-tracker-corrected2-2026-09-13.json"))
        let expenses = try context.fetch(FetchDescriptor<BusinessExpense>())
        let grading = try context.fetch(FetchDescriptor<GradingSubmission>())
        report.insert("purchases \(purchasesBefore) -> \(purchases.count), total \(money(purchases.reduce(0) { $0 + $1.landedCostCents })); grading \(grading.count), total \(money(grading.reduce(0) { $0 + $1.totalCostCents })); expenses \(expenses.count), total \(money(expenses.reduce(0) { $0 + $1.amountCents })); cards \(roundTrip.cards.count); sales \(salesBefore)", at: 0)
        try report.joined(separator: "\n").write(to: out.appendingPathComponent("apply-report.txt"), atomically: true, encoding: .utf8)
    }
}
