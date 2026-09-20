import Foundation
import Testing
@testable import BinderBooks

/// The queue rule, over an injected clock. This is the decision that used to
/// live in four `guard` statements inside the camera controller, where the only
/// way to test it was a card and a lamp.
@Suite struct ScanPipelineTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func card(number: String? = nil, name: String? = nil, art: [Int8]? = nil) -> ScanObservation {
        var observation = ScanObservation(number: number, name: name)
        if let name { observation.nameCandidates = [name] }
        observation.artDescriptor = art
        observation.sawCard = true
        return observation
    }

    /// Feed one observation over and over, and collect what was queued.
    private func run(
        _ observation: ScanObservation,
        seconds: Double,
        step: Double = 0.1,
        pipeline: inout ScanPipeline
    ) -> [ScanObservation] {
        var queued: [ScanObservation] = []
        var clock = 0.0
        while clock < seconds {
            if case .queue(let out) = pipeline.consider(observation, at: t0.addingTimeInterval(clock)) {
                queued.append(out)
            }
            clock += step
        }
        return queued
    }

    // MARK: - The number, which still wins

    @Test func aNumberAgreedAcrossTwoFramesQueuesAtOnce() {
        var pipeline = ScanPipeline()
        let observation = card(number: "114/084", name: "Mega Zeraora ex")
        let first = pipeline.consider(observation, at: t0)
        let second = pipeline.consider(observation, at: t0.addingTimeInterval(0.1))
        #expect(first == .waiting(.reading(.name)))
        #expect(second == .queue(observation))
    }

    /// It must not wait out `patience` when the number is right there.
    @Test func aNumberDoesNotWaitForPatience() {
        var pipeline = ScanPipeline(patience: 1.2)
        let observation = card(number: "25/172", name: "Pikachu")
        _ = pipeline.consider(observation, at: t0)
        let queuedAt = pipeline.consider(observation, at: t0.addingTimeInterval(0.1))
        #expect(queuedAt == .queue(observation))
    }

    // MARK: - The cards the old loop refused forever

    /// **The reported bug.** A card whose collector number never reads — glare
    /// across three millimetres of print, a finger over the corner — was
    /// refused for as long as he held it there, and nothing said why. The name
    /// alone is enough to look a card up, and `CardMatcher` already demands a
    /// strong name match before it assigns anything.
    @Test func aCardWithNoReadableNumberQueuesOnItsName() {
        var pipeline = ScanPipeline(patience: 1.2)
        let observation = card(name: "Sableye")
        let queued = run(observation, seconds: 3, pipeline: &pipeline)
        #expect(queued.count == 1)
        #expect(queued.first?.name == "Sableye")
    }

    /// The Japanese case, and the card read through glare: no number the
    /// catalog shares, a name it files in English, and a picture that is worth
    /// 95% at rank one on its own.
    @Test func aCardWithOnlyAPictureQueuesOnThePicture() {
        var pipeline = ScanPipeline(patience: 1.2)
        var observation = ScanObservation()
        observation.sawCard = true
        observation.artDescriptor = Fixture.artDescriptor(seed: 0xFACE)
        let queued = run(observation, seconds: 3, pipeline: &pipeline)
        #expect(queued.count == 1)
        #expect(queued.first?.artDescriptor == Fixture.artDescriptor(seed: 0xFACE))
    }

    /// Before `patience` is up, the number is still worth waiting for.
    @Test func theNameWaitsForPatienceBeforeItQueues() {
        var pipeline = ScanPipeline(patience: 1.2)
        let observation = card(name: "Snivy")
        let early = run(observation, seconds: 1.0, pipeline: &pipeline)
        #expect(early.isEmpty)
    }

    /// One card in view logs once, however long he holds it there.
    @Test func aCardQueuesOnceNotRepeatedly() {
        var pipeline = ScanPipeline(patience: 1.2)
        let observation = card(name: "Snivy", art: Fixture.artDescriptor(seed: 0x5117))
        let queued = run(observation, seconds: 5, pipeline: &pipeline)
        #expect(queued.count == 1)
    }

    // MARK: - What must still never queue

    @Test func anEmptyFrameNeverQueues() {
        var pipeline = ScanPipeline(patience: 1.2)
        let queued = run(ScanObservation(), seconds: 5, pipeline: &pipeline)
        #expect(queued.isEmpty)
        #expect(pipeline.consider(ScanObservation(), at: t0) == .waiting(.idle))
    }

    /// A card is in the frame and nothing on it can be read. There is nothing
    /// to look up, so nothing is logged — but the screen says so.
    @Test func aCardWithNothingReadableWaitsAndSaysSo() {
        var pipeline = ScanPipeline(patience: 1.2)
        var observation = ScanObservation()
        observation.sawCard = true
        let queued = run(observation, seconds: 5, pipeline: &pipeline)
        #expect(queued.isEmpty)
        #expect(pipeline.consider(observation, at: t0.addingTimeInterval(6)) == .waiting(.reading([.number, .name])))
    }

    /// Detail fills the frame and no card is found in it: he is too close for
    /// the card's edges to fit. He is told to move back — **and** the words the
    /// guide crop did manage to read still log. Telling him and logging nothing
    /// is what the old loop did, and it cost him the card either way.
    @Test func aCardReadTooCloseSaysSoAndStillLogs() {
        var pipeline = ScanPipeline(patience: 1.2)
        var observation = ScanObservation(number: nil, name: "Mega Zeraora ex")
        observation.nameCandidates = ["Mega Zeraora ex"]
        observation.sawCard = false
        observation.readFromGuideCrop = true

        #expect(pipeline.consider(observation, at: t0) == .waiting(.tooClose))
        let queued = run(observation, seconds: 3, pipeline: &pipeline)
        #expect(queued.count == 1)
    }

    @Test func manualModeQueuesNothingOnItsOwn() {
        var pipeline = ScanPipeline(patience: 1.2)
        let observation = card(number: "114/084", name: "Mega Zeraora ex")
        var clock = 0.0
        var queued = 0
        while clock < 5 {
            if case .queue = pipeline.consider(observation, mode: .manual, at: t0.addingTimeInterval(clock)) {
                queued += 1
            }
            clock += 0.1
        }
        #expect(queued == 0)
    }

    /// The shutter logged it, so the loop must not log it again when he
    /// switches back to automatic with the card still in the chute.
    @Test func aCapturedCardDoesNotQueueAgain() {
        var pipeline = ScanPipeline(patience: 1.2)
        let observation = card(number: "4/102", name: "Charizard")
        pipeline.noteCaptured(observation, at: t0)
        let queued = run(observation, seconds: 4, pipeline: &pipeline)
        #expect(queued.isEmpty)
    }

    // MARK: - The two failures the relaxed rules must not bring back

    /// 2026-09-10. A Sableye was held with a finger over `070/196`, so no
    /// number read; the name picker fell through to the attack name `Scratch`;
    /// and the card was logged twice as a Japanese trainer.
    ///
    /// The loop's job here is only to hand the matcher one observation with
    /// the attack line in it. `CardMatcher` is what refuses to assign a card
    /// on a weak name — `nameOnlyAgreement` is 0.75 for exactly this — and
    /// `CardMatcherTests` holds that half. What this pins is the *once*: one
    /// card in the chute produces one row, however badly it reads.
    @Test func theSableyeLogsOnceNotTwice() {
        var pipeline = ScanPipeline(patience: 1.2)
        let misread = card(name: "Scratch")
        let queued = run(misread, seconds: 6, pipeline: &pipeline)
        #expect(queued.count == 1)
    }

    /// 2026-09-14. One Dedenne in the chute produced seven rows, because text
    /// was read off the whole frame: its own attack line, and "Resistance Gym"
    /// off the next card along. The crop fixed the cause; this pins the count.
    ///
    /// The readings here are what that frame produced — the card, then junk
    /// off it and its neighbour — with the card never leaving the frame.
    @Test func theDedenneLogsOnceNotSeven() {
        var pipeline = ScanPipeline(patience: 1.2)
        let dedenne = Fixture.artDescriptor(seed: 0x0DED)
        var queued = 0
        var clock = 0.0

        func feed(_ observation: ScanObservation) {
            if case .queue = pipeline.consider(observation, at: t0.addingTimeInterval(clock)) { queued += 1 }
            clock += 0.1
        }

        // The card reads properly and logs.
        let real = card(number: "085/195", name: "Dedenne", art: dedenne)
        feed(real)
        feed(real)
        // Then the junk, all of it while the same card sits in the chute and
        // the window is refilling, so none of it carries a picture.
        for junk in ["Tail Smack", "Dede-Short", "Resistance Gym", "Energy Search"] {
            for _ in 0..<4 { feed(card(name: junk)) }
        }
        #expect(queued == 1)
    }
}
