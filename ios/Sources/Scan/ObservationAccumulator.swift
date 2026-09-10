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

    mutating func add(_ observation: ScanObservation, now: Date = Date()) {
        guard !observation.isEmpty else { return }
        readings.append((observation, now))
        prune(now: now)
    }

    mutating func reset() {
        readings.removeAll()
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
