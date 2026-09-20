import Foundation
import Testing
@testable import BinderBooks

/// One frame is not a reliable read of small print. These cover the merge that
/// replaced the still photo.
@Suite struct ObservationAccumulatorTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func observation(name: String? = nil, number: String? = nil) -> ScanObservation {
        ScanObservation(number: number, name: name, nameCandidates: [name].compactMap { $0 })
    }

    private func observation(lines: [String]) -> ScanObservation {
        ScanObservation(number: nil, name: lines.first, nameCandidates: lines)
    }

    /// The reading that produced a Mawile V: 195 on a card printed 196. One
    /// frame said it and the rest disagreed, so it must lose.
    @Test func theNumberMostFramesAgreeOnWins() {
        var accumulator = ObservationAccumulator()
        accumulator.add(observation(name: "Sableye", number: "070/196"), now: start)
        accumulator.add(observation(name: "Sableye", number: "070/195"), now: start.addingTimeInterval(0.1))
        accumulator.add(observation(name: "Sableye", number: "070/196"), now: start.addingTimeInterval(0.2))

        let merged = accumulator.merged(now: start.addingTimeInterval(0.3))
        #expect(merged.number == "070/196")
        #expect(merged.name == "Sableye")
    }

    /// The reading that produced a Scramble Switch. A frame that missed the
    /// name and took the attack instead is outvoted.
    @Test func aStrayAttackNameIsOutvoted() {
        var accumulator = ObservationAccumulator()
        accumulator.add(observation(name: "Sableye"), now: start)
        accumulator.add(observation(name: "Scratch"), now: start.addingTimeInterval(0.1))
        accumulator.add(observation(name: "Sableye"), now: start.addingTimeInterval(0.2))

        #expect(accumulator.merged(now: start.addingTimeInterval(0.3)).name == "Sableye")
    }

    /// The number and the name rarely land in the same frame. The window is
    /// what puts them together.
    @Test func aNumberFromOneFrameJoinsANameFromAnother() {
        var accumulator = ObservationAccumulator()
        accumulator.add(observation(name: "Sableye"), now: start)
        accumulator.add(observation(number: "070/196"), now: start.addingTimeInterval(0.4))

        let merged = accumulator.merged(now: start.addingTimeInterval(0.5))
        #expect(merged.name == "Sableye")
        #expect(merged.number == "070/196")
    }

    @Test func areadingFallsOutOfTheWindow() {
        var accumulator = ObservationAccumulator()
        accumulator.add(observation(name: "Sableye", number: "070/196"), now: start)
        #expect(accumulator.merged(now: start.addingTimeInterval(5)).isEmpty)
    }

    /// The previous card must not vote on the next one.
    @Test func loggingACardClearsTheWindow() {
        var accumulator = ObservationAccumulator()
        accumulator.add(observation(name: "Sableye", number: "070/196"), now: start)
        accumulator.reset()
        #expect(accumulator.merged(now: start.addingTimeInterval(0.1)).isEmpty)
    }

    @Test func aTieGoesToTheMostRecent() {
        var accumulator = ObservationAccumulator()
        accumulator.add(observation(name: "Sableye"), now: start)
        accumulator.add(observation(name: "Sandshrew"), now: start.addingTimeInterval(0.2))
        #expect(accumulator.merged(now: start.addingTimeInterval(0.3)).name == "Sandshrew")
    }

    /// The matcher checks every line against the catalog, so the merge has to
    /// carry the whole shortlist and not just the winner.
    @Test func everyLineAnyFrameSawSurvivesTheMerge() {
        var accumulator = ObservationAccumulator()
        accumulator.add(observation(lines: ["Scratch", "Sableye"]), now: start)
        accumulator.add(observation(lines: ["Scratch", "Lost Mine"]), now: start.addingTimeInterval(0.1))

        let merged = accumulator.merged(now: start.addingTimeInterval(0.2))
        // Most-seen first, so the attack leads. The catalog sorts that out.
        #expect(merged.name == "Scratch")
        #expect(Set(merged.nameCandidates) == ["Scratch", "Sableye", "Lost Mine"])
    }

    @Test func anEmptyFrameIsNotARead() {
        var accumulator = ObservationAccumulator()
        accumulator.add(ScanObservation(), now: start)
        #expect(accumulator.merged(now: start).isEmpty)
    }

    /// One frame that found the card is enough. The quadrilateral detector
    /// loses the card for a frame at a time while he turns it over, and the
    /// shutter must not refuse a capture over that.
    @Test func oneFrameFindingTheCardSaysTheCardWasThere() {
        var accumulator = ObservationAccumulator()
        var seen = observation(name: "Dedenne", number: "085/195")
        seen.sawCard = true
        accumulator.add(observation(name: "Dedenne", number: "085/195"), now: start)
        accumulator.add(seen, now: start.addingTimeInterval(0.1))
        #expect(accumulator.merged(now: start.addingTimeInterval(0.2)).sawCard)
    }

    /// And no frame finding it says so, which is what stops the scanner
    /// logging the words on his desk.
    @Test func noFrameFindingTheCardSaysItWasNotThere() {
        var accumulator = ObservationAccumulator()
        accumulator.add(observation(name: "Dedenne", number: "085/195"), now: start)
        #expect(!accumulator.merged(now: start).sawCard)
    }

    /// The Toxel logged with Vulpix's name. Vulpix was logged, stayed in view
    /// while he swapped cards, and outvoted Toxel's frames on the name.
    @Test func theCardJustLoggedStaysOutOfTheNextWindow() {
        var accumulator = ObservationAccumulator()
        let vulpix = observation(name: "Vulpix", number: "009/128")
        accumulator.reset(afterLogging: vulpix, now: start)
        for i in 1...6 {
            accumulator.add(observation(name: "Vulpix"), now: start.addingTimeInterval(Double(i) * 0.1))
        }
        accumulator.add(observation(name: "Vulpix", number: "009/128"), now: start.addingTimeInterval(0.7))
        accumulator.add(observation(name: "Toxel"), now: start.addingTimeInterval(0.8))
        accumulator.add(observation(name: "Toxel", number: "058/128"), now: start.addingTimeInterval(0.9))

        let merged = accumulator.merged(now: start.addingTimeInterval(1.0))
        #expect(merged.number == "058/128")
        #expect(merged.nameCandidates == ["Toxel"])
    }

    /// A second copy of the same card logs once the first has left the lens.
    @Test func theLoggedCardIsForgottenOnceItLeaves() {
        var accumulator = ObservationAccumulator()
        let vulpix = observation(name: "Vulpix", number: "009/128")
        accumulator.reset(afterLogging: vulpix, now: start)
        accumulator.add(vulpix, now: start.addingTimeInterval(0.2))
        #expect(accumulator.merged(now: start.addingTimeInterval(0.3)).isEmpty)

        // No frame of it for longer than `loggedAbsence`.
        accumulator.add(vulpix, now: start.addingTimeInterval(1.5))
        #expect(accumulator.merged(now: start.addingTimeInterval(1.6)).number == "009/128")
    }

    /// A card held in view for good cannot block itself for good.
    @Test func theLoggedCardIsForgottenAfterItsLifetime() {
        var accumulator = ObservationAccumulator()
        let vulpix = observation(name: "Vulpix", number: "009/128")
        accumulator.reset(afterLogging: vulpix, now: start)
        var t = 0.0
        while t < accumulator.loggedLifetime {
            t += 0.25
            accumulator.add(vulpix, now: start.addingTimeInterval(t))
        }
        accumulator.add(vulpix, now: start.addingTimeInterval(t + 0.25))
        #expect(accumulator.merged(now: start.addingTimeInterval(t + 0.3)).number == "009/128")
    }
}
