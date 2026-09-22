import SwiftData
import SwiftUI

/// One purchase: what it cost, and what was in it.
///
/// A purchase is money on the books. It has no link to the cards in
/// inventory, so nothing here changes a card.
struct PurchaseDetailView: View {
    let purchaseID: UUID

    @Environment(InventoryModel.self) private var inventory
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var purchases: [Purchase]
    @State private var confirmDelete = false
    @State private var editing = false

    init(purchaseID: UUID) {
        self.purchaseID = purchaseID
        _purchases = Query(filter: #Predicate<Purchase> { $0.id == purchaseID })
    }

    private var purchase: Purchase? { purchases.first }

    /// The products on the purchase, with the quantity of each, in the order
    /// they first appear.
    static func contents(of purchase: Purchase) -> [(productId: Int, quantity: Int)] {
        var order: [Int] = []
        var totals: [Int: Int] = [:]
        for item in purchase.items {
            if totals[item.productId] == nil { order.append(item.productId) }
            totals[item.productId, default: 0] += max(1, item.quantity)
        }
        return order.map { ($0, totals[$0] ?? 0) }
    }

    var body: some View {
        List {
            if let purchase {
                Section {
                    LabeledContent("Bought", value: purchase.date.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Vendor", value: purchase.vendor.isEmpty ? "—" : purchase.vendor)
                    if !purchase.note.isEmpty {
                        Text(purchase.note).font(.callout).foregroundStyle(.secondary)
                    }
                }

                Section("Money") {
                    LabeledContent("Item cost", value: purchase.itemCostCents.asCurrency)
                    if purchase.shippingCents > 0 { LabeledContent("Shipping", value: purchase.shippingCents.asCurrency) }
                    if purchase.taxCents > 0 { LabeledContent("Tax", value: purchase.taxCents.asCurrency) }
                    if purchase.feesCents > 0 { LabeledContent("Fees", value: purchase.feesCents.asCurrency) }
                    LabeledContent("Landed") {
                        Text(purchase.landedCostCents.asCurrency).font(.body.weight(.semibold).monospacedDigit())
                    }
                }

                contentsSection(purchase)

                Section {
                    Button("Delete purchase", role: .destructive) { confirmDelete = true }
                }
            } else {
                ContentUnavailableView("This purchase is gone", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("Purchase")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if purchase != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let purchase {
                EditPurchaseSheet(purchase: purchase) { inventory.invalidateHaystacks() }
            }
        }
        .task(id: purchase?.items.count ?? 0) {
            await inventory.load(productIds: purchase.map { Self.contents(of: $0).map(\.productId) } ?? [])
        }
        .confirmationDialog("Delete this purchase?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deletePurchase() }
        } message: {
            Text("It leaves the books. Cards in inventory do not change.")
        }
    }

    /// What he bought, by product.
    private func contentsSection(_ purchase: Purchase) -> some View {
        let contents = Self.contents(of: purchase)
        return Section {
            if contents.isEmpty {
                Text("No items listed.")
                    .foregroundStyle(.secondary)
            }
            ForEach(contents, id: \.productId) { line in
                HStack {
                    Text(inventory.hits[line.productId]?.name ?? "Product")
                        .lineLimit(2)
                    Spacer()
                    Text("\(line.quantity)×")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("What was in it")
        }
    }

    private func deletePurchase() {
        guard let purchase else { return }
        try? PurchaseEditor.delete(purchase, context: modelContext)
        inventory.invalidateHaystacks()
        dismiss()
    }
}

/// One grading charge. It carries fees and, for the imported ones, no cards.
struct GradingDetailView: View {
    let submissionID: UUID

    @Environment(InventoryModel.self) private var inventory
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var submissions: [GradingSubmission]
    @State private var recording = false
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var blockedMessage: String?

    init(submissionID: UUID) {
        self.submissionID = submissionID
        _submissions = Query(filter: #Predicate<GradingSubmission> { $0.id == submissionID })
    }

    var body: some View {
        List {
            if let submission = submissions.first {
                Section {
                    Picker("Grader", selection: Binding(
                        get: { submission.graderRaw.lowercased() },
                        set: { grader in
                            GraderCorrection.change(submission, to: grader, context: modelContext)
                            inventory.invalidateHaystacks()
                        }
                    )) {
                        ForEach(graderChoices(submission), id: \.self) { grader in
                            Text(grader.isEmpty ? "Unknown" : grader.uppercased()).tag(grader)
                        }
                    }
                    if let shipped = submission.shippedAt {
                        LabeledContent("Shipped", value: shipped.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let returned = submission.returnedAt {
                        LabeledContent("Returned", value: returned.formatted(date: .abbreviated, time: .omitted))
                    }
                    if !submission.submissionNumber.isEmpty {
                        LabeledContent("Submission", value: submission.submissionNumber)
                    }
                    if !submission.serviceLevel.isEmpty {
                        LabeledContent("Service level", value: submission.serviceLevel)
                    }
                    if submission.declaredValueCents > 0 {
                        LabeledContent("Declared value", value: submission.declaredValueCents.asCurrency)
                    }
                } footer: {
                    if submission.entries.contains(where: { $0.card != nil }) {
                        Text("A new grader moves the cards with it: a card still out changes its label, and a returned slab changes its grader.")
                    }
                }

                Section("Money") {
                    LabeledContent("Grading fees", value: submission.gradingFeesCents.asCurrency)
                    if submission.shipToGraderCents > 0 { LabeledContent("Ship out", value: submission.shipToGraderCents.asCurrency) }
                    if submission.shipReturnCents > 0 { LabeledContent("Ship back", value: submission.shipReturnCents.asCurrency) }
                    if submission.insuranceCents > 0 { LabeledContent("Insurance", value: submission.insuranceCents.asCurrency) }
                    LabeledContent("Total") {
                        Text(submission.totalCostCents.asCurrency).font(.body.weight(.semibold).monospacedDigit())
                    }
                }

                Section {
                    if submission.entries.isEmpty {
                        Text("No cards are attached to this charge.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(submission.entries) { entry in
                        if let card = entry.card {
                            NavigationLink(value: AppRoute.ownedCard(card.id)) {
                                LabeledContent(card.displayName(inventory.hits[card.productId]) ?? "Unknown", value: gradeText(entry))
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Remove", role: .destructive) { remove(entry) }
                            }
                        }
                    }
                    if submission.entries.contains(where: { $0.card != nil }) {
                        Button {
                            recording = true
                        } label: {
                            Label(submission.returnedAt == nil ? "Record return" : "Edit return", systemImage: "shippingbox")
                        }
                    }
                } header: {
                    Text("Cards")
                } footer: {
                    if submission.entries.isEmpty {
                        // docs/04: the charge names a card count and no cards.
                        Text("The imported charges name a card count and nothing else, so nothing was joined to them.")
                    } else {
                        Text("Swipe a card to take it off this submission.")
                    }
                }

                Section {
                    Button("Delete submission", role: .destructive) { requestDelete(submission) }
                }
            } else {
                ContentUnavailableView("This charge is gone", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("Grading")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !submissions.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                }
            }
        }
        .sheet(isPresented: $recording) {
            if let submission = submissions.first {
                GradingReturnSheet(submission: submission) { inventory.invalidateHaystacks() }
            }
        }
        .sheet(isPresented: $editing) {
            if let submission = submissions.first {
                EditGradingSheet(submission: submission) { inventory.invalidateHaystacks() }
            }
        }
        .confirmationDialog("Delete this submission?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSubmission() }
        }
        .alert("Cards are still on this submission", isPresented: Binding(get: { blockedMessage != nil }, set: { if !$0 { blockedMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(blockedMessage ?? "")
        }
    }

    /// The graders a send offers, plus whatever an imported charge already
    /// names, so the picker always holds the current value.
    private func graderChoices(_ submission: GradingSubmission) -> [String] {
        let current = submission.graderRaw.lowercased()
        return SendToGraderSheet.graders.contains(current) ? SendToGraderSheet.graders : [current] + SendToGraderSheet.graders
    }

    private func gradeText(_ entry: GradingEntry) -> String {
        if entry.noGrade { return "no grade" }
        guard let grade = entry.grade else { return "not back" }
        let text = GradingReturnSheet.gradeText(grade)
        return entry.certNumber.isEmpty ? text : "\(text) · \(entry.certNumber)"
    }

    /// The card leaves the submission. The charge stays as it is. The slab
    /// stays: a cert number on a card is a fact about the card.
    private func remove(_ entry: GradingEntry) {
        if let card = entry.card {
            let editor = CardTagEditor(context: modelContext)
            for label in ReservedTag.allAtGrader { editor.remove(label, from: [card]) }
            if card.status == .atGrader { card.status = .owned }
        }
        modelContext.delete(entry)
        try? modelContext.save()
    }

    private func requestDelete(_ submission: GradingSubmission) {
        let linked = submission.entries.filter { $0.card != nil }.count
        if linked > 0 {
            blockedMessage = linked == 1
                ? "1 card in inventory is on this submission. Remove it first."
                : "\(linked) cards in inventory are on this submission. Remove them first."
        } else {
            confirmDelete = true
        }
    }

    private func deleteSubmission() {
        guard let submission = submissions.first else { return }
        modelContext.delete(submission)
        try? modelContext.save()
        dismiss()
    }
}
