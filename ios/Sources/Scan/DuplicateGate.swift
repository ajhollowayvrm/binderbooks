import Foundation

/// Decides whether a number reading is a new card or the same card still in
/// front of the camera.
///
/// VisionKit's item ids churn while tracking flickers, so "the item left the
/// frame" fires many times for one card held still. The gate keys on the
/// number text instead. A number is accepted once per visit, a visit ends when
/// the number has been absent for `absence`, and a reading must repeat before
/// it counts, because OCR flickers.
struct DuplicateGate {
    var absence: TimeInterval = 1.5

    private var lastSeen: [String: Date] = [:]
    private var acceptedThisVisit: Set<String> = []
    private var pending: String?

    init(absence: TimeInterval = 1.5) {
        self.absence = absence
    }

    /// Call once per frame with the number found in it, or nil.
    /// Returns true when the reading should log a card.
    mutating func shouldAccept(_ number: String?, at now: Date = Date()) -> Bool {
        // Expire visits whose number has been gone long enough.
        for (value, seen) in lastSeen where now.timeIntervalSince(seen) > absence {
            lastSeen[value] = nil
            acceptedThisVisit.remove(value)
        }
        guard let number else {
            pending = nil
            return false
        }
        lastSeen[number] = now
        if acceptedThisVisit.contains(number) {
            return false
        }
        if pending == number {
            acceptedThisVisit.insert(number)
            pending = nil
            return true
        }
        pending = number
        return false
    }

    /// "Same card again": the next reading of this number counts as new.
    mutating func allowAgain(_ number: String) {
        acceptedThisVisit.remove(number)
    }
}
