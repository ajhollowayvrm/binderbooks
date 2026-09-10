import SwiftUI

/// A capsule toggle. The chip rows replace every dropdown the old app had.
struct Chip: View {
    var title: String
    var systemImage: String? = nil
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                }
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: Capsule())
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The filter row under the search field: kind, set, and category chips.
struct FilterChipRow: View {
    @Bindable var model: SearchModel
    @Binding var showSetPicker: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.Kind.allCases, id: \.self) { kind in
                    Chip(title: kind.title, isSelected: model.filter.kind == kind) {
                        model.filter.kind = kind
                    }
                }

                Divider()
                    .frame(height: 20)

                if let set = model.selectedSet {
                    Chip(title: set.name, systemImage: "xmark", isSelected: true) {
                        model.filter.groupId = nil
                    }
                } else {
                    Chip(title: "Set", systemImage: "square.stack", isSelected: false) {
                        showSetPicker = true
                    }
                }

                ForEach(model.categories) { category in
                    Chip(title: category.chipTitle, isSelected: model.filter.categoryIds.contains(category.categoryId)) {
                        model.toggleCategory(category.categoryId)
                    }
                }

                if model.filter.isActive {
                    Button("Clear") { model.clearFilters() }
                        .font(.subheadline)
                        .padding(.leading, 4)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }
}
