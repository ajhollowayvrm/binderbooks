import SwiftUI

/// The plus button's screen. Two roads to one new card: the camera, or a
/// catalog search he types into. A card the catalog does not carry has a
/// third road at the bottom of the search, by hand.
///
/// The scanner is a full-screen cover that `RootView` owns, so the Scan button
/// closes this sheet and hands the open to the root.
struct AddCardSheet: View {
    /// The card count of the open scan session, if there is one.
    var openSessionCount: Int?
    /// Called before the sheet dismisses. The root opens the scanner when the
    /// dismissal ends.
    var onScan: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(CatalogController.self) private var catalog
    @State private var search = SearchModel(context: .intake)
    @State private var target: AddTarget?
    @State private var loadingProductId: Int?
    @State private var errorMessage: String?
    /// Set by the add form on save. The form's dismiss then closes this sheet
    /// too, because the card he came for is in.
    @State private var didAdd = false

    enum AddTarget: Identifiable {
        case product(ProductDetail)
        case handEntry(String)

        var id: String {
            switch self {
            case .product(let detail): return "product-\(detail.hit.productId)"
            case .handEntry: return "hand"
            }
        }
    }

    var body: some View {
        @Bindable var search = search
        NavigationStack {
            List {
                Section {
                    Button {
                        onScan()
                        dismiss()
                    } label: {
                        Label(
                            openSessionCount.map { "Resume scan (\($0) cards)" } ?? "Scan with the camera",
                            systemImage: "camera"
                        )
                    }
                    .disabled(!catalog.isReady)
                } footer: {
                    if !catalog.isReady {
                        Text("The scanner needs the catalog. You can still add a card by hand.")
                    }
                }

                Section {
                    catalogRows
                    if !search.isSearching {
                        Button {
                            target = .handEntry(search.text)
                        } label: {
                            Label("Not in the catalog? Add it by hand", systemImage: "square.and.pencil")
                        }
                    }
                } header: {
                    Text("Or enter it").textCase(nil)
                }
            }
            .searchable(text: $search.text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or number")
            .navigationTitle("Add a card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                search.database = { [weak catalog] in catalog?.database }
            }
            .sheet(item: $target, onDismiss: {
                if didAdd { dismiss() }
            }) { target in
                switch target {
                case .product(let detail):
                    AddToInventorySheet(detail: detail) { didAdd = true }
                case .handEntry(let name):
                    AddToInventorySheet(handEnteredName: name) { didAdd = true }
                }
            }
            .alert("Could not load", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var catalogRows: some View {
        if catalog.database == nil {
            Text("The catalog is not installed yet.")
                .foregroundStyle(.secondary)
        } else if search.isEmptyQuery {
            Text("Type a name or a number to search the catalog.")
                .foregroundStyle(.secondary)
        } else if search.hits.isEmpty, !search.isSearching {
            Text("No product matches.")
                .foregroundStyle(.secondary)
        }
        ForEach(search.hits.prefix(40)) { hit in
            Button {
                Task { await pick(hit) }
            } label: {
                HStack {
                    ProductRow(hit: hit)
                    if loadingProductId == hit.productId {
                        ProgressView()
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(loadingProductId != nil)
        }
    }

    /// The add form needs the printings and their prices, which a hit does not
    /// carry.
    private func pick(_ hit: SearchHit) async {
        guard let db = catalog.database else { return }
        loadingProductId = hit.productId
        defer { loadingProductId = nil }
        do {
            if let detail = try await CatalogSearch(database: db).detail(productId: hit.productId) {
                target = .product(detail)
            } else {
                errorMessage = "Product \(hit.productId) is not in the installed catalog."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
