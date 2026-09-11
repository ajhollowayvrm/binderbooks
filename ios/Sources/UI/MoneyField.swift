import SwiftUI

/// A labelled cents field. Decimal keyboard, right-aligned, two decimals.
struct MoneyField: View {
    var label: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0.00", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .frame(maxWidth: 140)
        }
    }
}
