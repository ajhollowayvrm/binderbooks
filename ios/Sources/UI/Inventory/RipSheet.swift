import SwiftData
import SwiftUI

/// Rips several sealed packs as one rip. The packs can come from one purchase
/// or several. See `Rip`.
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

    /// The packs of one product.
    struct Bundle: Identifiable {
        var id: String
        var productId: Int
        var cards: [OwnedCard]
    }

    private var bundles: [Bundle] {
        var order: [String] = []
        var byKey: [String: Bundle] = [:]
        for card in Rip.rippable(packs) {
            let key = "\(card.productId)"
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = Bundle(id: key, productId: card.productId, cards: [])
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
                }

                Section {
                    LabeledContent("Packs", value: "\(chosen.count)")
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
                    Text("The packs leave inventory when you commit the scan. If you discard the scan, they stay sealed.")
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
                Text("The packs leave inventory. The purchase stays on the books.")
            }
            .task { await model.load(for: packs) }
        }
    }

    private func row(_ bundle: Bundle) -> some View {
        let hit = model.hits[bundle.productId]
        return VStack(alignment: .leading, spacing: 4) {
            Text(hit?.name ?? "Sealed product")
                .lineLimit(2)
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

    private func scan(search: Bool = false) {
        guard let session = Rip.start(chosen, context: modelContext, catalog: catalog) else { return }
        onChange()
        onScan(session, search)
        dismiss()
    }

    private func ripWithNothing() {
        Rip.ripWithNothing(chosen, context: modelContext)
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
