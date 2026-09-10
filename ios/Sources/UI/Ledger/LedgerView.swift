import SwiftData
import SwiftUI

/// Money in and money out, one list, newest first.
///
/// The 93 purchases, 8 grading charges, and 131 sales that came out of
/// BinderBooks had nowhere to be read. This is that place.
struct LedgerView: View {
    @Query(sort: \Purchase.date, order: .reverse) private var purchases: [Purchase]
    @Query private var grading: [GradingSubmission]
    @Query(sort: \Sale.soldAt, order: .reverse) private var sales: [Sale]

    @State private var filter: LedgerFilter
    @State private var adding: Bool

    /// The defaults are the only thing the app uses. The arguments exist so a
    /// screenshot run can reach a state that simctl cannot tap its way to.
    init(filter: LedgerFilter = .all, adding: Bool = false) {
        _filter = State(initialValue: filter)
        _adding = State(initialValue: adding)
    }

    private var months: [LedgerMonth] {
        let all = LedgerEntry.entries(purchases: purchases, grading: grading, sales: sales)
        return LedgerMonth.group(all.filter(filter.keeps))
    }

    private var moneyIn: Int { months.reduce(0) { $0 + $1.moneyInCents } }
    private var moneyOut: Int { months.reduce(0) { $0 + $1.moneyOutCents } }

    /// One side of the books shows one number. A "$0.00 out" on the In filter
    /// is a total he did not ask for.
    private func header(for month: LedgerMonth) -> String {
        switch filter {
        case .all: return "\(month.moneyInCents.asCurrency) in · \(month.moneyOutCents.asCurrency) out"
        case .moneyIn: return month.moneyInCents.asCurrency
        case .moneyOut: return month.moneyOutCents.asCurrency
        }
    }

    var body: some View {
        List {
            // Only the whole ledger gets the summary. On one side of the books
            // a difference is not a difference, and the other side's total is
            // a number he did not ask to see.
            if filter == .all {
                Section {
                    LabeledContent("Money in", value: moneyIn.asCurrency)
                    LabeledContent("Money out", value: moneyOut.asCurrency)
                    LabeledContent("Difference") {
                        Text((moneyIn - moneyOut).asCurrency)
                            .foregroundStyle(moneyIn >= moneyOut ? Color.green : Color.primary)
                    }
                } footer: {
                    // docs/04: August's buying is largely still sitting in
                    // inventory or at a grader. Cash flow is not profit, and
                    // saying so here costs one line and stops a wrong read.
                    Text("Cash in and out, not profit. What you bought and still hold is not a loss.")
                }
            }

            ForEach(months) { month in
                Section {
                    ForEach(month.entries) { entry in
                        NavigationLink(value: entry.kind) {
                            LedgerRow(entry: entry)
                        }
                    }
                } header: {
                    HStack {
                        Text(month.title)
                        Spacer()
                        Text(header(for: month))
                    }
                }
            }

            if months.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Tap the plus to record a purchase, an order, or a grading charge.")
                )
            }
        }
        .navigationTitle("Ledger")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Label("Add transaction", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $adding) {
            AddTransactionSheet { _ in }
        }
        // The picker sits under the bar, not in it. In the bar it crowds the
        // title and the back button on a smaller phone.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Picker("Show", selection: $filter) {
                    ForEach(LedgerFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                Divider()
            }
            .background(.bar)
        }
    }
}

struct LedgerRow: View {
    let entry: LedgerEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                Text(entry.detail.isEmpty ? entry.date.formatted(date: .abbreviated, time: .omitted)
                     : "\(entry.date.formatted(date: .abbreviated, time: .omitted)) · \(entry.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Text(amount)
                .font(.body.monospacedDigit())
                .foregroundStyle(entry.isMoneyIn ? Color.green : Color.primary)
        }
    }

    /// Money out reads with a minus, so a statement scans without a legend.
    private var amount: String {
        entry.isMoneyIn ? entry.amountCents.asCurrency : "−" + (-entry.amountCents).asCurrency
    }
}
