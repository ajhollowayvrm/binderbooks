import SwiftData
import SwiftUI

/// One set, read two ways.
///
/// As a **checklist**, from the set chip on the inventory page and the search
/// page: collector order, and the cards he lacks faded, because the question is
/// what is still missing.
///
/// As a **reference**, from the Sets button: dearest card first and nothing
/// faded, because the question is "what is the most expensive card in Fusion
/// Strike" and the answer should be the first row. Fading four fifths of a
/// 284-card set greys the whole screen and buries it.
///
/// One view, because the two differ only in where they start. He can sort
/// either one either way once it is open, and the progress figures are worth
/// having in both.
///
/// The search field narrows the list by name or number. The layout button
/// rules it the same as every other card list.
struct MasterSetView: View {
    var groupId: Int
    var query: String = ""
    /// The set name, for a pushed screen's title. Empty when the view is swapped
    /// in under the search field, which has its own title.
    var title: String = ""
    var style: Style = .checklist

    enum Style { case checklist, reference }

    enum Sort: String, CaseIterable, Identifiable {
        case number = "Number", value = "Value"
        var id: String { rawValue }
        var symbol: String { self == .number ? "number" : "dollarsign" }
    }

    @Environment(CatalogController.self) private var catalog
    @Query private var cards: [OwnedCard]
    @AppStorage(cardLayoutKey) private var layout: CardLayout = .grid
    @State private var contents: (hits: [SearchHit], prices: [Int: [ProductPrice]])?
    @State private var show: Show = .all
    @State private var sort: Sort
    @State private var errorMessage: String?

    init(groupId: Int, query: String = "", title: String = "", style: Style = .checklist) {
        self.groupId = groupId
        self.query = query
        self.title = title
        self.style = style
        _sort = State(initialValue: style == .reference ? .value : .number)
    }

    enum Show: String, CaseIterable, Identifiable {
        case all = "All", missing = "Missing", have = "Have"
        var id: String { rawValue }
    }

    private var masterSet: MasterSet? {
        contents.map { MasterSet.build(hits: $0.hits, prices: $0.prices, owned: MasterSet.ownedCopies(cards)) }
    }

    var body: some View {
        Group {
            if let masterSet {
                if masterSet.slots.isEmpty {
                    ContentUnavailableView("No singles in this set", systemImage: "square.stack",
                                           description: Text("The catalog lists only sealed product for it."))
                } else {
                    checklist(masterSet)
                }
            } else if let errorMessage {
                ContentUnavailableView("The set did not load", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // Keyed on the price version too, so a price refresh updates the cost
        // to finish.
        .task(id: "\(groupId)#\(catalog.database?.path ?? "")#\(catalog.version)") {
            await load()
        }
    }

    private func load() async {
        guard let db = catalog.database else { return }
        do {
            contents = try await CatalogSearch(database: db).masterSetContents(groupId: groupId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - The checklist

    private func visible(_ masterSet: MasterSet) -> [MasterSet.Slot] {
        let needle = NameCleaner.clean(query.trimmingCharacters(in: .whitespaces))
        let kept = masterSet.slots.filter { slot in
            switch show {
            case .all: break
            case .missing: if slot.isOwned { return false }
            case .have: if !slot.isOwned { return false }
            }
            guard !needle.isEmpty else { return true }
            return NameCleaner.clean(slot.hit.name).contains(needle) || (slot.hit.number?.lowercased().contains(needle) ?? false)
        }
        return sorted(kept)
    }

    /// `MasterSet.build` returns collector order, so number sorting is already
    /// done and only value needs a pass.
    private func sorted(_ slots: [MasterSet.Slot]) -> [MasterSet.Slot] {
        sort == .value ? MasterSet.byValue(slots) : slots
    }

    @ViewBuilder
    private func checklist(_ masterSet: MasterSet) -> some View {
        let slots = visible(masterSet)
        switch layout {
        case .list:
            // The header is a row, not a section header. A plain list draws
            // a section header faded and pins it over the rows.
            List {
                header(masterSet)
                    .listRowSeparator(.hidden)
                ForEach(slots) { slot in
                    NavigationLink(value: slot.hit) {
                        MasterSetRow(slot: slot, fadeMissing: style == .checklist)
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        case .grid:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(masterSet)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 14) {
                        ForEach(slots) { slot in
                            NavigationLink(value: slot.hit) {
                                MasterSetCell(slot: slot, fadeMissing: style == .checklist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    /// The progress, the money on each side of it, and the three views.
    private func header(_ masterSet: MasterSet) -> some View {
        let total = masterSet.slots.count
        let have = masterSet.ownedSlots
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(have) of \(total)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                Spacer()
                Text(total == 0 ? "" : "\(have * 100 / total)%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(have), total: Double(max(total, 1)))
            HStack(spacing: 16) {
                figure("Have", masterSet.ownedValueCents.asCurrency)
                figure("To finish", masterSet.costToFinishCents.asCurrency)
                Spacer()
                // A menu, not a third segmented control. The header already
                // carries one, and two is a control panel.
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                    }
                } label: {
                    Label(sort.rawValue, systemImage: "arrow.up.arrow.down")
                        .font(.subheadline)
                }
            }
            if masterSet.unpricedMissing > 0 {
                Text("To finish leaves out \(masterSet.unpricedMissing) missing \(masterSet.unpricedMissing == 1 ? "card" : "cards") with no market price.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Show", selection: $show) {
                ForEach(Show.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.medium))
        }
    }
}

/// One slot in the list layout. The check leads, because it is the answer
/// the page exists to give.
private struct MasterSetRow: View {
    var slot: MasterSet.Slot
    /// Reading a set, the check alone says what he holds. Fading the rest
    /// would grey four fifths of the screen.
    var fadeMissing: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: slot.isOwned ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(slot.isOwned ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
            ProductThumbnail(urlString: slot.hit.imageUrl, isSealed: false)
                .frame(width: 36, height: 50)
                .opacity(slot.isOwned || !fadeMissing ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.hit.name)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let number = slot.hit.number {
                        Text(number).monospacedDigit()
                    }
                    if let printing = slot.printing {
                        Text(printing)
                    }
                    if slot.ownedCount > 1 {
                        Text("×\(slot.ownedCount)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                unsetNote(slot)
            }
            Spacer(minLength: 8)
            Text(slot.marketCents?.asCurrency ?? "No price")
                .font(slot.marketCents == nil ? .caption : .body.monospacedDigit())
                .foregroundStyle(slot.marketCents == nil ? .tertiary : .primary)
        }
        .padding(.vertical, 2)
    }
}

/// One slot in the grid layout. A missing card is faded and gray, the way an
/// empty pocket in a binder reads.
private struct MasterSetCell: View {
    var slot: MasterSet.Slot
    var fadeMissing: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: slot.hit.largeImageURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    Rectangle().fill(.fill.quaternary)
                }
            }
            .aspectRatio(5.0 / 7.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .saturation(slot.isOwned || !fadeMissing ? 1 : 0)
            .opacity(slot.isOwned || !fadeMissing ? 1 : 0.4)
            .overlay(alignment: .topTrailing) {
                if slot.isOwned {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.title3)
                        .padding(4)
                }
            }
            Text(slot.marketCents?.asCurrency ?? "No price")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(slot.marketCents == nil ? .tertiary : .primary)
                .lineLimit(1)
            // The name stays, because the pattern prints share one number
            // and one piece of art, and only the name tells them apart.
            Text(slot.hit.name)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let number = slot.hit.number {
                Text(number)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Only a product with more than one printing names it. On a set
            // with one printing per card it would repeat on every cell.
            if slot.hit.printingCount > 1, let printing = slot.printing {
                Text(printing)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            unsetNote(slot)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A copy with no printing set fills no slot. The note says so, so he can
/// open the card and set its printing.
@ViewBuilder
private func unsetNote(_ slot: MasterSet.Slot) -> some View {
    if slot.unsetPrintingCount > 0 {
        Text("\(slot.unsetPrintingCount) held with no printing set")
            .font(.caption2)
            .foregroundStyle(.orange)
            .lineLimit(2)
    }
}
