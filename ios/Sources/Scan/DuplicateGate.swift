import Foundation

/// Decides whether the frame shows a new card or the card already logged.
///
/// Automatic mode logs a card the moment it reads. The hard part is not reading
/// it, it is reading it once: he holds one card in the chute for a second or
/// two, and thirty frames a second all say the same thing.
///
/// The gate is fed **every** frame, not only the frames that read a number.
/// That is the whole of the fix for the double log. The old gate ended a card's
/// visit when its number had been absent for a moment, and a number is absent
/// often: the print is three millimetres tall, glare crosses it, the accumulator
/// is emptied the instant a card is logged. The card never left, but the gate
/// believed it had, and logged it again. Now a visit ends when the **card**
/// leaves the frame, which is what `sawCard` reports, and nothing is logged
/// again until the lens sees something different.
///
/// Different means different to look at, or carrying a different number. Two
/// readings of one card disagree about its number often enough — "066/064" one
/// frame and "066/084" the next — that the number alone cannot be the key.
struct DuplicateGate {
    /// How long the frame must hold no card at all before the cards logged
    /// during this visit may be logged again.
    var absence: TimeInterval = 1.5

    /// How near two artwork signatures sit before they are the same card.
    ///
    /// Both sides come off the camera here, a second apart and in one light, so
    /// they sit far nearer each other than a camera frame sits to the catalog's
    /// scanned reference. `CardArtDescriptor.sameCard` is 0.78 and is written
    /// for that harder comparison, with the nearest unrelated card measured at
    /// 0.84 — too little room to spend on camera noise when the cost of a wrong
    /// answer is a card silently missing from the stack. This bar is tighter.
    var sameLook: Float = 0.6

    /// How many logged cards stay blocked. Enough that OCR flickering between
    /// two readings of one card cannot log both, few enough that a genuine run
    /// of cards is never mistaken for a repeat.
    static let memory = 4

    /// A card the gate has logged, and when the lens last saw it.
    private struct Visit {
        var number: String?
        var art: [Int8]?
    }

    /// What one frame says is in front of the lens.
    struct Reading: Equatable {
        var number: String?
        var art: [Int8]?
        /// True when a card-shaped thing was in the frame, whether or not any
        /// word on it could be read.
        var sawCard: Bool = false

        /// Nothing to identify a card by yet.
        var isBlank: Bool { number == nil && art == nil }
    }

    private var visits: [Visit] = []
    private var pending: Reading?
    private var lastCardAt: Date?

    init(absence: TimeInterval = 1.5, sameLook: Float = 0.6) {
        self.absence = absence
        self.sameLook = sameLook
    }

    /// Call once per frame. Returns true when this reading should log a card.
    mutating func shouldAccept(_ reading: Reading, at now: Date = Date()) -> Bool {
        if reading.sawCard || !reading.isBlank {
            lastCardAt = now
        } else if let last = lastCardAt, now.timeIntervalSince(last) > absence {
            // The chute is empty. Whatever was logged is gone, and the same
            // card coming back is a card he is scanning again on purpose.
            visits.removeAll()
            pending = nil
        }

        guard !reading.isBlank else {
            pending = nil
            return false
        }
        // A picture with no number cannot be logged, so it must not use up the
        // card. The reader signs every tenth of a second and reads words every
        // quarter second, so the picture often comes first. It still holds the
        // visit open, above.
        guard reading.number != nil else { return false }
        guard !visits.contains(where: { isSameCard($0, reading) }) else {
            pending = nil
            return false
        }
        // OCR flickers, so one frame is never enough. A reading counts once a
        // second frame agrees with it.
        guard let waiting = pending, isSameCard(Visit(number: waiting.number, art: waiting.art), reading) else {
            pending = reading
            return false
        }
        pending = nil
        visits.append(Visit(number: reading.number, art: reading.art))
        if visits.count > Self.memory { visits.removeFirst(visits.count - Self.memory) }
        return true
    }

    /// Reading a slab: the cert number off its barcode is exact, and a slab has
    /// no artwork the catalog holds.
    mutating func shouldAccept(cert: String, at now: Date = Date()) -> Bool {
        shouldAccept(Reading(number: cert, sawCard: true), at: now)
    }

    /// Record a card as logged without it having passed the gate. The shutter
    /// logs on his say-so, and the gate must not then log it again by itself.
    mutating func note(_ reading: Reading, at now: Date = Date()) {
        guard !reading.isBlank else { return }
        lastCardAt = now
        pending = nil
        visits.append(Visit(number: reading.number, art: reading.art))
        if visits.count > Self.memory { visits.removeFirst(visits.count - Self.memory) }
    }

    /// "Same card again": the next reading of this card counts as new.
    mutating func allowAgain() {
        visits.removeAll()
        pending = nil
    }

    /// The picture decides, and a reading with no picture decides nothing.
    ///
    /// This is the ghost card. Logging a card empties the reading window, and
    /// the window refills unevenly: words are read every quarter second, while
    /// a signature waits for a frame sharp enough to be worth taking. So for a
    /// moment after a card logs, the scanner holds a number and no picture of
    /// the card still sitting in the chute — and a second, worse reading of
    /// that card looks like a different card, because the only thing left to
    /// compare is a number that the second reading got wrong. One Dedenne
    /// logged correctly and was followed by its own attack line, "Dede-Short".
    ///
    /// A reading that brings no picture cannot prove it is a new card, so it is
    /// not allowed to claim it. Whatever is in the frame stays the card already
    /// logged until a picture says otherwise, or until the frame empties.
    private func isSameCard(_ visit: Visit, _ reading: Reading) -> Bool {
        if let a = visit.art {
            guard let b = reading.art else { return true }
            if CardArtDescriptor.distance(a, b) <= sameLook { return true }
        }
        if let number = visit.number, number == reading.number {
            return true
        }
        return false
    }
}
