import SwiftData
import SwiftUI

/// The purchase the selected cards came from. The purchases are the ones on
/// the books, newest first. The ones bought around the cards' own date come
/// first, because a scan usually follows its purchase by a day or two.
struct ChoosePurchaseSheet: View {
    let cards: [OwnedCard]
    var onLinked: () -> Void

    @Environment(InventoryModel.self) private var inventory
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var failed = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            PurchasePickerList(
                around: cards.map(\.acquiredAt).min(),
                footer: "The cards take their share of the purchase's total, split by market price. A cost you typed on a card stays, and it comes out of the total first.",
                isCurrent: { purchase in cards.allSatisfy { $0.sourceItem?.purchase?.id == purchase.id } },
                onPick: { purchase in Task { await choose(purchase) } }
            )
            .disabled(working)
            .navigationTitle(cards.count == 1 ? "Add to a purchase" : "Add \(cards.count) cards to a purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("The cards did not move", isPresented: $failed) {
                Button("OK") {}
            } message: {
                Text("The store did not accept the change. Try again.")
            }
        }
    }

    /// The split reads market prices, so every card on the purchases involved
    /// loads first: the new purchase, and each purchase the cards leave.
    private func choose(_ purchase: Purchase) async {
        working = true
        defer { working = false }
        let others = cards.compactMap { $0.sourceItem?.purchase }
        let involved = ([purchase] + others).flatMap { $0.items.flatMap(\.cards) } + cards
        await inventory.load(for: involved)
        do {
            try PurchaseLink.link(cards, to: purchase, marketCents: { inventory.marketCents(for: $0) }, context: modelContext)
            inventory.invalidateHaystacks()
            onLinked()
            dismiss()
        } catch {
            failed = true
        }
    }
}

/// Every purchase on the books, with search. The purchases bought around
/// `around` come first. Put it inside a `NavigationStack`, for the search field.
struct PurchasePickerList: View {
    /// The date the nearby section is built around. Nil for no such section.
    var around: Date?
    var footer: String
    /// True for the purchase the cards are on now. It shows a checkmark and
    /// cannot be chosen again.
    var isCurrent: (Purchase) -> Bool
    var onPick: (Purchase) -> Void

    @Query(sort: \Purchase.date, order: .reverse) private var purchases: [Purchase]
    @State private var query = ""

    /// Seven days either side of `around`.
    private var nearby: [Purchase] {
        guard query.isEmpty, let around else { return [] }
        return purchases.filter { abs($0.date.timeIntervalSince(around)) <= 7 * 86_400 }
    }

    /// Every typed word must appear in the vendor, the note, the amount, or
    /// the date. The note names what was bought: "11x Destined Rivals
    /// Booster Pack".
    private var matching: [Purchase] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return purchases }
        return purchases.filter { purchase in
            let text = [
                purchase.vendor, purchase.note, purchase.landedCostCents.asCurrency,
                purchase.date.formatted(date: .abbreviated, time: .omitted),
                purchase.date.formatted(.dateTime.month(.wide).year()),
            ].joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        List {
            if let around, !nearby.isEmpty {
                Section("Around \(around.formatted(date: .abbreviated, time: .omitted))") {
                    ForEach(nearby) { row($0) }
                }
            }
            Section {
                if matching.isEmpty {
                    Text("No purchase matches.").foregroundStyle(.secondary)
                }
                ForEach(matching) { row($0) }
            } header: {
                Text(query.isEmpty ? "All purchases (\(purchases.count))" : "Matches (\(matching.count))")
            } footer: {
                Text(footer)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Vendor, product, amount, or date")
    }

    private func row(_ purchase: Purchase) -> some View {
        let current = isCurrent(purchase)
        let items = LedgerEntry.itemSummary(purchase)
        let date = purchase.date.formatted(date: .abbreviated, time: .omitted)
        return Button {
            onPick(purchase)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(purchase.vendor.isEmpty ? "Purchase" : purchase.vendor)
                        .foregroundStyle(.primary)
                    Text(items.isEmpty ? date : "\(date) · \(items)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !purchase.note.isEmpty {
                        Text(purchase.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if current {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
                Text(purchase.landedCostCents.asCurrency)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        // Plain, like the card picker. A list button tints its whole label,
        // and every row then reads as a link.
        .buttonStyle(.plain)
        .disabled(current)
    }
}
