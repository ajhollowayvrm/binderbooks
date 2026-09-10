import SwiftUI

/// Picks one set out of 863 by typing, grouped by category, newest first.
/// The chip row opens it. Choosing a set with an empty query browses the set.
struct SetPickerSheet: View {
    var sets: [SetSummary]
    var selected: Int?
    var onPick: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [SetSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return sets }
        let clean = NameCleaner.clean(needle)
        return sets.filter {
            NameCleaner.clean($0.name).contains(clean)
                || ($0.abbreviation.map { NameCleaner.clean($0).contains(clean) } ?? false)
        }
    }

    private var grouped: [(category: String, sets: [SetSummary])] {
        var order: [String] = []
        var buckets: [String: [SetSummary]] = [:]
        for set in filtered {
            if buckets[set.categoryName] == nil { order.append(set.categoryName) }
            buckets[set.categoryName, default: []].append(set)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if selected != nil {
                    Button("Any set") {
                        onPick(nil)
                        dismiss()
                    }
                }
                ForEach(grouped, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.sets) { set in
                            Button {
                                onPick(set.groupId)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(set.name)
                                            .foregroundStyle(.primary)
                                        HStack(spacing: 6) {
                                            if let abbreviation = set.abbreviation, !abbreviation.isEmpty {
                                                Text(abbreviation)
                                            }
                                            if let date = set.publishedOn?.prefix(10) {
                                                Text(date)
                                            }
                                            Text("\(set.productCount) products")
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if set.groupId == selected {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Set name or code")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
