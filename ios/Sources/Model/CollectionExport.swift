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
    /// Version 2 added `OwnedCardDTO.tags` and `basisIsManual`. The gate is `file.version <= version`,
    /// so a version 1 file still imports. The bump stops an older build from
    /// importing a tagged file and dropping every label in silence.
    static let version = 2

    struct File: Codable, Equatable {
        var format: String = CollectionExport.format
        var version: Int = CollectionExport.version
        var exportedAt: String
        var purchases: [PurchaseDTO]
        var purchaseItems: [PurchaseItemDTO]
        var cards: [OwnedCardDTO]
        var sessions: [ScanSessionDTO]

        var counts: String {
            "\(purchases.count) purchases, \(purchaseItems.count) lines, \(cards.count) cards, \(sessions.count) sessions"
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
        var ocrName: String?
        var ocrNumber: String?
        var candidateProductIds: [Int]
        var scannedAt: Date
        /// Optional on purpose. The synthesised decoder calls `decode` for a
        /// non-optional property and throws `keyNotFound`, so a non-optional
        /// field would make every file written before tags unimportable.
        var tags: [String]?
    }

    struct ScanSessionDTO: Codable, Equatable {
        var id: UUID
        var startedAt: Date
        var committedAt: Date?
        var defaultCondition: String
        var defaultPrinting: String?
        var purchaseId: UUID?
        var observedGroupIds: [Int]
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
        var deleted = 0
    }

    // MARK: - Export

    @MainActor
    static func snapshot(_ context: ModelContext, now: Date = Date()) throws -> File {
        let purchases = try context.fetch(FetchDescriptor<Purchase>())
        let items = try context.fetch(FetchDescriptor<PurchaseItem>())
        let cards = try context.fetch(FetchDescriptor<OwnedCard>())
        let sessions = try context.fetch(FetchDescriptor<ScanSession>())

        return File(
            exportedAt: ISO8601DateFormatter().string(from: now),
            purchases: purchases.map {
                PurchaseDTO(
                    id: $0.id, date: $0.date, vendor: $0.vendor, note: $0.note, receiptImageData: $0.receiptImageData,
                    itemCostCents: $0.itemCostCents, shippingCents: $0.shippingCents, taxCents: $0.taxCents,
                    feesCents: $0.feesCents, allocationMethodRaw: $0.allocationMethodRaw
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
                    certNumber: $0.certNumber, graderRaw: $0.graderRaw, ocrName: $0.ocrName, ocrNumber: $0.ocrNumber,
                    candidateProductIds: $0.candidateProductIds, scannedAt: $0.scannedAt, tags: $0.tags
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            sessions: sessions.map {
                ScanSessionDTO(
                    id: $0.id, startedAt: $0.startedAt, committedAt: $0.committedAt, defaultCondition: $0.defaultCondition,
                    defaultPrinting: $0.defaultPrinting, purchaseId: $0.purchase?.id, observedGroupIds: $0.observedGroupIds
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
            card.ocrName = dto.ocrName
            card.ocrNumber = dto.ocrNumber
            card.candidateProductIds = dto.candidateProductIds
            card.scannedAt = dto.scannedAt
            card.tags = dto.tags ?? []
            report.cards += 1
        }

        try context.save()
        return report
    }
}
