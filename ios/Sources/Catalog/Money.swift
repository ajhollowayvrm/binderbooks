import Foundation

/// All money is `Int` cents. This is the one place cents become text.
extension Int {
    /// Cents to "$1,234.56". Always two decimals. `NSDecimalNumber`, never `Double`.
    var asCurrency: String {
        Money.formatter.string(from: NSDecimalNumber(value: self).dividing(by: 100)) ?? "$0.00"
    }
}

enum Money {
    static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    /// Parses typed text into cents. Rejects a third decimal digit.
    static func cents(from text: String) -> Int? {
        let filtered = text.filter { $0.isNumber || $0 == "." }
        guard !filtered.isEmpty, filtered.filter({ $0 == "." }).count <= 1 else { return nil }
        if let dot = filtered.firstIndex(of: "."), filtered.distance(from: dot, to: filtered.endIndex) > 3 {
            return nil
        }
        guard let value = Decimal(string: filtered) else { return nil }
        return NSDecimalNumber(decimal: value * 100).rounding(accordingToBehavior: nil).intValue
    }
}
