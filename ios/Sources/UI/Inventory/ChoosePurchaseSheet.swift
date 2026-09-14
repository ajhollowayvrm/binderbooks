import SwiftData
import SwiftUI

/// Where one card, or a selection, came from. The purchases are the ones on the
/// books, newest first. The ones bought around the cards' own date come first,
/// because a scan usually follows its purchase by a day or two.
struct ChoosePurchaseSheet: View {
    let cards: [OwnedCard]
    var onLinked: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Purchase.date, order: .reverse) private var purchases: [Purchase]
    @State private var query = ""
    @State private var message: String?
    @State private var failed = false

    /// Seven days either side of the earliest card.
    private var nearby: [Purchase] {
        guard query.isEmpty, let earliest = cards.map(\.acquiredAt).min() else { return [] }
        return purchases.filter { abs($0.date.timeIntervalSince(earliest)) <= 7 * 86_400 }
    }

    /// Every typed word must appear in the vendor, the note, the amount, or the date.
    private var matching: [Purchase] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return purchases }
        return purchases.filter { purchase in
            let text = [
                purchase.vendor, purchase.note, purchase.landedCostCents.asCurrency,
                purchase.date.formatted(date: .abbreviated, time: .omitted),
            ].joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let earliest = cards.map(\.acquiredAt).min(), !nearby.isEmpty {
                    Section("Around \(earliest.formatted(date: .abbreviated, time: .omitted))") {
                        ForEach(nearby) { row($0) }
                    }
                }
                Section {
                    if matching.isEmpty {
                        Text("No purchase matches.").foregroundStyle(.secondary)
                    }
                    ForEach(matching) { row($0) }
                } header: {
                    Text(query.isEmpty ? "All purchases" : "Matches")
                } footer: {
                    Text("The cards take their share of the purchase's total. A cost already on a card stays, and it comes out of the total first.")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Vendor, note, or amount")
            .navigationTitle(cards.count == 1 ? "Choose a purchase" : "Purchase for \(cards.count) cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("Linked", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil; dismiss() } })) {
                Button("OK") {}
            } message: {
                Text(message ?? "")
            }
            .alert("The cards did not move", isPresented: $failed) {
                Button("OK") {}
            }
        }
    }

    private func row(_ purchase: Purchase) -> some View {
        let isCurrent = cards.allSatisfy { $0.sourceItem?.purchase?.id == purchase.id }
        return Button {
            choose(purchase)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(purchase.vendor.isEmpty ? "Purchase" : purchase.vendor)
                        .foregroundStyle(.primary)
                    Text("\(purchase.date.formatted(date: .abbreviated, time: .omitted)) · \(LedgerEntry.cardCount(purchase))")
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
                if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
                Text(purchase.landedCostCents.asCurrency)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
        // Plain, like the card picker. A list button tints its whole label, and
        // every row then reads as a link.
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    private func choose(_ purchase: Purchase) {
        do {
            let result = try PurchaseLink.link(cards, to: purchase, context: modelContext)
            onLinked()
            if !result.split {
                message = "Another card on this purchase has a cost that the split did not write, so the total did not split again. Set the cost of these cards by hand."
            } else if result.filledSaleLines > 0 {
                message = result.filledSaleLines == 1
                    ? "1 sold card now has a cost on its order."
                    : "\(result.filledSaleLines) sold cards now have a cost on their orders."
            } else {
                dismiss()
            }
        } catch {
            failed = true
        }
    }
}
