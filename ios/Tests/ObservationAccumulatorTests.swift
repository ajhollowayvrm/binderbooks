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
}
