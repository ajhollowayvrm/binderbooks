import SwiftUI

/// Who he bought from, sold through, graded with, or paid: a menu of the
/// names he used before, and "New…" for a name he has not used.
///
/// "New…" turns the row into a text field. A name that is not in the list,
/// for example a vendor a receipt filled in, also shows as a text field, so
/// the menu never hides what the entry holds. The list button goes back to
/// the menu. With no names yet, the row is only a text field.
struct CounterpartyField: View {
    /// The menu's label: "Vendor", "Channel".
    let title: String
    /// The text field's placeholder: "Vendor, e.g. Gamecraft".
    let placeholder: String
    @Binding var text: String
    /// From `Counterparties.names`.
    let options: [String]

    @State private var typing = false
    @FocusState private var focused: Bool

    private static let newTag = "\u{0}new"

    private var showsField: Bool {
        options.isEmpty || typing || (!text.isEmpty && Counterparties.match(text, in: options) == nil)
    }

    var body: some View {
        if showsField {
            HStack {
                TextField(placeholder, text: $text)
                    .textInputAutocapitalization(.words)
                    .focused($focused)
                    .onAppear { if typing { focused = true } }
                if !options.isEmpty {
                    Button {
                        typing = false
                        text = ""
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Pick from the list")
                }
            }
        } else {
            Picker(title, selection: selection) {
                if text.isEmpty { Text("Choose").tag("") }
                ForEach(options, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("New…").tag(Self.newTag)
            }
            .pickerStyle(.menu)
        }
    }

    private var selection: Binding<String> {
        Binding {
            Counterparties.match(text, in: options) ?? ""
        } set: { picked in
            if picked == Self.newTag {
                text = ""
                typing = true
            } else {
                text = picked
            }
        }
    }
}
