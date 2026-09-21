import SwiftData
import SwiftUI

/// Every purchase on the books, with search. The purchases bought around
/// `around` come first, because a card usually follows its purchase by a day
/// or two. Put it inside a `NavigationStack`, for the search field.
///
/// `ChoosePurchaseSheet` and `AddToInventorySheet` both use it.
struct PurchasePickerList<Leading: View>: View {
    /// The date the nearby section is built around. Nil for no such section.
    var around: Date?
    var footer: String
    /// True for the purchase that is chosen now. It shows a checkmark.
    var isCurrent: (Purchase) -> Bool
    /// True when the current purchase cannot be chosen again.
    var disablesCurrent = false
    /// Rows above the purchases, such as "None". Hidden while he searches.
    @ViewBuilder var leading: () -> Leading
    var onPick: (Purchase) -> Void

    @Query(sort: \Purchase.date, order: .reverse) private var purchases: [Purchase]
    @State private var query = ""

    /// Seven days either side of `around`.
    private var nearby: [Purchase] {
        guard query.isEmpty, let around else { return [] }
        return purchases.filter { abs($0.date.timeIntervalSince(around)) <= 7 * 86_400 }
    }

    /// Every typed word must appear in the vendor, the note, the amount, the
    /// date, or the contents line. The note names what was bought: "11x
    /// Destined Rivals Booster Pack", and the contents line carries "sealed"
    /// and the card count.
    private var matching: [Purchase] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return purchases }
        return purchases.filter { purchase in
            let text = [
                purchase.vendor, purchase.note, purchase.landedCostCents.asCurrency,
                purchase.date.formatted(date: .abbreviated, time: .omitted),
                purchase.date.formatted(.dateTime.month(.wide).year()),
                LedgerEntry.purchaseContents(purchase),
            ].joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        List {
            if query.isEmpty {
                let leading = leading()
                if !(leading is EmptyView) {
                    Section { leading }
                }
            }
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
        return Button {
            onPick(purchase)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(purchase.vendor.isEmpty ? "Purchase" : purchase.vendor)
                        .foregroundStyle(.primary)
                    Text("\(purchase.date.formatted(date: .abbreviated, time: .omitted)) · \(LedgerEntry.purchaseContents(purchase))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !purchase.note.isEmpty {
                        Text(purchase.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    let extras = LedgerEntry.purchaseExtras(purchase)
                    if !extras.isEmpty {
                        Text(extras)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
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
        // Plain, like the card picker. A list button tints its whole label, and
        // every row then reads as a link.
        .buttonStyle(.plain)
        .disabled(disablesCurrent && current)
    }
}

extension PurchasePickerList where Leading == EmptyView {
    init(
        around: Date?, footer: String, isCurrent: @escaping (Purchase) -> Bool,
        disablesCurrent: Bool = false, onPick: @escaping (Purchase) -> Void
    ) {
        self.init(around: around, footer: footer, isCurrent: isCurrent, disablesCurrent: disablesCurrent, leading: { EmptyView() }, onPick: onPick)
    }
}
