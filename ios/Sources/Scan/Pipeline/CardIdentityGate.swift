import Foundation

/// Decides whether the frame shows a new card or the card already logged.
///
/// Automatic mode logs a card the moment it reads. The hard part is not reading
/// it, it is reading it once: he holds one card in the chute for a second or
/// two, and thirty frames a second all say the same thing.
///
/// The gate is fed **every** frame, not only the frames that read a number.
/// That is how it knows the card is still there: a number is unreadable far
/// more often than a card is absent, and a gate that counted an unreadable
/// number as "the card left" logged the card twice. A visit ends when the
/// **card** leaves the frame, which is what `sawCard` reports.
///
/// ## Why this replaced `DuplicateGate`
///
/// The old gate held one rule that could not be bounded: a reading carrying no
/// artwork signature was declared the same card as any remembered visit that
/// had one. It was written for a real failure (see `ghostWindow`), and it was
/// true often enough to look right. But it was an *unconditional* claim, and
/// the remembered visits only cleared after the frame held no card at all for
/// `absence`. Feed it a continuous chute where signatures have stopped arriving
/// — a dim room, a run of soft frames — and it blocks every card from then on,
/// for the rest of the run, with no way back and nothing on screen to say so.
///
/// Three changes, and the shape of each matters more than its constant:
///
/// 1. **The artwork rule is bounded by time**, not left open (`ghostWindow`).
/// 2. **It applies only where the asymmetry is real** — a signed visit against
///    an unsigned reading. When nothing is signed, artwork is not a signal at
///    all and the number decides, which is what it did before artwork existed.
/// 3. **Visits expire** (`visitLifetime`), whatever else happens. No single
///    stuck visit can outlive the card it came from.
///
/// Together those mean the gate cannot enter a state it never leaves. That is
/// the property being defended here, not any one threshold.
struct CardIdentityGate {
    /// The one place each threshold is written down. The properties and the
    /// initializer both read from here, so they cannot drift apart.
    enum Defaults {
        static let absence: TimeInterval = 1.5
        static let sameLook: Float = 0.6
        static let ghostWindow: TimeInterval = 0.6
        static let visitLifetime: TimeInterval = 6
        static let stallWarning: TimeInterval = 8
    }

    /// How long the frame must hold no card at all before the cards logged
    /// during this visit may be logged again.
    var absence: TimeInterval = Defaults.absence

    /// How near two artwork signatures sit before they are the same card.
    ///
    /// Both sides come off the camera here, a second apart and in one light, so
    /// they sit far nearer each other than a camera frame sits to the catalog's
    /// scanned reference. `CardArtDescriptor.sameCard` is 0.78 and is written
    /// for that harder comparison, with the nearest unrelated card measured at
    /// 0.84 — too little room to spend on camera noise when the cost of a wrong
    /// answer is a card silently missing from the stack. This bar is tighter.
    var sameLook: Float = Defaults.sameLook

    /// How long after a signed card was logged an *unsigned* reading is still
    /// assumed to be that same card.
    ///
    /// This is the ghost card, and it is a real failure. Logging a card empties
    /// the reading window, and the window refills unevenly: words are read
    /// every quarter second, while a signature waits for a frame sharp enough
    /// to be worth taking. So for a moment after a card logs, the scanner holds
    /// a number and no picture of the card still sitting in the chute — and a
    /// second, worse reading of that card looks like a different card, because
    /// the only thing left to compare is a number that the second reading got
    /// wrong. One Dedenne logged correctly and was followed by its own attack
    /// line, "Dede-Short".
    ///
    /// Long enough to cover the refill, short enough that the next card out of
    /// a slinger is not caught by it. A second was too long: a slinger feeds a
    /// card about every second, and at 1.0 the next card was read as the last
    /// card's ghost and silently dropped — the very failure this rebuild is
    /// for. The two-frame agreement below is the second layer here, and it is
    /// the one that does the real work: a ghost that escapes this window still
    /// has to be read twice the same way before it logs.
    ///
    /// The costs are not symmetric. A ghost that gets through is a wrong row in
    /// the queue, which he sees and deletes. A real card caught by this window
    /// is a card that is simply missing, and nothing on screen ever said so.
    /// When in doubt, let it through.
    var ghostWindow: TimeInterval = Defaults.ghostWindow

    /// How long a logged card stays remembered, whatever the frame holds.
    ///
    /// `absence` clears the memory when the chute empties. This clears it when
    /// the chute never empties, which is exactly the run the old gate died on.
    /// Longer than any card spends in the frame, shorter than a run of cards.
    var visitLifetime: TimeInterval = Defaults.visitLifetime

    /// How long the gate may refuse a readable card before it says so.
    ///
    /// Not a decision — the gate keeps refusing. It is the admission that it is
    /// refusing, so the screen can stop looking like an empty chute.
    var stallWarning: TimeInterval = Defaults.stallWarning

    /// How many logged cards stay blocked. Enough that OCR flickering between
    /// two readings of one card cannot log both, few enough that a genuine run
    /// of cards is never mistaken for a repeat.
    static let memory = 4

    /// A card the gate has logged, and when it logged it.
    private struct Visit {
        var number: String?
        var art: [Int8]?
        var loggedAt: Date
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
    /// When the gate started refusing a card it could read. Nil while it is not
    /// refusing anything.
    private var refusingSince: Date?

    /// Spelled out because the private state below makes the memberwise
    /// initializer private. Each default reads from the property above it
    /// rather than repeating the number: they were written twice once, the two
    /// copies disagreed, and every caller silently got the initializer's.
    init(
        absence: TimeInterval = Defaults.absence,
        sameLook: Float = Defaults.sameLook,
        ghostWindow: TimeInterval = Defaults.ghostWindow,
        visitLifetime: TimeInterval = Defaults.visitLifetime
    ) {
        self.absence = absence
        self.sameLook = sameLook
        self.ghostWindow = ghostWindow
        self.visitLifetime = visitLifetime
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
            refusingSince = nil
        }

        // A card that has been out of the frame longer than it could plausibly
        // still be in it stops being remembered, whether or not the chute ever
        // emptied. This is the rule that makes a permanent block impossible.
        visits.removeAll { now.timeIntervalSince($0.loggedAt) > visitLifetime }

        guard !reading.isBlank else {
            pending = nil
            return false
        }
        // A picture with no number cannot be logged, so it must not use up the
        // card. The reader signs every tenth of a second and reads words every
        // quarter second, so the picture often comes first. It still holds the
        // visit open, above.
        guard reading.number != nil else { return false }

        guard !visits.contains(where: { isSameCard($0, reading, at: now) }) else {
            pending = nil
            if refusingSince == nil { refusingSince = now }
            return false
        }
        // OCR flickers, so one frame is never enough. A reading counts once a
        // second frame agrees with it.
        guard let waiting = pending,
              isSameCard(Visit(number: waiting.number, art: waiting.art, loggedAt: now), reading, at: now) else {
            pending = reading
            if refusingSince == nil { refusingSince = now }
            return false
        }
        pending = nil
        refusingSince = nil
        remember(Visit(number: reading.number, art: reading.art, loggedAt: now))
        return true
    }

    /// Whether this reading is a card already logged, asked without the
    /// two-frame agreement `shouldAccept` insists on.
    ///
    /// For the patience path: a card that has sat in view for a while with no
    /// readable number is logged on its name or its picture alone, and that
    /// decision is made on elapsed time rather than on frames agreeing. It
    /// still must not log a card twice, so it asks this and then calls `note`.
    func isRepeat(_ reading: Reading, at now: Date = Date()) -> Bool {
        visits.contains { visit in
            now.timeIntervalSince(visit.loggedAt) <= visitLifetime && isSameCard(visit, reading, at: now)
        }
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
        refusingSince = nil
        remember(Visit(number: reading.number, art: reading.art, loggedAt: now))
    }

    /// "Same card again": the next reading of this card counts as new.
    mutating func allowAgain() {
        visits.removeAll()
        pending = nil
        refusingSince = nil
    }

    /// The gate has been refusing a card it can read for longer than it should
    /// take. Whatever the cause, he needs to know it is refusing rather than
    /// seeing nothing.
    func isStalled(at now: Date = Date()) -> Bool {
        guard let since = refusingSince else { return false }
        return now.timeIntervalSince(since) >= stallWarning
    }

    private mutating func remember(_ visit: Visit) {
        visits.append(visit)
        if visits.count > Self.memory { visits.removeFirst(visits.count - Self.memory) }
    }

    /// Whether this reading is the card that visit already logged.
    ///
    /// Read the three branches in order; each answers a different question, and
    /// the middle one is the whole reason this type exists.
    private func isSameCard(_ visit: Visit, _ reading: Reading, at now: Date) -> Bool {
        // Both were photographed. The picture is the best evidence there is,
        // and it is the only thing that separates two cards sharing a number.
        if let a = visit.art, let b = reading.art {
            return CardArtDescriptor.distance(a, b) <= sameLook
        }

        // The card was photographed and this reading was not. That is the ghost
        // (see `ghostWindow`): a worse second look at the card still in the
        // chute, arriving before the next signature does. It is the same card
        // while it is fresh — and only while it is fresh, because the same
        // shape describes the next card out of the slinger once enough time has
        // passed, and treating *that* as a repeat is how a run goes silent.
        if visit.art != nil, reading.art == nil {
            return now.timeIntervalSince(visit.loggedAt) <= ghostWindow
        }

        // Neither carries a picture, or only the new reading does. Artwork is
        // not a signal here, so the number is the whole answer — which is what
        // it was before the scanner could see a card at all.
        return visit.number != nil && visit.number == reading.number
    }
}
