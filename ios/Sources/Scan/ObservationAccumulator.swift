import Foundation

/// Merges what the last second of frames read into one observation.
///
/// A still photo read the card properly but cost a camera rebuild per capture,
/// which is too slow for a stack of 300. The live scanner gives about thirty
/// frames a second instead, and no single frame has to be perfect: the
/// collector number only has to be legible in one of them, and a stray reading
/// of an attack name is outvoted by the frames that read the card name.
///
/// Most common wins, and the most recent breaks a tie. Most common matters more
/// than most recent here: the misread that logged a Mawile V was a set total of
/// 195 on a card printed 196, and it appeared in one frame among many.
struct ObservationAccumulator {
    /// How far back a reading still counts. Long enough to gather frames, short
    /// enough that the previous card is gone before he shoots the next one.
    var window: TimeInterval = 1.2

    private var readings: [(observation: ScanObservation, at: Date)] = []

    /// The card just logged, and when a frame last showed it.
    ///
    /// The card he just logged stays in front of the lens while he swaps it
    /// for the next one, and every frame of it went into the window. The next
    /// card's number then logged a row, but the old card's frames still
    /// outvoted the new one on the name. That is how a Toxel was logged with
    /// Vulpix's name, and why its candidates held six Vulpix and one Toxel.
    /// So a frame of the card just logged no longer enters the window.
    private var logged: ScanObservation?
    private var loggedLastSeen: Date?
    private var loggedAt: Date?

    /// How long with no frame of the logged card before it is forgotten. A
    /// swap takes less than this, and a second copy of the same card can log
    /// once the first has been gone this long.
    var loggedAbsence: TimeInterval = 1.0
    /// The longest the logged card is remembered at all, the same bound the
    /// identity gate puts on a visit. Nothing may block a card for good.
    var loggedLifetime: TimeInterval = CardIdentityGate.Defaults.visitLifetime

    mutating func add(_ observation: ScanObservation, now: Date = Date()) {
        // A frame that only signed the artwork still counts. Text runs on its
        // own slower cadence, so most frames carry a signature and no words,
        // and dropping them would throw away every sharp look at the card.
        guard !observation.isEmpty || observation.artDescriptor != nil else { return }
        forgetLoggedIfGone(now: now)
        if isLoggedCard(observation) {
            loggedLastSeen = now
            return
        }
        readings.append((observation, now))
        prune(now: now)
    }

    mutating func reset() {
        readings.removeAll()
        logged = nil
        loggedLastSeen = nil
        loggedAt = nil
    }

    /// Empty the window after a card is logged, and keep that card out of it.
    mutating func reset(afterLogging card: ScanObservation, now: Date = Date()) {
        readings.removeAll()
        logged = card
        loggedLastSeen = now
        loggedAt = now
    }

    /// Whether this frame shows the card just logged. The number decides when
    /// the frame read one: a different number is a different card. Otherwise
    /// the artwork decides, and the name only when there is nothing else.
    func isLoggedCard(_ observation: ScanObservation) -> Bool {
        guard let logged else { return false }
        if let number = observation.number {
            return number == logged.number
        }
        if let art = observation.artDescriptor, let loggedArt = logged.artDescriptor {
            return CardArtDescriptor.distance(art, loggedArt) <= CardIdentityGate.Defaults.sameLook
        }
        if let name = observation.name {
            return name == logged.name || logged.nameCandidates.contains(name)
        }
        return false
    }

    private mutating func forgetLoggedIfGone(now: Date) {
        guard logged != nil else { return }
        let gone = loggedLastSeen.map { now.timeIntervalSince($0) > loggedAbsence } ?? true
        let expired = loggedAt.map { now.timeIntervalSince($0) > loggedLifetime } ?? true
        if gone || expired {
            logged = nil
            loggedLastSeen = nil
            loggedAt = nil
        }
    }

    /// What the window agrees on. Empty when nothing has been read.
    func merged(now: Date = Date()) -> ScanObservation {
        let live = readings.filter { now.timeIntervalSince($0.at) <= window }
        guard !live.isEmpty else { return ScanObservation() }

        var merged = ScanObservation()
        merged.number = mostAgreed(live.map { ($0.observation.number, $0.at) })
        merged.certNumber = mostAgreed(live.map { ($0.observation.certNumber, $0.at) })
        merged.grader = mostAgreed(live.map { ($0.observation.grader, $0.at) })

        // Every line any frame thought could be the name, the most-seen first.
        // The matcher checks the whole list against the catalog, so a line that
        // only one frame caught still gets its chance.
        var votes: [String: Int] = [:]
        var newest: [String: Date] = [:]
        for reading in live {
            for line in reading.observation.nameCandidates where !line.isEmpty {
                votes[line, default: 0] += 1
                newest[line] = max(newest[line] ?? .distantPast, reading.at)
            }
        }
        merged.nameCandidates = votes
            .sorted { left, right in
                left.value == right.value
                    ? (newest[left.key] ?? .distantPast) > (newest[right.key] ?? .distantPast)
                    : left.value > right.value
            }
            .map(\.key)
            .prefix(FrameInterpreter.nameCandidateLimit)
            .map { $0 }
        merged.name = merged.nameCandidates.first
        // One frame is enough. Japanese script is never a misread of an English
        // card, and glare hides the kana far more often than it invents it.
        merged.sawJapaneseText = live.contains { $0.observation.sawJapaneseText }
        // One frame is enough here too. The card leaves the quadrilateral
        // detector's reach for a frame at a time while he turns it over, and
        // "no card was ever in view" is the only answer worth acting on.
        merged.sawCard = live.contains { $0.observation.sawCard }

        // The sharpest signature in the window, not the most recent and not the
        // most agreed. Signatures are not votes: a blurred frame and a sharp
        // one do not average into a better reading of the artwork, and the
        // sharp one is simply the right answer.
        if let sharpest = live
            .filter({ $0.observation.artDescriptor != nil })
            .max(by: { $0.observation.artSharpness < $1.observation.artSharpness }) {
            merged.artDescriptor = sharpest.observation.artDescriptor
            merged.artSharpness = sharpest.observation.artSharpness
            merged.artIsBestEffort = sharpest.observation.artIsBestEffort
        }

        // Only when every frame that read words read them from the crop. One
        // frame that found a real card is enough to say the words came off a
        // card, and the crop is the weaker claim.
        let read = live.filter { !$0.observation.isEmpty }
        merged.readFromGuideCrop = !read.isEmpty && read.allSatisfy { $0.observation.readFromGuideCrop }
        return merged
    }

    /// The value the most frames read. The most recent of those breaks a tie.
    private func mostAgreed(_ values: [(String?, Date)]) -> String? {
        var counts: [String: Int] = [:]
        var newest: [String: Date] = [:]
        for (value, at) in values {
            guard let value, !value.isEmpty else { continue }
            counts[value, default: 0] += 1
            if let seen = newest[value] { newest[value] = max(seen, at) } else { newest[value] = at }
        }
        return counts
            .sorted { left, right in
                left.value == right.value
                    ? (newest[left.key] ?? .distantPast) > (newest[right.key] ?? .distantPast)
                    : left.value > right.value
            }
            .first?.key
    }

    private mutating func prune(now: Date) {
        readings.removeAll { now.timeIntervalSince($0.at) > window }
    }
}
