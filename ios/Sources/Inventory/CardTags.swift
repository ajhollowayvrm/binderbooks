import Foundation
import SwiftData

/// The comparison and display rules for a tag. A tag is text he typed, so the
/// app must not rewrite his punctuation. `NameCleaner` is the wrong tool here:
/// it exists to match a card name against the catalog, and it would merge
/// "PSA-queue" into "PSA queue" and turn "binder #3" into "binder 3".
enum TagKey {
    /// The comparison form. Case and accents fold. Inner spaces collapse.
    static func of(_ label: String) -> String {
        display(label).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// The stored form. Trimmed, inner spaces collapsed, case as he typed it.
    static func display(_ label: String) -> String {
        label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func isValid(_ label: String) -> Bool { !display(label).isEmpty }
}

/// One label in use, with how many cards carry it.
struct TagUse: Identifiable, Equatable, Sendable {
    var label: String
    var count: Int

    var id: String { TagKey.of(label) }
}

/// The labels the old status picker used. Tags replaced `CardStatus`, so the
/// later sale and grading flows write these instead of a status field.
enum ReservedTag {
    static let sold = "sold"
    static let listed = "listed"
    /// The old status label, and the fallback for a grader the app does not
    /// know. A send to PSA or CGC writes the grader's own label instead.
    static let atGrader = "at grader"
    static let atPSA = "at PSA"
    static let atCGC = "at CGC"
    static let graded = "graded"
    static let lost = "lost"

    static let all = [sold, listed, atGrader, atPSA, atCGC, graded, lost]

    /// The label a card wears while it is out at that grader.
    static func atGrader(_ grader: String) -> String {
        switch grader.lowercased().trimmingCharacters(in: .whitespaces) {
        case "psa": return atPSA
        case "cgc": return atCGC
        default: return atGrader
        }
    }

    /// Every label that means "out at a grader". A return clears them all.
    static let allAtGrader = [atGrader, atPSA, atCGC]

    /// The label for a stored `CardStatus` raw value. `owned` needs no label,
    /// because an owned card is the default.
    static func forStatus(_ raw: String) -> String? {
        switch CardStatus(rawValue: raw) {
        case .sold: return sold
        case .listed: return listed
        case .atGrader: return atGrader
        case .gradedReturned: return graded
        case .lost: return lost
        case .owned, nil: return nil
        }
    }
}

/// Reads over the labels on a set of cards. Derived, never stored, so a
/// deleted card drops out of the suggestions at once.
enum CardTagIndex {
    /// Labels in use, most used first, then alphabetical by key. The display
    /// form is the one the first card carries.
    static func uses(in cards: [OwnedCard]) -> [TagUse] {
        var counts: [String: Int] = [:]
        var labels: [String: String] = [:]
        for card in cards {
            for tag in card.tags {
                let key = TagKey.of(tag)
                guard !key.isEmpty else { continue }
                counts[key, default: 0] += 1
                if labels[key] == nil { labels[key] = TagKey.display(tag) }
            }
        }
        return counts
            .map { TagUse(label: labels[$0.key] ?? $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
    }

    /// True when any label contains the query. "binder" finds "binder 3", and
    /// "sale" finds "for sale".
    static func matches(tags: [String], query: String) -> Bool {
        let key = TagKey.of(query)
        guard !key.isEmpty else { return false }
        return tags.contains { TagKey.of($0).contains(key) }
    }

    static func has(_ label: String, on card: OwnedCard) -> Bool {
        let key = TagKey.of(label)
        return card.tags.contains { TagKey.of($0) == key }
    }
}

/// Every write to a card's labels. `InventoryModel` stays read-only and holds
/// no `ModelContext`, so the mutators live here, in the shape of the
/// `ScanSessionModel` bulk mutators.
@MainActor
struct CardTagEditor {
    let context: ModelContext

    /// Merges. It must never assign the array, or a bulk apply would drop the
    /// labels a card already carries.
    func add(_ label: String, to cards: [OwnedCard]) {
        let display = TagKey.display(label)
        guard TagKey.isValid(display) else { return }
        for card in cards where !CardTagIndex.has(display, on: card) {
            card.tags.append(display)
            normalise(card)
        }
        save()
    }

    func remove(_ label: String, from cards: [OwnedCard]) {
        let key = TagKey.of(label)
        guard !key.isEmpty else { return }
        for card in cards {
            card.tags.removeAll { TagKey.of($0) == key }
        }
        save()
    }

    func toggle(_ label: String, on cards: [OwnedCard]) {
        if cards.allSatisfy({ CardTagIndex.has(label, on: $0) }) {
            remove(label, from: cards)
        } else {
            add(label, to: cards)
        }
    }

    func setTags(_ labels: [String], on card: OwnedCard) {
        card.tags = labels.map(TagKey.display).filter(TagKey.isValid)
        normalise(card)
        save()
    }

    /// Rewrites one label across every card he owns.
    func rename(_ old: String, to new: String, in cards: [OwnedCard]) {
        let oldKey = TagKey.of(old)
        let display = TagKey.display(new)
        guard !oldKey.isEmpty, TagKey.isValid(display) else { return }
        for card in cards where card.tags.contains(where: { TagKey.of($0) == oldKey }) {
            card.tags.removeAll { TagKey.of($0) == oldKey }
            if !CardTagIndex.has(display, on: card) { card.tags.append(display) }
            normalise(card)
        }
        save()
    }

    /// Dedupes by key and sorts by key, so two stores that hold the same
    /// labels export the same bytes.
    private func normalise(_ card: OwnedCard) {
        var seen: Set<String> = []
        var kept: [String] = []
        for tag in card.tags {
            let key = TagKey.of(tag)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            kept.append(TagKey.display(tag))
        }
        card.tags = kept.sorted { TagKey.of($0) < TagKey.of($1) }
    }

    private func save() {
        try? context.save()
    }
}

/// Copies each card's old status into a reserved label, once. The status
/// picker is gone, so this is the only way the stored value reaches him.
///
/// `OwnedCard.statusRaw` stays in the store and in the export file on purpose.
/// A field cannot be read after SwiftData drops it, and his existing backups
/// still carry it. A later release removes the field, once every install has
/// run this.
enum StatusTagBackfill {
    static let key = "statusTagsBackfilled.v1"

    @MainActor
    static func run(_ context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: key) else { return }
        let cards = (try? context.fetch(FetchDescriptor<OwnedCard>())) ?? []
        let editor = CardTagEditor(context: context)
        for card in cards {
            guard let label = ReservedTag.forStatus(card.statusRaw) else { continue }
            editor.add(label, to: [card])
        }
        defaults.set(true, forKey: key)
    }
}
