import Foundation
import Testing
@testable import BinderBooks

@Suite struct GradedCompsTests {
    let comps = ["PSA 10": 12_000, "PSA 9": 4_000, "PSA 8": 2_500, "CGC 10": 9_000, "10": 11_000]

    @Test func rangeIsLowestToHighestForOneGrader() {
        #expect(GradedComps.range(for: "psa", in: comps) == 2_500...12_000)
        #expect(GradedComps.range(for: "PSA", in: comps) == 2_500...12_000)
        #expect(GradedComps.range(for: "cgc", in: comps) == 9_000...9_000)
    }

    @Test func aBareGradeBelongsToNoGrader() {
        #expect(GradedComps.range(for: "psa", in: ["10": 11_000]) == nil)
        #expect(GradedComps.range(for: "bgs", in: comps) == nil)
    }

    @Test func theLabelSaysWhichGraderHasTheCard() {
        #expect(GradedComps.graderAtGrader(tags: ["binder 3", "at PSA"]) == "psa")
        #expect(GradedComps.graderAtGrader(tags: ["AT  cgc"]) == "cgc")
        #expect(GradedComps.graderAtGrader(tags: ["at grader"]) == nil)
        #expect(GradedComps.graderAtGrader(tags: []) == nil)
    }

    @Test func sendingWritesTheGradersOwnLabel() {
        #expect(ReservedTag.atGrader("psa") == "at PSA")
        #expect(ReservedTag.atGrader("CGC") == "at CGC")
        #expect(ReservedTag.atGrader("bgs") == "at grader")
    }

    @Test func theGradeItGotNamesItsOwnFigure() {
        #expect(GradedComps.compKey(grader: "cgc", grade: "Pristine 10") == "CGC Pristine 10")
        #expect(GradedComps.value(grader: "psa", grade: "9", in: comps) == 4_000)
        // He types a grade himself, so the lookup folds case the way a tag does.
        #expect(GradedComps.value(grader: "PSA", grade: "10", in: comps) == 12_000)
        #expect(GradedComps.value(grader: "cgc", grade: "Pristine 10", in: comps) == nil)
        #expect(GradedComps.value(grader: nil, grade: "10", in: comps) == nil)
        #expect(GradedComps.value(grader: "psa", grade: nil, in: comps) == nil)
    }

    @Test @MainActor func aKnownGradeReplacesTheProjection() {
        let card = OwnedCard(productId: 1, printing: "Holofoil", condition: "Near Mint", confidence: .manual)
        card.gradedCompCents = ["PSA 10": 12_000, "PSA 9": 4_000, "PSA 8": 2_500]
        card.acquisitionBasisCents = 3_000
        card.tags = ["at PSA"]

        let out = InventoryRow(card: card, hit: nil, marketCents: 500)
        #expect(out.projectedRange == 2_500...12_000)
        #expect(out.priceText == "$25.00–$120.00")

        // It came back a 9. The range is a question already answered.
        card.tags = ["graded"]
        card.graderRaw = "psa"
        card.gradeLabel = "9"
        let back = InventoryRow(card: card, hit: nil, marketCents: 500)
        #expect(back.projectedRange == nil)
        #expect(back.gradedValueCents == 4_000)
        #expect(back.priceText == "$40.00")
        // The gain counts against the slab, not the raw card.
        #expect(back.unrealizedCents == 1_000)
    }

    @Test func rangeTextCollapsesWhenTheCompsAgree() {
        #expect(GradedComps.rangeText(2_500...12_000) == "$25.00–$120.00")
        #expect(GradedComps.rangeText(9_000...9_000) == "$90.00")
    }
}
