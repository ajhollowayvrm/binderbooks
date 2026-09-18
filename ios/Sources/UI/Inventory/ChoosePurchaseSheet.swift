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
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            PurchasePickerList(
                around: cards.map(\.acquiredAt).min(),
                footer: "The cards take their share of the purchase's total. A cost already on a card stays, and it comes out of the total first.",
                isCurrent: { purchase in cards.allSatisfy { $0.sourceItem?.purchase?.id == purchase.id } },
                disablesCurrent: true,
                onPick: choose
            )
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
