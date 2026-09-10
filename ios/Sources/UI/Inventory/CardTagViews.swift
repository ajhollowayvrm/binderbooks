import SwiftData
import SwiftUI

/// The labels on one card, as small capsules. Hidden when the card has none,
/// so an untagged inventory looks exactly as it did before tags existed.
struct TagBadgeRow: View {
    var tags: [String]
    var limit = 3

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags.prefix(limit), id: \.self) { tag in
                    Text(tag)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                if tags.count > limit {
                    Text("+\(tags.count - limit)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
        }
    }
}

/// What the tag sheet applies to. One case, because the only difference
/// between one card and thirty is the footer text.
struct TagSheetTarget: Identifiable {
    var cards: [OwnedCard]

    var id: String { cards.map(\.id.uuidString).sorted().joined(separator: ",") }
}

/// The tag editor. It follows the `ChoiceSheet` shape from the review screen:
/// a navigation stack, medium detents, and a cancel item.
///
/// Every action writes at once. There is no Save button, which matches how the
/// card detail screen writes every edit.
struct TagSheet: View {
    var target: TagSheetTarget
    var uses: [TagUse]
    /// Every committed card. A rename must reach the labels on cards that are
    /// not part of the current selection.
    var allCards: [OwnedCard]
    var onChange: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var renaming: TagUse?
    @State private var renameText = ""

    private var editor: CardTagEditor { CardTagEditor(context: context) }

    private var filtered: [TagUse] {
        let key = TagKey.of(draft)
        guard !key.isEmpty else { return uses }
        return uses.filter { $0.id.contains(key) }
    }

    private var draftIsNew: Bool {
        let key = TagKey.of(draft)
        return !key.isEmpty && !uses.contains { $0.id == key }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("New label", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(applyDraft)
                    if draftIsNew {
                        Button {
                            applyDraft()
                        } label: {
                            Label("Create \"\(TagKey.display(draft))\"", systemImage: "plus.circle")
                        }
                    }
                }

                Section {
                    if filtered.isEmpty {
                        Text(uses.isEmpty ? "No labels yet. Type one above." : "No label matches.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { use in
                        Button {
                            editor.toggle(use.label, on: target.cards)
                            onChange()
                        } label: {
                            HStack {
                                Image(systemName: mark(for: use))
                                    .foregroundStyle(.tint)
                                Text(use.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(use.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Rename") {
                                renaming = use
                                renameText = use.label
                            }
                        }
                    }
                } footer: {
                    Text(target.cards.count == 1 ? "Applies to this card." : "Applies to \(target.cards.count) cards.")
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename label", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Label", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    if let old = renaming {
                        editor.rename(old.label, to: renameText, in: allCards)
                        onChange()
                    }
                    renaming = nil
                }
            } message: {
                Text("Renames the label on every card that carries it.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func mark(for use: TagUse) -> String {
        let held = target.cards.filter { CardTagIndex.has(use.label, on: $0) }.count
        if held == 0 { return "circle" }
        if held == target.cards.count { return "checkmark.circle.fill" }
        return "minus.circle.fill"
    }

    private func applyDraft() {
        let label = TagKey.display(draft)
        guard TagKey.isValid(label) else { return }
        editor.add(label, to: target.cards)
        draft = ""
        onChange()
    }
}

/// Picks the labels the inventory filters by. Select only; it never edits a card.
struct TagFilterSheet: View {
    var uses: [TagUse]
    @Binding var selected: Set<String>

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if uses.isEmpty {
                    Text("No labels yet. Tag a card first.")
                        .foregroundStyle(.secondary)
                }
                ForEach(uses) { use in
                    Button {
                        if selected.contains(use.id) {
                            selected.remove(use.id)
                        } else {
                            selected.insert(use.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: selected.contains(use.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(.tint)
                            Text(use.label)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(use.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Filter by tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !selected.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear") { selected = [] }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
