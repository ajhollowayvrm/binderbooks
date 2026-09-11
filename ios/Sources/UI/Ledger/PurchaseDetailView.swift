import SwiftData
import SwiftUI

/// One purchase: what it cost, what came out of it, and the way to open it.
///
/// Ripping starts here. There is no rip record — the cards land in inventory
/// carrying their share of what this purchase cost, and that is the whole of it.
struct PurchaseDetailView: View {
    let purchaseID: UUID

    @Environment(InventoryModel.self) private var inventory
    @Environment(ScannerLauncher.self) private var launcher
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var purchases: [Purchase]
    @State private var confirmDelete = false
    @State private var showBlocked = false

    init(purchaseID: UUID) {
        self.purchaseID = purchaseID
        _purchases = Query(filter: #Predicate<Purchase> { $0.id == purchaseID })
    }

    private var purchase: Purchase? { purchases.first }

    private var cards: [OwnedCard] {
        (purchase?.items ?? []).flatMap(\.cards).sorted { $0.acquiredAt > $1.acquiredAt }
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

                Section {
                    Button {
                        rip(purchase)
                    } label: {
                        Label(cards.isEmpty ? "Open it" : "Open more of it", systemImage: "camera")
                    }
                } footer: {
                    Text("Scan what came out. The cards join this purchase, and its total splits over the ones you do not price yourself.")
                }

                Section {
                    if cards.isEmpty {
                        Text("Nothing has come out of this purchase yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(cards) { card in
                        NavigationLink(value: AppRoute.ownedCard(card.id)) {
                            cardRow(card)
                        }
                    }
                } header: {
                    Text(cards.count == 1 ? "1 card" : "\(cards.count) cards")
                } footer: {
                    if cards.contains(where: \.basisIsAllocated) {
                        // docs/04: the $193 box that yielded three near-worthless
                        // hits. The per-card figure is derived, and the pack is
                        // the truer read.
                        Text("A derived cost is this purchase's total split over the cards. Read the purchase, not the card, to see how the opening did.")
                    }
                }

                Section {
                    Button("Delete purchase", role: .destructive) {
                        if cards.isEmpty { confirmDelete = true } else { showBlocked = true }
                    }
                }
            } else {
                ContentUnavailableView("This purchase is gone", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("Purchase")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this purchase?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deletePurchase() }
        }
        // Deleting a purchase deletes its lines, and the lines own the cards.
        // He removes the cards first, on purpose, or the purchase stays.
        .alert("Cards came out of this purchase", isPresented: $showBlocked) {
            Button("OK") {}
        } message: {
            Text(cards.count == 1
                ? "1 card in inventory came from this purchase. Delete it first."
                : "\(cards.count) cards in inventory came from this purchase. Delete them first.")
        }
    }

    private func deletePurchase() {
        guard let purchase else { return }
        modelContext.delete(purchase)
        try? modelContext.save()
        dismiss()
    }

    private func cardRow(_ card: OwnedCard) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(inventory.hits[card.productId]?.name ?? card.ocrName ?? "Unknown")
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if card.basisIsAllocated { Text("derived") }
                    if card.basisIsManual { Text("you priced it") }
                    if let set = inventory.hits[card.productId]?.setName { Text(set).lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(card.totalBasisCents.asCurrency)
                .font(.callout.monospacedDigit())
        }
    }

    /// Start a session already attached to this purchase, so the commit sheet
    /// has nothing left to ask.
    private func rip(_ purchase: Purchase) {
        let session = ScanSession()
        session.purchase = purchase
        modelContext.insert(session)
        try? modelContext.save()
        launcher.session = session
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
                    LabeledContent("Grader", value: submission.graderRaw.uppercased())
                    if let shipped = submission.shippedAt {
                        LabeledContent("Shipped", value: shipped.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let returned = submission.returnedAt {
                        LabeledContent("Returned", value: returned.formatted(date: .abbreviated, time: .omitted))
                    }
                    if !submission.submissionNumber.isEmpty {
                        LabeledContent("Submission", value: submission.submissionNumber)
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
                                LabeledContent(inventory.hits[card.productId]?.name ?? card.ocrName ?? "Unknown", value: gradeText(entry))
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
                        Text("The imported charges name a card count and nothing else, so nothing was joined to them. Each card carries its own grading cost.")
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
        .sheet(isPresented: $recording) {
            if let submission = submissions.first {
                GradingReturnSheet(submission: submission) { inventory.invalidateHaystacks() }
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

    private func gradeText(_ entry: GradingEntry) -> String {
        if entry.noGrade { return "no grade" }
        guard let grade = entry.grade else { return "not back" }
        let text = GradingReturnSheet.gradeText(grade)
        return entry.certNumber.isEmpty ? text : "\(text) · \(entry.certNumber)"
    }

    /// The card leaves the submission and the fee it carried comes off it.
    /// The slab stays: a cert number on a card is a fact about the card.
    private func remove(_ entry: GradingEntry) {
        if let card = entry.card {
            let editor = CardTagEditor(context: modelContext)
            for label in ReservedTag.allAtGrader { editor.remove(label, from: [card]) }
            if card.gradingBasisCents == entry.allocatedFeeCents { card.gradingBasisCents = 0 }
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
