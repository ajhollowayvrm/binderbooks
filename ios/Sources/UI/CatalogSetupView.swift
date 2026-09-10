import SwiftUI

/// First run. The app is useless without a catalog, so this is the whole screen
/// until the download finishes.
struct CatalogSetupView: View {
    @Environment(CatalogController.self) private var catalog

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            switch catalog.state {
            case .missing, .working(.checking):
                ProgressView()
                Text("Checking for the catalog")
                    .foregroundStyle(.secondary)
            case .working(.downloading(let fraction)):
                ProgressView(value: fraction)
                    .frame(maxWidth: 280)
                Text("Downloading the catalog, \(Int(fraction * 100))%")
                    .foregroundStyle(.secondary)
            case .working(.verifying):
                ProgressView()
                Text("Verifying and unpacking")
                    .foregroundStyle(.secondary)
            case .ready:
                EmptyView()
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("The catalog did not install")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Try again") {
                    Task { await catalog.check() }
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Installed catalog details and a manual check. Reached from the toolbar.
struct CatalogStatusView: View {
    @Environment(CatalogController.self) private var catalog

    var body: some View {
        List {
            if let meta = catalog.meta {
                Section("Installed") {
                    LabeledContent("Products", value: meta.productCount.formatted())
                    LabeledContent("Source date", value: meta.sourceDate)
                    LabeledContent("Built", value: meta.builtAt)
                    LabeledContent("Schema", value: "\(meta.schemaVersion)")
                }
                Section("Categories") {
                    ForEach(meta.categories, id: \.categoryId) { category in
                        LabeledContent(category.name, value: category.productCount.formatted())
                    }
                }
            } else {
                Section {
                    Text("No catalog installed.")
                        .foregroundStyle(.secondary)
                }
            }

            if let pending = catalog.pendingManifest {
                Section("Waiting") {
                    Text("A catalog from \(pending.sourceDate) is downloaded. It installs when the current scan session ends.")
                        .font(.footnote)
                }
            }

            Section {
                Button {
                    Task { await catalog.check() }
                } label: {
                    HStack {
                        Text("Check now")
                        Spacer()
                        if case .working = catalog.state {
                            ProgressView()
                        }
                    }
                }
                .disabled({ if case .working = catalog.state { return true } else { return false } }())
                if let checked = catalog.lastCheckedAt {
                    LabeledContent("Last check", value: checked.formatted(date: .abbreviated, time: .shortened))
                }
                if let error = catalog.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("The app also checks on every launch. A new catalog is published daily at about 21:30 UTC.")
            }
        }
        .navigationTitle("Catalog")
    }
}
