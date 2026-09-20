import Foundation
import Testing
@testable import BinderBooks

/// Replaces `DuplicateGateTests`. Every case the old gate proved is kept, in
/// its own words, because each one came off a real failure. The cases at the
/// end are new, and they are the ones the old gate could not pass.
@Suite struct CardIdentityGateTests {
    /// A gate plus a clock, so each step reads as "at t, this reading, expect".
    private struct Run {
        var gate = CardIdentityGate(absence: 1.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)

        /// A frame that read a number off a card.
        mutating func see(_ number: String?, at seconds: Double) -> Bool {
            gate.shouldAccept(
                CardIdentityGate.Reading(number: number, sawCard: number != nil),
                at: t0.addingTimeInterval(seconds)
            )
        }

        /// A frame holding a card whose number could not be read.
        mutating func seeCardOnly(at seconds: Double) -> Bool {
            gate.shouldAccept(CardIdentityGate.Reading(sawCard: true), at: t0.addingTimeInterval(seconds))
        }

        /// A frame holding nothing at all.
        mutating func seeNothing(at seconds: Double) -> Bool {
            gate.shouldAccept(CardIdentityGate.Reading(), at: t0.addingTimeInterval(seconds))
        }
    }

    // MARK: - What the old gate already proved

    @Test func acceptsOncePerVisitAfterARepeatedReading() {
        var run = Run()
        let first = run.see(nil, at: 0)
        let second = run.see("114/084", at: 0)
        let third = run.see("114/084", at: 0.1)
        #expect(!first)
        #expect(!second)
        #expect(third)
        // Held still for a while: the ids may churn, the text does not.
        var later = false
        for i in 2...40 { later = later || run.see("114/084", at: Double(i) * 0.1) }
        #expect(!later)
    }

    /// His report: automatic mode logged the same card twice. The number is the
    /// smallest print on a card and it reads intermittently, so a gate that
    /// ended the visit when the *number* went missing ended it while the card
    /// was still in the chute.
    @Test func aCardStillInTheFrameIsNotLoggedAgainWhileItsNumberIsUnreadable() {
        var run = Run()
        _ = run.see("25/172", at: 0)
        let accepted = run.see("25/172", at: 0.1)
        var unreadable = false
        for i in 2...40 { unreadable = unreadable || run.seeCardOnly(at: Double(i) * 0.1) }
        let readAgain = run.see("25/172", at: 4.2)
        let readAgainConfirmed = run.see("25/172", at: 4.3)
        #expect(accepted)
        #expect(!unreadable)
        #expect(!readAgain && !readAgainConfirmed)
    }

    @Test func aNewVisitStartsAfterTheCardWasGone() {
        var run = Run()
        _ = run.see("4/102", at: 0)
        let accepted = run.see("4/102", at: 0.1)
        let gone = run.seeNothing(at: 1.0)
        let stillGone = run.seeNothing(at: 2.0)
        let back = run.see("4/102", at: 2.2)
        let backAgain = run.see("4/102", at: 2.3)
        #expect(accepted)
        #expect(!gone && !stillGone)
        #expect(!back)
        #expect(backAgain)
    }

    @Test func aShortGapDoesNotStartANewVisit() {
        var run = Run()
        _ = run.see("4/102", at: 0)
        let accepted = run.see("4/102", at: 0.1)
        let gap = run.seeNothing(at: 0.5)
        let back = run.see("4/102", at: 0.8)
        let backAgain = run.see("4/102", at: 0.9)
        #expect(accepted)
        #expect(!gap && !back && !backAgain)
    }

    @Test func differentCardsInterleave() {
        var run = Run()
        _ = run.see("1/102", at: 0)
        let one = run.see("1/102", at: 0.1)
        _ = run.see("2/102", at: 0.2)
        let two = run.see("2/102", at: 0.3)
        let oneAgain = run.see("1/102", at: 0.4)
        #expect(one && two && !oneAgain)
    }

    /// The number flickers between two readings of one card. The picture does
    /// not, so the picture is what says they are the same card.
    @Test func oneCardReadTwoWaysIsStillOneCard() {
        var gate = CardIdentityGate(absence: 1.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let art = Fixture.artDescriptor(seed: 0x0DED)
        func see(_ number: String, _ art: [Int8], at seconds: Double) -> Bool {
            gate.shouldAccept(
                CardIdentityGate.Reading(number: number, art: art, sawCard: true),
                at: t0.addingTimeInterval(seconds)
            )
        }
        _ = see("66/064", art, at: 0)
        let accepted = see("66/064", art, at: 0.1)
        _ = see("66/084", art, at: 0.3)
        let misread = see("66/084", art, at: 0.4)
        #expect(accepted)
        #expect(!misread)
    }

    /// His report: the Dedenne logged correctly, and its own attack line
    /// "Dede-Short" logged right behind it. Logging a card empties the reading
    /// window, and words come back before the picture does.
    ///
    /// Two layers hold this, and the test covers both: the early readings fall
    /// inside `ghostWindow`, and the later one is outside it but has to be read
    /// twice the same way before it can log.
    @Test func aSecondReadingWithNoPictureIsNotANewCard() {
        var gate = CardIdentityGate(absence: 1.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let dedenne = Fixture.artDescriptor(seed: 0x0DED)
        func see(_ number: String?, _ art: [Int8]?, at seconds: Double) -> Bool {
            gate.shouldAccept(
                CardIdentityGate.Reading(number: number, art: art, sawCard: true),
                at: t0.addingTimeInterval(seconds)
            )
        }
        _ = see("085/195", dedenne, at: 0)
        let dedenneLogged = see("085/195", dedenne, at: 0.1)
        _ = see("10/60", nil, at: 0.35)
        let ghost = see("10/60", nil, at: 0.6)
        let ghostAgain = see("10/60", nil, at: 0.85)
        #expect(dedenneLogged)
        #expect(!ghost && !ghostAgain)
    }

    /// His report: automatic mode logged nothing on Perfect Order. The picture
    /// often arrives before the number, and a picture-only frame must not use
    /// up the card.
    @Test func aPictureBeforeTheNumberDoesNotUseUpTheCard() {
        var gate = CardIdentityGate(absence: 1.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let tyrunt = Fixture.artDescriptor(seed: 0x7A7A)
        func see(_ number: String?, at seconds: Double) -> Bool {
            gate.shouldAccept(
                CardIdentityGate.Reading(number: number, art: tyrunt, sawCard: true),
                at: t0.addingTimeInterval(seconds)
            )
        }
        let first = see(nil, at: 0)
        let second = see(nil, at: 0.1)
        _ = see("044/088", at: 0.25)
        let logged = see("044/088", at: 0.5)
        #expect(!first && !second)
        #expect(logged)
    }

    /// The next card in the stack looks like nothing the last one looked like,
    /// so it logs, and it logs without the lens ever seeing an empty chute.
    @Test func theNextCardInTheStackLogs() {
        var gate = CardIdentityGate(absence: 1.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let first = Fixture.artDescriptor(seed: 0x1111)
        let second = Fixture.artDescriptor(seed: 0x2222)
        func see(_ number: String, _ art: [Int8], at seconds: Double) -> Bool {
            gate.shouldAccept(
                CardIdentityGate.Reading(number: number, art: art, sawCard: true),
                at: t0.addingTimeInterval(seconds)
            )
        }
        _ = see("1/102", first, at: 0)
        let one = see("1/102", first, at: 0.1)
        _ = see("2/102", second, at: 0.5)
        let two = see("2/102", second, at: 0.6)
        #expect(one && two)
    }

    // MARK: - What the old gate could not pass

    /// **The reported bug.** A rip in a dim room: the frames are too soft to
    /// sign, so no reading carries a picture. The first card logged while a
    /// signature still happened to land. From then on the chute never empties,
    /// so the old gate never cleared its memory, and its rule that an unsigned
    /// reading *is* the signed card it remembers blocked every card after it —
    /// for the rest of the run, with nothing on screen to say so.
    ///
    /// Ten different cards go through. Ten must log.
    @Test func aRunWhereSignaturesStopArrivingKeepsLogging() {
        var gate = CardIdentityGate(absence: 1.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let signed = Fixture.artDescriptor(seed: 0xFEED)

        // The one card the light was good enough for.
        _ = gate.shouldAccept(
            CardIdentityGate.Reading(number: "001/191", art: signed, sawCard: true),
            at: t0
        )
        let firstLogged = gate.shouldAccept(
            CardIdentityGate.Reading(number: "001/191", art: signed, sawCard: true),
            at: t0.addingTimeInterval(0.1)
        )
        #expect(firstLogged)

        // Every card after it reads its number and never gets signed. The card
        // is always in the frame, so the chute never reads as empty.
        var logged = 0
        var clock = 1.0
        for card in 2...11 {
            let number = String(format: "%03d/191", card)
            for _ in 0..<2 {
                if gate.shouldAccept(
                    CardIdentityGate.Reading(number: number, sawCard: true),
                    at: t0.addingTimeInterval(clock)
                ) {
                    logged += 1
                }
                clock += 0.1
            }
            // A moment of the card in frame with nothing readable, as happens
            // between cards, but never an empty chute.
            _ = gate.shouldAccept(CardIdentityGate.Reading(sawCard: true), at: t0.addingTimeInterval(clock))
            clock += 0.2
        }
        #expect(logged == 10)
    }

    /// The same asymmetry at its narrowest: one signed card, then one unsigned
    /// card, with the chute never empty. Inside the ghost window it is the same
    /// card. Outside it, it is the next card and it must log.
    @Test func anUnsignedReadingIsTheGhostOnlyWhileItIsFresh() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let art = Fixture.artDescriptor(seed: 0xBEEF)

        func runLoggingUnsigned(after delay: Double) -> Bool {
            var gate = CardIdentityGate(absence: 1.5)
            _ = gate.shouldAccept(CardIdentityGate.Reading(number: "5/102", art: art, sawCard: true), at: t0)
            _ = gate.shouldAccept(
                CardIdentityGate.Reading(number: "5/102", art: art, sawCard: true),
                at: t0.addingTimeInterval(0.1)
            )
            _ = gate.shouldAccept(
                CardIdentityGate.Reading(number: "6/102", sawCard: true),
                at: t0.addingTimeInterval(delay)
            )
            return gate.shouldAccept(
                CardIdentityGate.Reading(number: "6/102", sawCard: true),
                at: t0.addingTimeInterval(delay + 0.1)
            )
        }

        // A third of a second after the Dedenne logged: its own attack line.
        #expect(!runLoggingUnsigned(after: 0.3))
        // A second after: this is the next card out of the slinger. A slinger
        // feeds about one card a second, so this case has to log, and it is
        // the one a wider window silently swallowed.
        #expect(runLoggingUnsigned(after: 1.0))
    }

    /// A visit stops being remembered even when the chute never empties. The
    /// old gate cleared its memory on `absence` alone, so a card held in view
    /// kept every earlier card blocked indefinitely.
    @Test func aVisitExpiresWithoutTheChuteEverEmptying() {
        var gate = CardIdentityGate(absence: 1.5, visitLifetime: 6)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = gate.shouldAccept(CardIdentityGate.Reading(number: "9/102", sawCard: true), at: t0)
        let logged = gate.shouldAccept(
            CardIdentityGate.Reading(number: "9/102", sawCard: true),
            at: t0.addingTimeInterval(0.1)
        )
        #expect(logged)

        // The card never leaves the frame, and he deliberately scans it again
        // well after the visit should have expired.
        var clock = 0.2
        while clock < 7 {
            _ = gate.shouldAccept(CardIdentityGate.Reading(sawCard: true), at: t0.addingTimeInterval(clock))
            clock += 0.2
        }
        _ = gate.shouldAccept(CardIdentityGate.Reading(number: "9/102", sawCard: true), at: t0.addingTimeInterval(7.2))
        let again = gate.shouldAccept(
            CardIdentityGate.Reading(number: "9/102", sawCard: true),
            at: t0.addingTimeInterval(7.3)
        )
        #expect(again)
    }

    /// Holding one card in the frame is **not** a stall. The visit expires and
    /// the card logs again, which is the gate healing itself rather than
    /// needing to be told about. Pinned because it is what makes the stall
    /// report rare enough to be worth showing.
    @Test func holdingOneCardIsNotAStall() {
        var gate = CardIdentityGate(absence: 1.5, visitLifetime: 6)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var clock = 0.0
        var logged = 0
        while clock < 9 {
            if gate.shouldAccept(
                CardIdentityGate.Reading(number: "3/102", sawCard: true),
                at: t0.addingTimeInterval(clock)
            ) {
                logged += 1
            }
            clock += 0.2
        }
        #expect(logged >= 2)
        #expect(!gate.isStalled(at: t0.addingTimeInterval(9)))
    }

    /// The case that genuinely stalls: a number that reads differently on every
    /// frame, so no two frames ever agree and nothing is ever logged. The gate
    /// is allowed to keep refusing. It is not allowed to refuse in silence,
    /// because a refusing scanner and an empty chute look identical.
    @Test func aNumberThatNeverReadsTwiceTheSameWayReportsAStall() {
        var gate = CardIdentityGate(absence: 1.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var clock = 0.0
        var logged = 0
        var flicker = 0
        while clock < 9 {
            flicker += 1
            // Glare crossing the print: "071/129", "071/l29", "07I/129", …
            let number = "07\(flicker % 3)/129"
            if gate.shouldAccept(
                CardIdentityGate.Reading(number: number, sawCard: true),
                at: t0.addingTimeInterval(clock)
            ) {
                logged += 1
            }
            clock += 0.2
        }
        #expect(logged == 0)
        #expect(gate.isStalled(at: t0.addingTimeInterval(9)))
    }

    /// "Same card again" clears the stall as well as the memory.
    @Test func allowAgainClearsTheStall() {
        var gate = CardIdentityGate(absence: 1.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var clock = 0.0
        var flicker = 0
        while clock < 9 {
            flicker += 1
            _ = gate.shouldAccept(
                CardIdentityGate.Reading(number: "07\(flicker % 3)/129", sawCard: true),
                at: t0.addingTimeInterval(clock)
            )
            clock += 0.2
        }
        #expect(gate.isStalled(at: t0.addingTimeInterval(9)))
        gate.allowAgain()
        #expect(!gate.isStalled(at: t0.addingTimeInterval(9)))
    }
}
