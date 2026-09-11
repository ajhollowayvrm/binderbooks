import SwiftData
import SwiftUI

/// The books, in two halves.
///
/// `Activity` is money in and money out, one list, newest first — the 93
/// purchases, 8 grading charges, and 131 sales that came out of BinderBooks had
/// nowhere to be read, and this is that place. `Summary` is how it is going.
///
/// The split exists because those are two different readings. A statement is
/// read row by row; a profit figure is read on its own. Mixing them put a
/// summary card on top of 300 rows where it was both in the way and easy to
/// mistake for profit.
struct LedgerView: View {
    @Query(sort: \Purchase.date, order: .reverse) private var purchases: [Purchase]
    @Query private var grading: [GradingSubmission]
    @Query(sort: \Sale.soldAt, order: .reverse) private var sales: [Sale]
    @Query(sort: \BusinessExpense.date, order: .reverse) private var expenses: [BusinessExpense]

    @State private var tab: LedgerTab
    @State private var filter: LedgerFilter
    @State private var adding: Bool

    /// The defaults are the only thing the app uses. The arguments exist so a
    /// screenshot run can reach a state that simctl cannot tap its way to.
    init(tab: LedgerTab = .activity, filter: LedgerFilter = .all, adding: Bool = false) {
        _tab = State(initialValue: tab)
        _filter = State(initialValue: filter)
        _adding = State(initialValue: adding)
    }

    private var months: [LedgerMonth] {
        let all = LedgerEntry.entries(purchases: purchases, grading: grading, sales: sales, expenses: expenses)
        return LedgerMonth.group(all.filter(filter.keeps))
    }

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
        Group {
            switch tab {
            case .activity: activity
            case .summary:
                LedgerSummaryView(purchases: purchases, grading: grading, sales: sales, expenses: expenses)
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
                Picker("Show", selection: $tab) {
                    ForEach(LedgerTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                Divider()
            }
            .background(.bar)
        }
    }

    private var activity: some View {
        List {
            // In and Out belong to this list, so the control for them lives in
            // it. Two stacked segmented controls under the bar is one too many.
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(LedgerFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listSectionSpacing(.compact)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))

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
                    description: Text("Tap the plus to record a purchase, an order, a grading charge, or an expense.")
                )
            }
        }
        // The list sits directly under the filter. Its own top inset would put
        // the control adrift in a band of empty space.
        .contentMargins(.top, 0, for: .scrollContent)
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
