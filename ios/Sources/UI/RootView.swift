import SwiftUI

/// The app shell: a persistent search field with a camera button, above the
/// content. Not a search tab. Search itself arrives in step 3 and the scanner in
/// step 4. Until then the field is present but inert, so the layout is settled
/// before either lands.
struct RootView: View {
    @Environment(CatalogController.self) private var catalog
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SearchHeader(query: $query, enabled: catalog.isReady)
                Divider()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        CatalogStatusView()
                    } label: {
                        Label("Catalog", systemImage: "externaldrive")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if catalog.isReady {
            HomePlaceholder()
        } else {
            CatalogSetupView()
        }
    }
}

struct SearchHeader: View {
    @Binding var query: String
    var enabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search cards and sealed", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!enabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))

            Button {
                // Step 4: the scan session.
            } label: {
                Image(systemName: "camera")
                    .font(.title3)
                    .frame(width: 40, height: 36)
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .accessibilityLabel("Scan")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// The empty-query home. Step 3 fills it with recent purchases, unripped sealed,
/// and cards flagged from scans.
private struct HomePlaceholder: View {
    @Environment(CatalogController.self) private var catalog

    var body: some View {
        ContentUnavailableView {
            Label("Catalog ready", systemImage: "checkmark.circle")
        } description: {
            if let meta = catalog.meta {
                Text("\(meta.productCount.formatted()) products, built \(meta.sourceDate).")
            }
        }
    }
}
