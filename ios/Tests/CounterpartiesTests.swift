import Testing
@testable import BinderBooks

/// The who list on the ledger sheets comes from the names he used before.
@Suite struct CounterpartiesTests {
    @Test func mostUsedFirstAndOneEntryForEachStore() {
        let names = Counterparties.names([
            "Gamecraft", "Whatnot", "GameCraft", "Gamecraft", " Whatnot ", "Amazon", "", "  ", "Walmart",
        ])
        // Gamecraft 3, Whatnot 2, then Amazon and Walmart once each, alphabetical.
        #expect(names == ["Gamecraft", "Whatnot", "Amazon", "Walmart"])
    }

    @Test func aTieInSpellingKeepsTheCapitalizedOne() {
        #expect(Counterparties.names(["cgc", "CGC", "psa", "PSA", "PSA"]) == ["PSA", "CGC"])
    }

    @Test func matchIgnoresCaseAndSpaces() {
        let options = ["Gamecraft", "Whatnot"]
        #expect(Counterparties.match(" gamecraft ", in: options) == "Gamecraft")
        #expect(Counterparties.match("Game Grid", in: options) == nil)
        #expect(Counterparties.match("", in: options) == nil)
    }
}
