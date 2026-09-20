import Foundation

/// Decides, once per frame, whether to log a card and what to say if not.
///
/// This used to be four `guard` statements inside the camera controller, and
/// the middle one was the reported bug:
///
/// ```swift
/// guard accepted, merged.number != nil, !merged.isEmpty else { return }
/// ```
///
/// A card whose collector number never read — glare across three millimetres of
/// print, a finger over the corner, a Japanese card at an angle — was refused
/// forever, silently, however well the scanner could see it. The picture that
/// identifies a card at 95% on its own was taken, compared against nothing, and
/// thrown away. So was the name.
///
/// Two things are different here. A card is logged on **any** of the three keys
/// rather than the number alone, and every refusal carries a reason the screen
/// can show. It is a plain struct over an injected clock, so each rule is a
/// unit test rather than something only a card and a lamp can reproduce.
struct ScanPipeline {
    /// How long a card may sit in view before it is logged on whatever is
    /// there — its name, its picture, or both.
    ///
    /// The number is still the best key and still worth waiting for, because
    /// it is the only signal that says *which printing*. This is how long the
    /// wait lasts before a worse answer beats no answer. Long enough that a
    /// number about to read still wins, short enough that he does not notice
    /// having waited.
    var patience: TimeInterval = 1.2

    var gate = CardIdentityGate()

    enum Outcome: Equatable {
        case queue(ScanObservation)
        case waiting(ScanState)
    }

    /// What the window has been saying, and since when.
    ///
    /// Patience is measured against **one identity holding still**, not against
    /// a card being present. Those are different questions, and the difference
    /// is the Dedenne: a card sat in the chute for two seconds while the words
    /// coming off it changed four times, and "a card has been here 1.2 seconds"
    /// was true of every one of those readings. A real card with an unreadable
    /// number holds its name steady; junk does not hold anything steady.
    private var lastKey: String?
    private var keySince: Date?

    init(patience: TimeInterval = 1.2, gate: CardIdentityGate = CardIdentityGate()) {
        self.patience = patience
        self.gate = gate
    }

    /// Call once per frame, with what the last second of frames agreed on.
    mutating func consider(
        _ merged: ScanObservation,
        mode: ScanMode = .automatic,
        at now: Date = Date()
    ) -> Outcome {
        let hasCard = merged.sawCard || !merged.isEmpty || merged.artDescriptor != nil
        track(key: Self.stabilityKey(merged), at: now)

        // The gate decides the number path, and it is fed **only** the number.
        // Handing it the name as a stand-in looked tidy and broke the whole
        // rule below: the gate accepted on the name, recorded the card as
        // logged, and the number branch then skipped it — so a card with no
        // readable number was consumed without ever being queued, which is the
        // bug this type exists to fix.
        let numberReading = CardIdentityGate.Reading(
            number: merged.number,
            art: merged.artDescriptor,
            sawCard: occupied(merged)
        )
        let accepted = gate.shouldAccept(numberReading, at: now)

        guard mode == .automatic else { return .waiting(.manual) }

        // The number agrees across two frames. The strongest answer there is,
        // and it does not wait for anything.
        if accepted, merged.number != nil, !merged.isEmpty {
            reset()
            return .queue(merged)
        }

        guard hasCard else { return .waiting(.idle) }

        // Identity for everything that is not the number path. The key is the
        // name when there is no number, because that is what tells two cards
        // apart when the number cannot be read.
        let identity = CardIdentityGate.Reading(
            number: merged.number ?? merged.name,
            art: merged.artDescriptor,
            sawCard: occupied(merged)
        )

        // Detail where a card should be and no card found: he is too close for
        // its edges to fit. Said first, because it is the one fault he can
        // correct by moving his hand.
        let tooClose = !merged.sawCard && merged.readFromGuideCrop

        // Nothing to look a card up by yet. Say which half is missing rather
        // than showing an unchanging screen.
        guard merged.number != nil || merged.name != nil || merged.artDescriptor != nil else {
            return .waiting(tooClose ? .tooClose : .reading([.number, .name]))
        }

        // The number never came. Once one identity has held still for
        // `patience`, whatever is there is the answer: the name the catalog
        // can confirm, the picture that ranks 95% at rank one, or both.
        // `CardMatcher` already takes all three and already returns
        // `.uncertain` with its candidates when they do not settle it, which
        // is exactly a row he can correct in the queue.
        if merged.number == nil, heldStill(at: now), !gate.isRepeat(identity, at: now) {
            gate.note(identity, at: now)
            reset()
            return .queue(merged)
        }

        if tooClose { return .waiting(.tooClose) }
        if gate.isStalled(at: now) { return .waiting(.stalled) }
        if gate.isRepeat(identity, at: now) { return .waiting(.alreadyLogged) }
        return .waiting(.reading(merged.number == nil ? .number : .name))
    }

    /// Whether something he is scanning is in front of the lens.
    ///
    /// Not the same question as `sawCard`, which means "a card-shaped
    /// quadrilateral was found". A card held too close has no quadrilateral and
    /// is very much still in the chute. Passing `sawCard` here let the gate
    /// conclude the chute had emptied while he was holding a card against the
    /// lens, so it forgot what it had logged and logged the card again.
    private func occupied(_ merged: ScanObservation) -> Bool {
        merged.sawCard || merged.readFromGuideCrop
    }

    /// What this reading claims to be, for the purpose of "has it stopped
    /// changing". A picture with no words is still one thing held steady.
    private static func stabilityKey(_ merged: ScanObservation) -> String? {
        if let number = merged.number { return "#\(number)" }
        if let name = merged.name { return "n\(name)" }
        return merged.artDescriptor == nil ? nil : "art"
    }

    private mutating func track(key: String?, at now: Date) {
        guard key == lastKey else {
            lastKey = key
            keySince = key == nil ? nil : now
            return
        }
        if key != nil, keySince == nil { keySince = now }
    }

    /// The shutter logged a card on his say-so. The gate must not then log it
    /// again by itself.
    mutating func noteCaptured(_ merged: ScanObservation, at now: Date = Date()) {
        gate.note(
            CardIdentityGate.Reading(
                number: merged.number ?? merged.name,
                art: merged.artDescriptor,
                sawCard: merged.sawCard
            ),
            at: now
        )
        reset()
    }

    /// "Same card again": the next reading of this card counts as new.
    mutating func allowAgain() {
        gate.allowAgain()
        reset()
    }

    private mutating func reset() {
        lastKey = nil
        keySince = nil
    }

    /// Whether one identity has been saying the same thing for long enough to
    /// act on without a number.
    private func heldStill(at now: Date) -> Bool {
        guard let since = keySince else { return false }
        return now.timeIntervalSince(since) >= patience
    }
}
