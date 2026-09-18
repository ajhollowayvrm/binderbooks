import SwiftUI

/// Refresh prices, when TCGCSV has newer ones than his cards carry.
///
/// Refresh is enabled only then. TCGCSV updates once a day, so a refresh
/// before its next update returns the same prices it replaces. The inventory's
/// sort menu and the Catalog screen both show it.
struct PriceRefreshButton: View {
    /// The products whose prices matter: his unsold, identified cards.
    var productIds: [Int]
    /// In a menu, the second line is a subtitle. In a list, it sits below.
    var inMenu = true

    @Environment(CatalogController.self) private var catalog

    enum Action: Equatable {
        case refresh
        case check
    }

    struct Presentation: Equatable {
        var title: String
        var detail: String?
        var systemImage: String
        /// Nil when the button does nothing, and so is disabled.
        var action: Action?
    }

    static func presentation(_ state: CatalogController.PriceState) -> Presentation {
        switch state {
        case .unknown, .checking:
            return Presentation(title: "Checking for new prices…", detail: nil, systemImage: "clock", action: nil)
        case .current(let source):
            return Presentation(title: "Prices are current", detail: "TCGCSV last updated \(day(source))", systemImage: "checkmark.circle", action: nil)
        case .available(let source, let oldest):
            return Presentation(title: "Refresh prices", detail: "TCGCSV has \(day(source)) prices. Yours are from \(day(oldest)).", systemImage: "arrow.clockwise", action: .refresh)
        case .refreshing(let done, let total):
            return Presentation(title: "Refreshing prices…", detail: "\(done) of \(total) sets", systemImage: "arrow.clockwise", action: nil)
        case .failed(let message):
            return Presentation(title: "Check for new prices", detail: message, systemImage: "exclamationmark.triangle", action: .check)
        }
    }

    /// "2026-09-17" to "Sep 17". The text is a UTC date, and it stays that date.
    static func day(_ text: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: text) else { return text }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US")
        out.timeZone = TimeZone(identifier: "UTC")
        out.dateFormat = "MMM d"
        return out.string(from: date)
    }

    var body: some View {
        let shown = Self.presentation(catalog.priceState)
        Button {
            switch shown.action {
            case .refresh: Task { await catalog.refreshPrices(for: productIds) }
            case .check: Task { await catalog.checkPrices(for: productIds) }
            case nil: break
            }
        } label: {
            if inMenu {
                Label(shown.title, systemImage: shown.systemImage)
                if let detail = shown.detail { Text(detail) }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Label(shown.title, systemImage: shown.systemImage)
                    if let detail = shown.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(shown.action == nil)
    }
}
