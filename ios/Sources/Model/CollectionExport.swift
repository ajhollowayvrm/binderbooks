import Foundation
import SwiftData

/// JSON export and import of the whole collection store.
///
/// There is no sync and no cloud backup. This file is the only thing between
/// him and total loss, so it must be complete, and import must round-trip its
/// own output exactly. Relationships travel as UUIDs. Dates travel as seconds
/// since the reference date, which JSON doubles reproduce exactly. Arrays are
/// sorted by id so two exports of the same store are byte-identical.
enum CollectionExport {
    static let format = "cardtracker-collection"
    /// Version 2 added `OwnedCardDTO.tags` and `basisIsManual`. Version 3 added
    /// rips, grading, sales, and the `sourceRef` that ties an imported row back
    /// to the BinderBooks ledger. Version 4 removed the rip: opening a pack is
    /// an intake path, not a record. A version 3 file still imports and its
    /// `rips` array is ignored, because `JSONDecoder` drops a key the struct
    /// does not declare. The gate is `file.version <= version`.
    /// Version 5 added business expenses. Version 6 added `OwnedCardDTO.isSealedSelf`
    /// and `ScanSessionDTO.ripTargetId`, for ripping one sealed item from
    /// inventory directly instead of opening its whole purchase.
    static let version = 6

    struct File: Codable, Equatable {
        var format: String = CollectionExport.format
        var version: Int = CollectionExport.version
        var exportedAt: String
        var purchases: [PurchaseDTO]
        var purchaseItems: [PurchaseItemDTO]
        var cards: [OwnedCardDTO]
        var sessions: [ScanSessionDTO]
        /// Optional, like `OwnedCardDTO.tags`: the synthesised decoder throws
        /// `keyNotFound` for a non-optional property, so a version 2 file would
        /// stop importing the day these arrived.
        var grading: [GradingSubmissionDTO]?
        var gradingEntries: [GradingEntryDTO]?
        var sales: [SaleDTO]?
        var saleLines: [SaleLineDTO]?
        var expenses: [BusinessExpenseDTO]?

        var counts: String {
            var parts = ["\(purchases.count) purchases", "\(purchaseItems.count) lines", "\(cards.count) cards", "\(sessions.count) sessions"]
            if let grading, !grading.isEmpty { parts.append("\(grading.count) submissions") }
            if let sales, !sales.isEmpty { parts.append("\(sales.count) sales") }
            if let expenses, !expenses.isEmpty { parts.append("\(expenses.count) expenses") }
            return parts.joined(separator: ", ")
        }
    }

    struct PurchaseDTO: Codable, Equatable {
        var id: UUID
        var date: Date
        var vendor: String
        var note: String
        var receiptImageData: Data?
        var itemCostCents: Int
        var shippingCents: Int
        var taxCents: Int
        var feesCents: Int
        var allocationMethodRaw: String
        var sourceRef: String?
    }

    struct PurchaseItemDTO: Codable, Equatable {
        var id: UUID
        var productId: Int
        var quantity: Int
        var isSealed: Bool
        var allocatedCostCents: Int
        var purchaseId: UUID?
        var parentItemId: UUID?
        var identifiedGroupId: Int?
        var isRipped: Bool
    }

    struct OwnedCardDTO: Codable, Equatable {
        var id: UUID
        var productId: Int
        var skuId: Int?
        var printing: String
        var condition: String
        var language: String
        var quantity: Int
        var acquiredAt: Date
        var statusRaw: String
        var acquisitionBasisCents: Int
        var gradingBasisCents: Int
        var basisIsAllocated: Bool
        /// Optional, like `tags`, so a file written before review pricing
        /// still decodes.
        var basisIsManual: Bool?
        var isBulk: Bool
        var isPersonalCollection: Bool
        var sourceItemId: UUID?
        var scanSessionId: UUID?
        var matchConfidenceRaw: String
        var certNumber: String?
        var graderRaw: String?
        var gradeLabel: String?
        var ocrName: String?
        var ocrNumber: String?
        var candidateProductIds: [Int]
        var scannedAt: Date
        var gradedCompCents: [String: Int]?
        var fetchedCompCents: [String: Int]?
        var compsFetchedAt: Date?
        var sourceRef: String?
        /// Optional on purpose. The synthesised decoder calls `decode` for a
        /// non-optional property and throws `keyNotFound`, so a non-optional
        /// field would make every file written before tags unimportable.
        var tags: [String]?
        /// Optional, like `tags`: added in version 6, for the self-card that
        /// stands for an unopened sealed item.
        var isSealedSelf: Bool?
    }

    struct GradingSubmissionDTO: Codable, Equatable {
        var id: UUID
        var graderRaw: String
        var submissionNumber: String
        var serviceLevel: String
        var declaredValueCents: Int
        var shippedAt: Date?
        var returnedAt: Date?
        var gradingFeesCents: Int
        var shipToGraderCents: Int
        var shipReturnCents: Int
        var insuranceCents: Int
        var sourceRef: String?
    }

    struct GradingEntryDTO: Codable, Equatable {
        var id: UUID
        var submissionId: UUID?
        var cardId: UUID?
        var grade: Double?
        var certNumber: String
        var allocatedFeeCents: Int
        var noGrade: Bool
    }

    struct SaleDTO: Codable, Equatable {
        var id: UUID
        var soldAt: Date
        var channelRaw: String
        var grossCents: Int
        var marketplaceFeesCents: Int
        var salesTaxCents: Int
        var shippingChargedCents: Int
        var shippingCostCents: Int
        var otherFeesCents: Int
        var externalOrderId: String
        var sourceRef: String?
    }

    struct SaleLineDTO: Codable, Equatable {
        var id: UUID
        var saleId: UUID?
        var cardId: UUID?
        var sealedItemId: UUID?
        var basisCents: Int
        var basisIncomplete: Bool
        var describedAs: String
        var sourceRef: String?
    }

    struct BusinessExpenseDTO: Codable, Equatable {
        var id: UUID
        var date: Date
        var category: String
        var vendor: String
        var amountCents: Int
        var note: String
        var sourceRef: String?
    }

    struct ScanSessionDTO: Codable, Equatable {
        var id: UUID
        var startedAt: Date
        var committedAt: Date?
        var defaultCondition: String
        var defaultPrinting: String?
        var purchaseId: UUID?
        var observedGroupIds: [Int]
        /// Optional, like `OwnedCardDTO.isSealedSelf`: added in version 6.
        var ripTargetId: UUID?
    }

    enum ImportError: LocalizedError {
        case wrongFormat(String)
        case newerVersion(Int)

        var errorDescription: String? {
            switch self {
            case .wrongFormat(let f): return "This is not a Card Tracker export. Format: \(f)."
            case .newerVersion(let v): return "This export is version \(v). This app reads version \(CollectionExport.version). Update the app."
            }
        }
    }

    enum Mode {
        /// Update rows with matching ids, insert the rest, keep everything else.
        case merge
        /// Delete the store first. The file becomes the whole collection.
        case replace
    }

    struct Report: Equatable {
        var purchases = 0
        var purchaseItems = 0
        var cards = 0
        var sessions = 0
        var grading = 0
        var gradingEntries = 0
        var sales = 0
        var saleLines = 0
        var expenses = 0
        var deleted = 0

        /// What the import wrote, leaving out anything the file did not carry.
        var summary: String {
            var parts = ["\(purchases) purchases", "\(purchaseItems) lines", "\(cards) cards", "\(sessions) sessions"]
            if grading > 0 { parts.append("\(grading) submissions") }
            if gradingEntries > 0 { parts.append("\(gradingEntries) grading entries") }
            if sales > 0 { parts.append("\(sales) sales") }
            if saleLines > 0 { parts.append("\(saleLines) sale lines") }
            if expenses > 0 { parts.append("\(expenses) expenses") }
            return parts.joined(separator: ", ") + ". \(deleted) rows deleted first."
        }
    }

    // MARK: - Export

    @MainActor
    static func snapshot(_ context: ModelContext, now: Date = Date()) throws -> File {
        let purchases = try context.fetch(FetchDescriptor<Purchase>())
        let items = try context.fetch(FetchDescriptor<PurchaseItem>())
        let cards = try context.fetch(FetchDescriptor<OwnedCard>())
        let sessions = try context.fetch(FetchDescriptor<ScanSession>())
        let grading = try context.fetch(FetchDescriptor<GradingSubmission>())
        let gradingEntries = try context.fetch(FetchDescriptor<GradingEntry>())
        let sales = try context.fetch(FetchDescriptor<Sale>())
        let saleLines = try context.fetch(FetchDescriptor<SaleLine>())
        let expenses = try context.fetch(FetchDescriptor<BusinessExpense>())

        return File(
            exportedAt: ISO8601DateFormatter().string(from: now),
            purchases: purchases.map {
                PurchaseDTO(
                    id: $0.id, date: $0.date, vendor: $0.vendor, note: $0.note, receiptImageData: $0.receiptImageData,
                    itemCostCents: $0.itemCostCents, shippingCents: $0.shippingCents, taxCents: $0.taxCents,
                    feesCents: $0.feesCents, allocationMethodRaw: $0.allocationMethodRaw, sourceRef: $0.sourceRef
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            purchaseItems: items.map {
                PurchaseItemDTO(
                    id: $0.id, productId: $0.productId, quantity: $0.quantity, isSealed: $0.isSealed,
                    allocatedCostCents: $0.allocatedCostCents, purchaseId: $0.purchase?.id, parentItemId: $0.parentItem?.id,
                    identifiedGroupId: $0.identifiedGroupId, isRipped: $0.isRipped
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            cards: cards.map {
                OwnedCardDTO(
                    id: $0.id, productId: $0.productId, skuId: $0.skuId, printing: $0.printing, condition: $0.condition,
                    language: $0.language, quantity: $0.quantity, acquiredAt: $0.acquiredAt, statusRaw: $0.statusRaw,
                    acquisitionBasisCents: $0.acquisitionBasisCents, gradingBasisCents: $0.gradingBasisCents,
                    basisIsAllocated: $0.basisIsAllocated, basisIsManual: $0.basisIsManual,
                    isBulk: $0.isBulk, isPersonalCollection: $0.isPersonalCollection,
                    sourceItemId: $0.sourceItem?.id, scanSessionId: $0.scanSession?.id, matchConfidenceRaw: $0.matchConfidenceRaw,
                    certNumber: $0.certNumber, graderRaw: $0.graderRaw, gradeLabel: $0.gradeLabel, ocrName: $0.ocrName, ocrNumber: $0.ocrNumber,
                    candidateProductIds: $0.candidateProductIds, scannedAt: $0.scannedAt,
                    gradedCompCents: $0.gradedCompCents, fetchedCompCents: $0.fetchedCompCents, compsFetchedAt: $0.compsFetchedAt, sourceRef: $0.sourceRef,
                    tags: $0.tags, isSealedSelf: $0.isSealedSelf
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            sessions: sessions.map {
                ScanSessionDTO(
                    id: $0.id, startedAt: $0.startedAt, committedAt: $0.committedAt, defaultCondition: $0.defaultCondition,
                    defaultPrinting: $0.defaultPrinting, purchaseId: $0.purchase?.id, observedGroupIds: $0.observedGroupIds,
                    ripTargetId: $0.ripTarget?.id
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            grading: grading.map {
                GradingSubmissionDTO(
                    id: $0.id, graderRaw: $0.graderRaw, submissionNumber: $0.submissionNumber, serviceLevel: $0.serviceLevel,
                    declaredValueCents: $0.declaredValueCents, shippedAt: $0.shippedAt, returnedAt: $0.returnedAt,
                    gradingFeesCents: $0.gradingFeesCents, shipToGraderCents: $0.shipToGraderCents,
                    shipReturnCents: $0.shipReturnCents, insuranceCents: $0.insuranceCents, sourceRef: $0.sourceRef
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            gradingEntries: gradingEntries.map {
                GradingEntryDTO(
                    id: $0.id, submissionId: $0.submission?.id, cardId: $0.card?.id, grade: $0.grade,
                    certNumber: $0.certNumber, allocatedFeeCents: $0.allocatedFeeCents, noGrade: $0.noGrade
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            sales: sales.map {
                SaleDTO(
                    id: $0.id, soldAt: $0.soldAt, channelRaw: $0.channelRaw, grossCents: $0.grossCents,
                    marketplaceFeesCents: $0.marketplaceFeesCents, salesTaxCents: $0.salesTaxCents,
                    shippingChargedCents: $0.shippingChargedCents, shippingCostCents: $0.shippingCostCents,
                    otherFeesCents: $0.otherFeesCents, externalOrderId: $0.externalOrderId, sourceRef: $0.sourceRef
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            saleLines: saleLines.map {
                SaleLineDTO(
                    id: $0.id, saleId: $0.sale?.id, cardId: $0.card?.id, sealedItemId: $0.sealedItem?.id,
                    basisCents: $0.basisCents, basisIncomplete: $0.basisIncomplete, describedAs: $0.describedAs,
                    sourceRef: $0.sourceRef
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            expenses: expenses.map {
                BusinessExpenseDTO(
                    id: $0.id, date: $0.date, category: $0.category, vendor: $0.vendor,
                    amountCents: $0.amountCents, note: $0.note, sourceRef: $0.sourceRef
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    static func encode(_ file: File) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    @MainActor
    static func exportData(_ context: ModelContext, now: Date = Date()) throws -> Data {
        try encode(try snapshot(context, now: now))
    }

    static func suggestedFileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "card-tracker-\(f.string(from: now)).json"
    }

    // MARK: - Import

    static func decode(_ data: Data) throws -> File {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.format == format else { throw ImportError.wrongFormat(file.format) }
        guard file.version <= version else { throw ImportError.newerVersion(file.version) }
        return file
    }

    /// Idempotent: importing the same file twice changes nothing the second time.
    @MainActor
    @discardableResult
    static func apply(_ file: File, to context: ModelContext, mode: Mode) throws -> Report {
        var report = Report()

        if mode == .replace {
            for expense in try context.fetch(FetchDescriptor<BusinessExpense>()) { context.delete(expense); report.deleted += 1 }
            for line in try context.fetch(FetchDescriptor<SaleLine>()) { context.delete(line); report.deleted += 1 }
            for sale in try context.fetch(FetchDescriptor<Sale>()) { context.delete(sale); report.deleted += 1 }
            for entry in try context.fetch(FetchDescriptor<GradingEntry>()) { context.delete(entry); report.deleted += 1 }
            for submission in try context.fetch(FetchDescriptor<GradingSubmission>()) { context.delete(submission); report.deleted += 1 }
            for card in try context.fetch(FetchDescriptor<OwnedCard>()) { context.delete(card); report.deleted += 1 }
            for item in try context.fetch(FetchDescriptor<PurchaseItem>()) { context.delete(item); report.deleted += 1 }
            for session in try context.fetch(FetchDescriptor<ScanSession>()) { context.delete(session); report.deleted += 1 }
            for purchase in try context.fetch(FetchDescriptor<Purchase>()) { context.delete(purchase); report.deleted += 1 }
            try context.save()
        }

        var purchases = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Purchase>()).map { ($0.id, $0) })
        var sessions = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ScanSession>()).map { ($0.id, $0) })
        var items = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<PurchaseItem>()).map { ($0.id, $0) })
        var cards = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<OwnedCard>()).map { ($0.id, $0) })
        var submissions = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<GradingSubmission>()).map { ($0.id, $0) })
        var entries = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<GradingEntry>()).map { ($0.id, $0) })
        var sales = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Sale>()).map { ($0.id, $0) })
        var saleLines = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<SaleLine>()).map { ($0.id, $0) })
        var expenses = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<BusinessExpense>()).map { ($0.id, $0) })

        for dto in file.purchases {
            let purchase = purchases[dto.id] ?? {
                let p = Purchase(vendor: dto.vendor, itemCostCents: dto.itemCostCents)
                p.id = dto.id
                context.insert(p)
                purchases[dto.id] = p
                return p
            }()
            purchase.date = dto.date
            purchase.vendor = dto.vendor
            purchase.note = dto.note
            purchase.receiptImageData = dto.receiptImageData
            purchase.itemCostCents = dto.itemCostCents
            purchase.shippingCents = dto.shippingCents
            purchase.taxCents = dto.taxCents
            purchase.feesCents = dto.feesCents
            purchase.allocationMethodRaw = dto.allocationMethodRaw
            purchase.sourceRef = dto.sourceRef ?? ""
            report.purchases += 1
        }

        for dto in file.sessions {
            let session = sessions[dto.id] ?? {
                let s = ScanSession()
                s.id = dto.id
                context.insert(s)
                sessions[dto.id] = s
                return s
            }()
            session.startedAt = dto.startedAt
            session.committedAt = dto.committedAt
            session.defaultCondition = dto.defaultCondition
            session.defaultPrinting = dto.defaultPrinting
            session.purchase = dto.purchaseId.flatMap { purchases[$0] }
            session.observedGroupIds = dto.observedGroupIds
            report.sessions += 1
        }

        // Two passes: parents may appear after their children in the file.
        for dto in file.purchaseItems {
            let item = items[dto.id] ?? {
                let i = PurchaseItem(productId: dto.productId)
                i.id = dto.id
                context.insert(i)
                items[dto.id] = i
                return i
            }()
            item.productId = dto.productId
            item.quantity = dto.quantity
            item.isSealed = dto.isSealed
            item.allocatedCostCents = dto.allocatedCostCents
            item.purchase = dto.purchaseId.flatMap { purchases[$0] }
            item.identifiedGroupId = dto.identifiedGroupId
            item.isRipped = dto.isRipped
            report.purchaseItems += 1
        }
        for dto in file.purchaseItems {
            items[dto.id]?.parentItem = dto.parentItemId.flatMap { items[$0] }
        }
        // A session's rip target is a `PurchaseItem`, resolved only now that
        // every line exists.
        for dto in file.sessions {
            sessions[dto.id]?.ripTarget = dto.ripTargetId.flatMap { items[$0] }
        }

        for dto in file.cards {
            let card = cards[dto.id] ?? {
                let c = OwnedCard(productId: dto.productId, printing: dto.printing, condition: dto.condition, confidence: .manual)
                c.id = dto.id
                context.insert(c)
                cards[dto.id] = c
                return c
            }()
            card.productId = dto.productId
            card.skuId = dto.skuId
            card.printing = dto.printing
            card.condition = dto.condition
            card.language = dto.language
            card.quantity = dto.quantity
            card.acquiredAt = dto.acquiredAt
            card.statusRaw = dto.statusRaw
            card.acquisitionBasisCents = dto.acquisitionBasisCents
            card.gradingBasisCents = dto.gradingBasisCents
            card.basisIsAllocated = dto.basisIsAllocated
            card.basisIsManual = dto.basisIsManual ?? false
            card.isBulk = dto.isBulk
            card.isPersonalCollection = dto.isPersonalCollection
            card.sourceItem = dto.sourceItemId.flatMap { items[$0] }
            card.scanSession = dto.scanSessionId.flatMap { sessions[$0] }
            card.matchConfidenceRaw = dto.matchConfidenceRaw
            card.certNumber = dto.certNumber
            card.graderRaw = dto.graderRaw
            card.gradeLabel = dto.gradeLabel
            card.ocrName = dto.ocrName
            card.ocrNumber = dto.ocrNumber
            card.candidateProductIds = dto.candidateProductIds
            card.scannedAt = dto.scannedAt
            card.tags = dto.tags ?? []
            card.isSealedSelf = dto.isSealedSelf ?? false
            card.gradedCompCents = dto.gradedCompCents ?? [:]
            card.fetchedCompCents = dto.fetchedCompCents ?? [:]
            card.compsFetchedAt = dto.compsFetchedAt
            card.sourceRef = dto.sourceRef ?? ""
            report.cards += 1
        }

        for dto in file.grading ?? [] {
            let submission = submissions[dto.id] ?? {
                let g = GradingSubmission(graderRaw: dto.graderRaw)
                g.id = dto.id
                context.insert(g)
                submissions[dto.id] = g
                return g
            }()
            submission.graderRaw = dto.graderRaw
            submission.submissionNumber = dto.submissionNumber
            submission.serviceLevel = dto.serviceLevel
            submission.declaredValueCents = dto.declaredValueCents
            submission.shippedAt = dto.shippedAt
            submission.returnedAt = dto.returnedAt
            submission.gradingFeesCents = dto.gradingFeesCents
            submission.shipToGraderCents = dto.shipToGraderCents
            submission.shipReturnCents = dto.shipReturnCents
            submission.insuranceCents = dto.insuranceCents
            submission.sourceRef = dto.sourceRef ?? ""
            report.grading += 1
        }

        for dto in file.gradingEntries ?? [] {
            let entry = entries[dto.id] ?? {
                let e = GradingEntry()
                e.id = dto.id
                context.insert(e)
                entries[dto.id] = e
                return e
            }()
            entry.submission = dto.submissionId.flatMap { submissions[$0] }
            entry.card = dto.cardId.flatMap { cards[$0] }
            entry.grade = dto.grade
            entry.certNumber = dto.certNumber
            entry.allocatedFeeCents = dto.allocatedFeeCents
            entry.noGrade = dto.noGrade
            report.gradingEntries += 1
        }

        for dto in file.sales ?? [] {
            let sale = sales[dto.id] ?? {
                let s = Sale(channelRaw: dto.channelRaw)
                s.id = dto.id
                context.insert(s)
                sales[dto.id] = s
                return s
            }()
            sale.soldAt = dto.soldAt
            sale.channelRaw = dto.channelRaw
            sale.grossCents = dto.grossCents
            sale.marketplaceFeesCents = dto.marketplaceFeesCents
            sale.salesTaxCents = dto.salesTaxCents
            sale.shippingChargedCents = dto.shippingChargedCents
            sale.shippingCostCents = dto.shippingCostCents
            sale.otherFeesCents = dto.otherFeesCents
            sale.externalOrderId = dto.externalOrderId
            sale.sourceRef = dto.sourceRef ?? ""
            report.sales += 1
        }

        for dto in file.saleLines ?? [] {
            let line = saleLines[dto.id] ?? {
                let l = SaleLine()
                l.id = dto.id
                context.insert(l)
                saleLines[dto.id] = l
                return l
            }()
            line.sale = dto.saleId.flatMap { sales[$0] }
            line.card = dto.cardId.flatMap { cards[$0] }
            line.sealedItem = dto.sealedItemId.flatMap { items[$0] }
            line.basisCents = dto.basisCents
            line.basisIncomplete = dto.basisIncomplete
            line.describedAs = dto.describedAs
            line.sourceRef = dto.sourceRef ?? ""
            report.saleLines += 1
        }

        for dto in file.expenses ?? [] {
            let expense = expenses[dto.id] ?? {
                let e = BusinessExpense()
                e.id = dto.id
                context.insert(e)
                expenses[dto.id] = e
                return e
            }()
            expense.date = dto.date
            expense.category = dto.category
            expense.vendor = dto.vendor
            expense.amountCents = dto.amountCents
            expense.note = dto.note
            expense.sourceRef = dto.sourceRef ?? ""
            report.expenses += 1
        }

        try context.save()
        return report
    }
}
