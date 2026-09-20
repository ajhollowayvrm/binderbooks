import SwiftData
import SwiftUI

/// Rips several sealed packs as one rip. The packs can come from one purchase
/// or several. The pulls share what all of them cost. See `RipPool`.
///
/// Nothing leaves inventory here. The packs go when he commits the scan, and
/// a scan he discards leaves them sealed.
struct RipSheet: View {
    let packs: [OwnedCard]
    /// The scan to open once this sheet is gone, and whether it opens with the
    /// catalog search showing. See `RipSheetPresenter`.
    var onScan: (ScanSession, Bool) -> Void
    var onChange: () -> Void

    @Environment(InventoryModel.self) private var model
    @Environment(CatalogController.self) private var catalog
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var counts: [String: Int] = [:]
    @State private var confirmNothing = false

    /// The packs of one product on one purchase.
    struct Bundle: Identifiable {
        var id: String
        var productId: Int
        var purchase: Purchase?
        var cards: [OwnedCard]
    }

    private var bundles: [Bundle] {
        var order: [String] = []
        var byKey: [String: Bundle] = [:]
        for card in RipPool.rippable(packs) {
            let purchase = card.sourceItem?.purchase
            let key = "\(purchase?.id.uuidString ?? "none")|\(card.productId)"
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = Bundle(id: key, productId: card.productId, purchase: purchase, cards: [])
            }
            byKey[key]?.cards.append(card)
        }
        return order.compactMap { byKey[$0] }
    }

    private func count(_ bundle: Bundle) -> Int {
        counts[bundle.id] ?? bundle.cards.count
    }

    private var chosen: [OwnedCard] {
        bundles.flatMap { Array($0.cards.prefix(count($0))) }
    }

    var body: some View {
        let bundles = bundles
        let chosen = chosen
        NavigationStack {
            List {
                Section {
                    ForEach(bundles) { bundle in
                        row(bundle)
                    }
                } footer: {
                    if Set(bundles.map { $0.purchase?.id }).count > 1 {
                        Text("These packs come from more than one purchase. Each pack's cost stays on its own purchase, and the pulls share the cost of all of them.")
                    }
                }

                Section {
                    LabeledContent("Packs", value: "\(chosen.count)")
                    LabeledContent("Cost") {
                        Text(chosen.reduce(0) { $0 + $1.acquisitionBasisCents }.asCurrency)
                            .font(.body.weight(.semibold).monospacedDigit())
                    }
                }

                Section {
                    Button {
                        scan()
                    } label: {
                        Label("Scan the pulls", systemImage: "camera")
                    }
                    .disabled(chosen.isEmpty)
                    Button {
                        scan(search: true)
                    } label: {
                        Label("Search the catalog for the pulls", systemImage: "magnifyingglass")
                    }
                    .disabled(chosen.isEmpty)
                    Button("Nothing to scan", role: .destructive) {
                        confirmNothing = true
                    }
                    .disabled(chosen.isEmpty)
                } footer: {
                    Text("The packs leave inventory when you commit the scan. If you discard the scan, they stay sealed. You can add pulls that are already in inventory from the purchase page.")
                }
            }
            .navigationTitle(chosen.count == 1 ? "Rip 1 pack" : "Rip \(chosen.count) packs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .confirmationDialog("Rip with nothing to scan?", isPresented: $confirmNothing, titleVisibility: .visible) {
                Button("Rip \(chosen.count) packs", role: .destructive) { ripWithNothing() }
            } message: {
                Text("The packs leave inventory. Their cost stays on the books. Add pulls from inventory later on the purchase page.")
            }
            .task { await model.load(for: packs) }
        }
    }

    private func row(_ bundle: Bundle) -> some View {
        let hit = model.hits[bundle.productId]
        return VStack(alignment: .leading, spacing: 4) {
            Text(hit?.name ?? "Sealed product")
                .lineLimit(2)
            Text(purchaseText(bundle.purchase))
                .font(.caption)
                .foregroundStyle(.secondary)
            if bundle.cards.count > 1 {
                Stepper(
                    "\(count(bundle)) of \(bundle.cards.count)",
                    value: Binding(get: { count(bundle) }, set: { counts[bundle.id] = $0 }),
                    in: 0...bundle.cards.count
                )
                .monospacedDigit()
            }
        }
    }

    private func purchaseText(_ purchase: Purchase?) -> String {
        guard let purchase else { return "No purchase" }
        let vendor = purchase.vendor.isEmpty ? "Purchase" : purchase.vendor
        return "\(vendor) · \(purchase.date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func scan(search: Bool = false) {
        let opening = chosen
        guard let home = RipPool.prepare(opening, context: modelContext) else { return }
        let session = ScanSession()
        session.purchase = home.purchase
        session.ripTarget = home
        // The sets these packs belong to, so the matcher knows what to expect.
        // He is not asked: he has just said which boxes he is opening, and a
        // box has a set. See `RipSetHint`.
        session.preferredGroupIds = []
        modelContext.insert(session)
        try? modelContext.save()
        let productIds = opening.map(\.productId)
        Task { @MainActor in
            await RipSetHint.apply(to: session, productIds: productIds, catalog: catalog)
            try? modelContext.save()
        }
        onChange()
        onScan(session, search)
        dismiss()
    }

    private func ripWithNothing() {
        guard let home = RipPool.prepare(chosen, context: modelContext) else { return }
        RipPool.finish(home, pulls: [], acquiredAt: home.purchase?.date ?? Date(), context: modelContext)
        onChange()
        dismiss()
    }
}

/// Presents `RipSheet`, then opens the scanner once the sheet is gone. The
/// root owns the scanner cover, and it cannot present over a sheet.
private struct RipSheetPresenter: ViewModifier {
    @Binding var target: TagSheetTarget?
    var onChange: () -> Void

    @Environment(ScannerLauncher.self) private var launcher
    @State private var pending: ScanSession?
    @State private var pendingSearch = false

    func body(content: Content) -> some View {
        content.sheet(item: $target, onDismiss: {
            if let pending {
                launcher.open(pending, search: pendingSearch)
                self.pending = nil
            }
        }) { target in
            RipSheet(packs: target.cards, onScan: { pending = $0; pendingSearch = $1 }, onChange: onChange)
        }
    }
}

extension View {
    /// The rip sheet for the packs in `target`.
    func ripSheet(_ target: Binding<TagSheetTarget?>, onChange: @escaping () -> Void = {}) -> some View {
        modifier(RipSheetPresenter(target: target, onChange: onChange))
    }
}

/// Cards already in inventory that came out of a rip. A card recorded as part
/// of a buy leaves that buy, and takes its share of the packs' cost instead.
struct RipPullsSheet: View {
    let home: PurchaseItem
    var onMoved: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var cards: [OwnedCard]
    @State private var selection: [UUID] = []
    @State private var failed = false

    var body: some View {
        NavigationStack {
            InventoryCardPicker(
                selection: $selection,
                footer: "Sold cards are not on this list. A card on its own line of a purchase leaves that line, and the purchase splits again."
            )
            .navigationTitle("Add pulls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(selection.isEmpty)
                }
            }
            .alert("The cards did not move", isPresented: $failed) {
                Button("OK") {}
            }
        }
    }

    private func add() {
        let byId = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let chosen = selection.compactMap { byId[$0] }
        do {
            try RipPool.addPulls(chosen, to: home, context: modelContext)
            onMoved()
            dismiss()
        } catch {
            failed = true
        }
    }
}
