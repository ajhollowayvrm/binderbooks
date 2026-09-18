import SwiftData
import SwiftUI

/// One purchase: what it cost, the sealed packs still on it, the rips, and the
/// cards.
///
/// There is no rip record. The pulls land in inventory carrying their share of
/// what the packs cost, and the ripped lines hold the rest. See `RipPool`.
struct PurchaseDetailView: View {
    let purchaseID: UUID

    @Environment(InventoryModel.self) private var inventory
    @Environment(ScannerLauncher.self) private var launcher
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var purchases: [Purchase]
    @State private var confirmDelete = false
    @State private var showBlocked = false
    @State private var editing = false
    @State private var addingCards = false
    @State private var ripTarget: TagSheetTarget?
    @State private var pullsTarget: PurchaseItem?

    init(purchaseID: UUID) {
        self.purchaseID = purchaseID
        _purchases = Query(filter: #Predicate<Purchase> { $0.id == purchaseID })
    }

    private var purchase: Purchase? { purchases.first }

    /// Everything on the purchase, the unopened packs too.
    private var allCards: [OwnedCard] {
        (purchase?.items ?? []).flatMap(\.cards)
    }

    /// Cards, not the packs that stand for themselves.
    private var cards: [OwnedCard] {
        allCards.filter { !$0.isSealedSelf }.sorted { $0.acquiredAt > $1.acquiredAt }
    }

    /// The unopened packs, a sealed self-card each. A pack he sold keeps its
    /// self-card, because its order points at it, so it is left out here.
    private var packs: [OwnedCard] {
        allCards.filter { $0.isSealedSelf && !CardTagIndex.isSold($0) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// One row for each rip that holds a line of this purchase.
    private var rips: [RipRow] {
        var seen = Set<UUID>()
        var rows: [RipRow] = []
        for item in purchase?.items ?? [] where item.isRipped && !seen.contains(item.id) {
            let group = RipPool.lines(of: item)
            seen.formUnion(group.map(\.id))
            if let home = RipPool.home(of: group) {
                rows.append(RipRow(home: home, group: group))
            }
        }
        return rows
    }

    struct RipRow: Identifiable {
        var home: PurchaseItem
        var group: [PurchaseItem]
        var id: UUID { home.id }
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

                sealedSection

                ripsSection(purchase)

                Section {
                    Button {
                        scanSingles(purchase)
                    } label: {
                        Label("Scan singles from this order", systemImage: "camera")
                    }
                    Button {
                        scanSingles(purchase, search: true)
                    } label: {
                        Label("Add singles from the catalog", systemImage: "magnifyingglass")
                    }
                } footer: {
                    Text("For cards you bought as singles. They are part of the buy, and the total splits over them. For what came out of a pack, rip the pack.")
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
                    // For cards already in inventory that came from this
                    // purchase. Open it is for cards not scanned yet.
                    Button {
                        addingCards = true
                    } label: {
                        Label("Add cards from inventory…", systemImage: "plus.rectangle.on.rectangle")
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
                        if allCards.isEmpty { confirmDelete = true } else { showBlocked = true }
                    }
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
        .sheet(isPresented: $addingCards) {
            if let purchase {
                PurchaseCardsSheet(purchase: purchase) { inventory.invalidateHaystacks() }
            }
        }
        .sheet(item: $pullsTarget) { home in
            RipPullsSheet(home: home) { inventory.invalidateHaystacks() }
        }
        .ripSheet($ripTarget) { inventory.invalidateHaystacks() }
        .task(id: allCards.count) { await inventory.load(for: rips.flatMap { $0.group.flatMap(\.cards) }) }
        .confirmationDialog("Delete this purchase?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deletePurchase() }
        }
        // Deleting a purchase deletes its lines, and the lines own the cards.
        // He removes the cards first, on purpose, or the purchase stays.
        .alert("Cards came out of this purchase", isPresented: $showBlocked) {
            Button("OK") {}
        } message: {
            Text(allCards.count == 1
                ? "1 card in inventory came from this purchase. Delete it first."
                : "\(allCards.count) cards in inventory came from this purchase. Delete them first.")
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
                Text(card.displayName(inventory.hits[card.productId]) ?? "Unknown")
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if card.basisIsAllocated { Text("derived") }
                    if card.basisIsManual { Text("you priced it") }
                    if let set = card.setName(inventory.hits[card.productId]) { Text(set).lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(card.totalBasisCents.asCurrency)
                .font(.callout.monospacedDigit())
        }
    }

    /// The unopened packs, by product.
    @ViewBuilder
    private var sealedSection: some View {
        let packs = packs
        if !packs.isEmpty {
            let byProduct = Dictionary(grouping: packs, by: \.productId)
            let productIds = byProduct.keys.sorted()
            Section {
                ForEach(productIds, id: \.self) { productId in
                    let copies = byProduct[productId] ?? []
                    HStack {
                        Text(inventory.hits[productId]?.name ?? "Sealed product")
                            .lineLimit(2)
                        Spacer()
                        Text("\(copies.count)×")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    ripTarget = TagSheetTarget(cards: packs)
                } label: {
                    Label(packs.count == 1 ? "Rip the pack…" : "Rip packs…", systemImage: "shippingbox.and.arrow.backward")
                }
            } header: {
                Text(packs.count == 1 ? "1 sealed" : "\(packs.count) sealed")
            } footer: {
                Text("Rip them together, and what comes out shares the cost of all of them.")
            }
        }
    }

    /// Each rip: what the packs cost against what came out of them.
    @ViewBuilder
    private func ripsSection(_ purchase: Purchase) -> some View {
        let rips = rips
        if !rips.isEmpty {
            Section {
                ForEach(rips) { rip in
                    ripRow(rip, on: purchase)
                }
            } header: {
                Text(rips.count == 1 ? "Rip" : "Rips")
            } footer: {
                Text("Read the rip, not the card, to see how the opening did. The value leaves out pulls with no price.")
            }
        }
    }

    private func ripRow(_ rip: RipRow, on purchase: Purchase) -> some View {
        let result = RipPool.result(of: rip.group, market: { inventory.marketCents(for: $0) })
        let others = rip.group.compactMap(\.purchase).filter { $0.id != purchase.id }
        var seenOther = Set<UUID>()
        let otherNames = others.filter { seenOther.insert($0.id).inserted }
            .map { $0.vendor.isEmpty ? $0.date.formatted(date: .abbreviated, time: .omitted) : $0.vendor }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(result.packs == 1 ? "1 pack" : "\(result.packs) packs")
                    .font(.body.weight(.semibold))
                Spacer()
                Text((result.netCents >= 0 ? "+" : "−") + abs(result.netCents).asCurrency)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(result.netCents >= 0 ? .green : .red)
            }
            LabeledContent("Cost", value: result.costCents.asCurrency)
                .font(.callout.monospacedDigit())
            LabeledContent(result.pulls == 1 ? "1 pull, value" : "\(result.pulls) pulls, value", value: result.valueCents.asCurrency)
                .font(.callout.monospacedDigit())
            if result.unpriced > 0 {
                Text("\(result.unpriced) with no price")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !otherNames.isEmpty {
                Text("With packs from " + otherNames.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Menu {
                Button {
                    scanPulls(rip.home)
                } label: {
                    Label("Scan them", systemImage: "camera")
                }
                Button {
                    scanPulls(rip.home, search: true)
                } label: {
                    Label("Search the catalog", systemImage: "magnifyingglass")
                }
                Button {
                    pullsTarget = rip.home
                } label: {
                    Label("From inventory…", systemImage: "rectangle.stack")
                }
            } label: {
                Label("Add pulls", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(.vertical, 2)
    }

    /// Start a session already attached to this purchase, so the commit sheet
    /// has nothing left to ask. Its cards are part of the buy.
    /// `search` opens it with the catalog search showing, in place of the camera.
    private func scanSingles(_ purchase: Purchase, search: Bool = false) {
        let session = ScanSession()
        session.purchase = purchase
        modelContext.insert(session)
        try? modelContext.save()
        launcher.open(session, search: search)
    }

    /// More pulls for a rip that already committed. They join its home line.
    private func scanPulls(_ home: PurchaseItem, search: Bool = false) {
        let session = ScanSession()
        session.purchase = home.purchase
        session.ripTarget = home
        modelContext.insert(session)
        try? modelContext.save()
        launcher.open(session, search: search)
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

    /// The card leaves the submission and the fee it carried comes off it.
    /// The slab stays: a cert number on a card is a fact about the card.
    private func remove(_ entry: GradingEntry) {
        if let card = entry.card {
            let editor = CardTagEditor(context: modelContext)
            for label in ReservedTag.allAtGrader { editor.remove(label, from: [card]) }
            if card.status == .atGrader { card.status = .owned }
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
