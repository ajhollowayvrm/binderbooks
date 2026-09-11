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

    @Test func rangeTextCollapsesWhenTheCompsAgree() {
        #expect(GradedComps.rangeText(2_500...12_000) == "$25.00–$120.00")
        #expect(GradedComps.rangeText(9_000...9_000) == "$90.00")
    }
}
