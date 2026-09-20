import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// The collection store has no `VersionedSchema` and no `SchemaMigrationPlan`.
/// It leans on SwiftData's lightweight migration, which means a model that goes
/// away must not take the store with it.
///
/// `RipEvent` was removed on 2026-09-10 while his phone already held 58 of them,
/// so this is the case that had to be proved rather than assumed. The app calls
/// `fatalError` when the container fails to open, so a migration this test does
/// not cover is a crash on launch with his only copy of the data inside.
///
/// It covers a removed entity, not a removed relationship: a test target cannot
/// add a stored property back onto `OwnedCard`.
@Suite struct SchemaMigrationTests {
    /// A model that exists in the old store and in no current schema.
    @Model final class RemovedEntity {
        var id: UUID = UUID()
        var note: String = ""
        init(note: String) {
            self.id = UUID()
            self.note = note
        }
    }

    @Test @MainActor func aStoreSurvivesAModelBeingDeleted() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migration-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        // The old schema: everything the app has now, plus the model that left.
        let old = Schema(CollectionStore.models + [RemovedEntity.self])
        let oldContainer = try ModelContainer(
            for: old,
            configurations: [ModelConfiguration(schema: old, url: url)]
        )
        let purchase = Purchase(vendor: "Game Grid", itemCostCents: 19_339)
        oldContainer.mainContext.insert(purchase)
        oldContainer.mainContext.insert(RemovedEntity(note: "a rip"))
        try oldContainer.mainContext.save()

        // The new schema opens the same file. Nothing it still knows about may
        // be lost, and it must not throw.
        let new = Schema(CollectionStore.models)
        let newContainer = try ModelContainer(
            for: new,
            configurations: [ModelConfiguration(schema: new, url: url)]
        )
        let purchases = try newContainer.mainContext.fetch(FetchDescriptor<Purchase>())
        #expect(purchases.count == 1)
        #expect(purchases.first?.vendor == "Game Grid")
        #expect(purchases.first?.itemCostCents == 19_339)
    }

    /// `ScanSession.preferredGroupIds` was added on 2026-09-18. A store written
    /// before it must open and read the field as empty, which is what those
    /// sessions were: unscoped. The app calls `fatalError` when the container
    /// fails to open, so an unproven migration is a crash on launch with his
    /// only copy of the data inside.
    @Test @MainActor func aStoreWrittenBeforeTheSetScopeStillOpens() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scope-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        let schema = Schema(CollectionStore.models)
        let first = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: url)]
        )
        let session = ScanSession()
        session.observedGroupIds = [100, 101]
        first.mainContext.insert(session)
        try first.mainContext.save()
        let id = session.id

        let second = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: url)]
        )
        let sessions = try second.mainContext.fetch(FetchDescriptor<ScanSession>())
        let reopened = sessions.first { $0.id == id }
        #expect(reopened != nil)
        #expect(reopened?.observedGroupIds == [100, 101])
        #expect(reopened?.preferredGroupIds == [])
    }
}
