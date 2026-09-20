import Foundation
import GRDB

/// What the matcher decided for one observation.
struct MatchResult: Equatable, Sendable {
    var productId: Int?
    var confidence: MatchConfidence
    /// Everything considered, best first. Feeds the disambiguation chip.
    var candidates: [SearchHit]
    var printing: String
    /// True when a rarity rule chose the printing among several.
    var printingGuessed: Bool

    var hit: SearchHit? { candidates.first { $0.productId == productId } }
}

/// Resolves an observation to a catalog product. Follows docs/03:
///
/// 1. Parse the number. The denominator carries the set.
/// 2. Candidates by (setCode, numberNum) or (setTotal, numberNum).
/// 3. Add name candidates when the number gave nothing, or when several cards
///    share the total and none of them is the name he read.
/// 4. Add the cards whose artwork looks like the card in the frame, taken
///    from `ArtIndex` over the whole catalog. The picture is the one signal
///    that does not depend on reading anything, so it is the one signal a
///    misread cannot spoil.
/// 5. Score by name agreement, the session bias, an exact number string, and a
///    bonus where the number and the name agree. A card only the picture found
///    cannot win on score; it wins, where it wins, on the artwork test.
/// 6. One candidate: certain. One clear winner: likely. Several: uncertain.
///    Nothing that agrees with the name: no product at all.
///
/// The order of authority: the number and the name agreeing beats everything.
/// Failing that, artwork that stands clear of every other card decides.
/// Failing that, nothing is assigned and the chip asks.
struct CardMatcher: Sendable {
    let database: CatalogDatabase
    /// Every signed card in the catalog, searchable by artwork.
    ///
    /// Optional because a catalog can carry no signatures and because the
    /// index takes a moment to build when the scanner opens. Without it the
    /// matcher works the way it always did, on words alone.
    var art: ArtIndex?

    static let nameAgreement = 0.5
    /// The bar a name must clear when it is the **only** signal.
    ///
    /// With no number, a loose name match is the whole decision, and a loose
    /// match is how an attack name became a card. "Scratch" against
    /// "Scramble Switch" scores 0.53 and cleared `nameAgreement`, so a Sableye
    /// was logged twice as a Japanese trainer. Below this bar the matcher
    /// assigns nothing and the chip asks. docs/03: a wrong card that looks
    /// confident is worse than a card marked unknown.
    static let nameOnlyAgreement = 0.75
    static let clearWinnerGap = 0.25
    static let recentBias = 0.3
    /// Added when the number and the name pick the same card.
    static let agreementBonus = 0.2
    static let olderBias = 0.15
    /// What the rip's declared set is worth.
    ///
    /// A preference, never a filter: nothing is removed from the candidates,
    /// so a card filed in another set — a Stellar Crown stamped print, a promo
    /// — still wins on the strength of its own number and name.
    static let preferredSetBias = 0.3
    /// The ceiling on the two set biases **together**.
    ///
    /// The learned bias and the declared scope both say "this set", and they
    /// agree most of the time, so they stack. At 0.3 each that is 0.6, which
    /// clears `nameAgreement` at 0.5 — a card in the expected set would beat a
    /// card whose name the catalog actually confirms, purely for being in the
    /// right box. Capping the pair at what one of them is worth keeps the set
    /// a tie-break, which is all it should ever be.
    static let setBiasCap = 0.3
    static let candidateCap = 12
    /// What artwork agreement is worth against a name. Roughly the same, by
    /// design: neither signal is allowed to overrule the other on its own.
    static let artWeight = 1.2
    /// How much nearer one pattern printing must be than its sibling before the
    /// scanner picks for him instead of asking. The printings sit about 0.5
    /// apart at the reference, so a real capture clears this comfortably or the
    /// light was too poor to judge.
    static let artFamilyGap: Float = 0.15
    /// The bar for asserting *which printing*, as against which card. Tighter
    /// than `sameCard` on purpose: the printings of one card sit about 0.5
    /// apart, so a distance that comfortably says "this is a Snivy" says
    /// nothing at all about which of the three Snivys it is.
    static let artSamePrinting: Float = 0.40
    /// How much nearer the winning picture must be than the nearest picture of
    /// a **different** card before artwork is allowed to overrule the words.
    ///
    /// Reprints are not different cards. Solosis printed in three sets is one
    /// picture, and the three sit within a hundredth of each other; asking the
    /// picture which of the three it is would fail every time and mean nothing.
    /// Which row of the three is the collector number's question.
    static let artDecisiveLead: Float = 0.08
    /// What a candidate earns for being on the artwork shortlist at all.
    ///
    /// Small. The shortlist is thirty cards long and only one of them is the
    /// card, so membership is weak evidence; the distance term above it is
    /// where the real signal is. This only has to lift a card the words never
    /// found above one the words found badly.
    static let artShortlistBonus = 0.15

    func match(
        _ observation: ScanObservation,
        session bias: [Int],
        defaultPrinting: String?,
        language: ScanLanguage? = nil,
        preferred: [Int] = []
    ) async throws -> MatchResult {
        try await database.asyncRead { db in
            try Self.match(
                db, observation: observation, bias: bias, defaultPrinting: defaultPrinting,
                art: art, language: language, preferred: preferred
            )
        }
    }

    static func match(
        _ db: Database,
        observation: ScanObservation,
        bias: [Int],
        defaultPrinting: String?,
        art: ArtIndex? = nil,
        /// What he set on the session. Nil where no one has said, and then the
        /// script on the card is the only evidence there is.
        language: ScanLanguage? = nil,
        /// The sets this rip is expected to be in. Widens the search and
        /// breaks ties. Never narrows it — see `preferredSetBias`.
        preferred: [Int] = []
    ) throws -> MatchResult {
        let parsed = CollectorNumber.parse(observation.number)
        var numberHits = try numberCandidates(db, parsed: parsed)

        // The same number, looked for inside the sets he is ripping.
        //
        // This is the half of the scope that finds cards rather than ranking
        // them. The ordinary lookup keys on the printed set total, so a card
        // whose denominator misread — or which has none, like a promo — is not
        // in the candidate list at all, and no amount of ranking can rescue a
        // card that was never a candidate. Merged, never substituted: the
        // ordinary hits keep their place.
        if !preferred.isEmpty, let numberNum = parsed.numberNum {
            let known = Set(numberHits.map(\.productId))
            let inSet = try product(db, inGroups: preferred, numberNum: numberNum)
            numberHits.append(contentsOf: inSet.filter { !known.contains($0.productId) })
        }

        // Which line on the card is its name? The frame cannot tell, so every
        // plausible line is tried and the catalog decides: an attack name is
        // not a card name, and the catalog holds every card name there is.
        let (chosenName, nameHits) = try readName(db, observation: observation, numberHits: numberHits)
        let cleanedName = chosenName.map(NameCleaner.clean).flatMap { $0.isEmpty ? nil : $0 }

        let numberIds = Set(numberHits.map(\.productId))
        let nameIds = Set(nameHits.map(\.productId))
        var merged: [SearchHit] = numberHits
        for hit in nameHits where !numberIds.contains(hit.productId) {
            merged.append(hit)
        }

        // The cards that look like the card in the frame.
        //
        // This is the step the scanner did not have. Artwork used to arrive
        // late, as a tie-break among candidates the words had already found,
        // so a frame whose words were junk had nothing to tie-break: the words
        // found an attack name, and artwork was never asked. Now the picture
        // proposes too, against every signed card in the catalog, and a card
        // the words missed entirely can still reach the shortlist.
        let neighbours = observation.artDescriptor.flatMap { descriptor in
            art.map { $0.nearest(to: descriptor) }
        } ?? []
        let artIds = Set(neighbours.map(\.productId))
        if !artIds.isEmpty {
            let known = Set(merged.map(\.productId))
            let fresh = neighbours.map(\.productId).filter { !known.contains($0) }
            if !fresh.isEmpty {
                let rows = try CatalogSearch.fetchHits(db, ids: fresh, filter: SearchFilter())
                let byId = Dictionary(rows.map { ($0.productId, $0) }, uniquingKeysWith: { a, _ in a })
                // In the index's own order, nearest first, so the chip reads
                // the way the camera ranked them when nothing else decides.
                for id in fresh {
                    if let row = byId[id] { merged.append(row) }
                }
            }
        }

        // Which catalogue the card is in. 034/190 is a Feebas in the Japanese
        // catalogue and a different card in the English one, so this decides
        // the answer whenever both hold the number.
        //
        // What he set on the session settles it, both ways. He knows which pile
        // he is scanning, and the guess that stood in for him was bad in the
        // one direction that mattered: Vision reads kana out of the foil of an
        // English card, and a single invented kana sent an English Dedenne into
        // the Japanese catalogue, where it does not exist.
        //
        // With nothing set, the old rule stands, and it runs one way only:
        // Japanese script proves a Japanese card, while no Japanese script
        // proves nothing, because glare hides every kana on a card often
        // enough and then the number is all that is left.
        switch language {
        case .japanese:
            let japanese = merged.filter { $0.categoryId == TCGCategory.pokemonJapan }
            if !japanese.isEmpty { merged = japanese }
        case .english:
            let english = merged.filter { $0.categoryId != TCGCategory.pokemonJapan }
            if !english.isEmpty { merged = english }
        case nil:
            if observation.sawJapaneseText {
                let japanese = merged.filter { $0.categoryId == TCGCategory.pokemonJapan }
                if !japanese.isEmpty { merged = japanese }
            }
        }

        guard !merged.isEmpty else {
            return MatchResult(productId: nil, confidence: .uncertain, candidates: [], printing: defaultPrinting ?? "", printingGuessed: false)
        }

        // What the card in the frame looks like, against what each candidate is
        // supposed to look like. This is the signal text cannot give: two cards
        // can carry one number, a Japanese name is never the name the catalog
        // holds, and the pattern printings differ only in the foil across them.
        let references = observation.artDescriptor == nil
            ? [:]
            : try CatalogSearch.artDescriptors(db, ids: merged.map(\.productId))

        func artDistance(of hit: SearchHit) -> Float? {
            guard let seen = observation.artDescriptor, let reference = references[hit.productId] else { return nil }
            return CardArtDescriptor.distance(seen, reference)
        }

        let scored = merged.map { hit -> Candidate in
            // Against the catalog's name, and against the name actually printed
            // on the card. They differ for a variant: the card says "Snivy" and
            // the catalog says "Snivy (Poke Ball Pattern)". Scoring only the
            // catalog's name punished every variant for a qualifier that is not
            // printed anywhere on it, which handed the plain card a win the
            // camera had not given it.
            let similarity = cleanedName.map { name in
                max(Similarity.dice(name, hit.cleanName), Similarity.dice(name, printedName(of: hit)))
            } ?? 0
            var score = similarity
            // The two set signals are capped together, not added freely: see
            // `setBiasCap`.
            var setBias = 0.0
            if let index = bias.firstIndex(of: hit.groupId) {
                setBias += index < 3 ? recentBias : olderBias
            }
            if preferred.contains(hit.groupId) {
                setBias += preferredSetBias
            }
            score += min(setBias, setBiasCap)
            // An exact number string beats a loose numeric match.
            if let number = observation.number, let hitNumber = hit.number,
               number.caseInsensitiveCompare(hitNumber) == .orderedSame {
                score += 0.1
            }
            // The number and the name point at the same card. That is the
            // strongest signal the scanner ever gets.
            let fromNumber = numberIds.contains(hit.productId)
            let fromName = nameIds.contains(hit.productId)
            let fromArt = artIds.contains(hit.productId)
            if fromNumber, fromName { score += agreementBonus }
            if fromArt { score += artShortlistBonus }

            // Artwork agreement, worth about what a name is worth. A candidate
            // with no reference image scores nothing here and is neither helped
            // nor punished: one product in forty has no image, and "we cannot
            // see it" is not "it is wrong".
            let distance = artDistance(of: hit)
            if let distance {
                score += Double(max(0, CardArtDescriptor.plausible - distance)) * artWeight
            }
            return Candidate(
                hit: hit, score: score, similarity: similarity,
                fromNumber: fromNumber, fromName: fromName, fromArt: fromArt,
                artDistance: distance
            )
        }.sorted { $0.score > $1.score }

        // The words rank first, among themselves, exactly as they always did.
        //
        // The artwork shortlist is thirty cards long and a card matched
        // exactly by its picture scores about what a card matched exactly by
        // its name and its number scores. Letting the two compete on one score
        // let a picture of a Dedenne outrank a Sableye that the name and the
        // number both agreed on. So a card the words never found cannot win on
        // score at all. It wins, when it wins, on the artwork test below.
        let byWords = scored.filter { $0.fromNumber || $0.fromName }
        let byArtOnly = scored.filter { !($0.fromNumber || $0.fromName) }
        var ordered = (byWords + byArtOnly).map(\.hit)
        var top = byWords.first ?? scored[0]

        // What the camera says, on its own.
        //
        // The old test was "exactly one candidate sits within `sameCard`",
        // which held while the only candidates were the handful the words
        // found. The artwork shortlist is thirty cards long and several of
        // them are near by construction, so counting them settles nothing.
        // What settles it is a lead: the nearest picture, and how far it
        // stands in front of the nearest picture of a *different* card.
        let byArt = scored
            .compactMap { candidate in candidate.artDistance.map { (candidate, $0) } }
            .sorted { $0.1 < $1.1 }
        let nearestArt = byArt.first
        let artLead: Float = {
            guard let nearestArt else { return 0 }
            guard let rival = byArt.first(where: { !isSameArtwork($0.0.hit, as: nearestArt.0.hit) })
            else { return .greatestFiniteMagnitude }
            return rival.1 - nearestArt.1
        }()
        let artWinner: Candidate? = {
            guard let nearestArt, nearestArt.1 <= CardArtDescriptor.sameCard else { return nil }
            return artLead >= artDecisiveLead ? nearestArt.0 : nil
        }()

        // Artwork rescues a card whose text is a mess. The words found an
        // attack name and a number one digit out; the picture found the card.
        //
        // Where the words agree with each other they are left alone. A name
        // the catalog holds and a number that finds that same card are two
        // independent readings pointing one way, and a photograph taken across
        // a desk under a lamp is not better evidence than both of them.
        let wordsAgree = scored.contains { $0.fromNumber && $0.similarity >= nameAgreement }
        if let artWinner, !wordsAgree, artWinner.hit.productId != top.hit.productId {
            top = artWinner
            // The chip follows the picture too, nearest first, or he is offered
            // a list ranked by the very words that just lost.
            let byPicture = byArt.map(\.0.hit)
            let pictured = Set(byPicture.map(\.productId))
            ordered = byPicture + ordered.filter { !pictured.contains($0.productId) }
        }
        let artIsDecisive = artWinner?.hit.productId == top.hit.productId

        // A weak name must never beat the number.
        //
        // Scoring ranks by name similarity, so a junk reading can outrank the
        // right card: "scratch" scores 0.53 against "scramble switch" and 0.00
        // against "sableye", which is how a Sableye held over its own number
        // came back as a Japanese trainer. docs/03: a name the catalog does not
        // hold cannot overrule the number, because glare and attack text
        // produce readings like that and the number is still right.
        if cleanedName != nil, !top.fromNumber, top.similarity < nameOnlyAgreement, !artIsDecisive {
            // The number's cards lead the chip. He is far likelier to want one
            // of those than the card a misread name dragged in. Behind them,
            // the cards the picture liked, nearest first — with the words this
            // far gone the picture is the best ordering left, and a card the
            // camera recognised should be one tap away, not buried under the
            // name search that just failed.
            let byNumber = scored.filter(\.fromNumber).map(\.hit)
            let numbered = Set(byNumber.map(\.productId))
            let pictured = byArt.map(\.0.hit).filter { !numbered.contains($0.productId) }
            let shown = numbered.union(pictured.map(\.productId))
            let chip = byNumber + pictured + scored.map(\.hit).filter { !shown.contains($0.productId) }
            // Assign nothing. Neither signal can be trusted: the name is junk,
            // and a number with no name to corroborate it is one misread digit
            // away from a real card in another set. 070/196 is a Sableye in
            // Lost Origin and 070/195 is a Mawile V in Silver Tempest, so
            // "exactly one card carries this number" is not the safety it looks
            // like. docs/03: a wrong card that looks confident is worse than a
            // card marked unknown.
            return MatchResult(
                productId: nil,
                confidence: .uncertain,
                candidates: Array(chip.prefix(candidateCap)),
                printing: defaultPrinting ?? "",
                printingGuessed: false
            )
        }

        // Nothing he read agrees with anything on offer. Assign no product and
        // let the chip ask. A wrong card that looks confident is worse than a
        // card marked unknown.
        if cleanedName != nil, scored.count > 1, top.similarity < nameAgreement, !artIsDecisive {
            return MatchResult(
                productId: nil,
                confidence: .uncertain,
                candidates: Array(ordered.prefix(candidateCap)),
                printing: defaultPrinting ?? "",
                printingGuessed: false
            )
        }

        var confidence: MatchConfidence
        if top.fromNumber, artIsDecisive {
            // The number and the picture picked the same card. Two independent
            // signals, neither derived from the other, and the one pair that
            // survives both glare over the text and a reprint of the artwork.
            confidence = .certain
        } else if top.fromNumber, top.fromName, top.similarity >= nameAgreement {
            confidence = .certain
        } else if scored.count == 1 {
            if top.fromNumber {
                confidence = (cleanedName == nil || top.similarity >= nameAgreement) ? .certain : .likely
            } else {
                confidence = top.similarity >= 0.8 ? .likely : .uncertain
            }
        } else {
            let gap = top.score - scored[1].score
            if top.fromNumber, nameHits.isEmpty {
                confidence = gap >= clearWinnerGap ? .likely : .uncertain
            } else {
                confidence = (gap >= clearWinnerGap && top.similarity >= nameAgreement) ? .likely : .uncertain
            }
        }

        // The name won, and the number pointed at a different card. Two signals
        // disagree, so the chip must ask rather than assert. This is the
        // Cyndaquil case: a total misread off the card matched one Combusken.
        if !numberHits.isEmpty, !top.fromNumber, cleanedName != nil {
            confidence = .uncertain
        }

        // Several different cards carry this number and the words did not say
        // which. Ask the picture, and ask it on an easier question than the one
        // it is usually put.
        //
        // 122/131 is a Professor's Research in Prismatic Evolutions and a
        // Lucario GX Full Art in Forbidden Light. With the name missed, nothing
        // separated the two, so whichever sat on top was sitting there by the
        // order the rows came back — the oldest product id, which owes nothing
        // to the card in his hand. That logged the Lucario: a card he does not
        // own, worth a great deal more than the trainer he was holding.
        //
        // The test above this one is `sameCard`, 0.78, and it is the bar for
        // recognising a card against the whole catalog. That is not the
        // question here. Here there are two or three known candidates and one
        // of them is the card, so what matters is which picture is nearer, not
        // whether either clears the bar for an unprompted identification. The
        // absolute bar drops to `plausible`, which is the bar written for
        // ranking, and the lead does the work — a trainer and a full-art
        // Lucario are not near each other by any measure.
        //
        // A pattern printing of the same card is not such a rival. It is the
        // same card, the assignment is nearly right either way, and the chip
        // settles which printing. Nor is the confidence raised: the bar is the
        // looser one, so the card is assigned and still reviewed.
        //
        // `wordsAgree` guards this the same way it guards the test above. A
        // name the catalog holds and a number that finds that same card are two
        // independent readings pointing one way, and the picture does not get
        // to move an answer they agree on.
        if confidence == .uncertain, !wordsAgree, !top.fromName, !artIsDecisive,
           scored.contains(where: { !isVariantSibling($0.hit, of: top.hit) }) {
            if let nearestArt, nearestArt.1 <= CardArtDescriptor.plausible, artLead >= artDecisiveLead {
                if nearestArt.0.hit.productId != top.hit.productId {
                    top = nearestArt.0
                    let byPicture = byArt.map(\.0.hit)
                    let pictured = Set(byPicture.map(\.productId))
                    ordered = byPicture + ordered.filter { !pictured.contains($0.productId) }
                }
            } else if cleanedName == nil {
                // No name and no usable picture. Nothing read distinguishes
                // these cards, and docs/03 is clear that a wrong card looking
                // confident is worse than a card marked unknown.
                return MatchResult(
                    productId: nil,
                    confidence: .uncertain,
                    candidates: Array(ordered.prefix(candidateCap)),
                    printing: defaultPrinting ?? "",
                    printingGuessed: false
                )
            }
        }

        // Two printings of one card, in two different sets, scoring the same.
        // Neither the picture nor the number can separate them, so the score
        // deciding it is deciding it by accident.
        if confidence != .certain, !artIsDecisive, scored.count > 1,
           let rival = scored.first(where: { candidate in
               candidate.hit.productId != top.hit.productId
                   && !isVariantSibling(candidate.hit, of: top.hit)
                   && isSameArtwork(candidate.hit, as: top.hit)
                   && top.score - candidate.score <= coinTossGap
           }) {
            // One last thing to try before asking: a set beats a shelf. He
            // opens packs, so a card in his hand came out of the set far more
            // often than out of a prize pack or a deck. Where exactly one of
            // the two is a shelf listing, that settles it.
            let shelves = try shelfGroups(db, groupIds: [top.hit.groupId, rival.hit.groupId])
            let topIsShelf = shelves.contains(top.hit.groupId)
            let rivalIsShelf = shelves.contains(rival.hit.groupId)
            if topIsShelf, !rivalIsShelf {
                top = rival
            } else if topIsShelf == rivalIsShelf {
                return MatchResult(
                    productId: nil,
                    confidence: .uncertain,
                    candidates: Array(ordered.prefix(candidateCap)),
                    printing: defaultPrinting ?? "",
                    printingGuessed: false
                )
            }
        }

        let product = top.hit

        // The pattern variants. Black Bolt prints Snivy three times at 001/086:
        // plain, Poké Ball pattern, and Master Ball pattern. The three carry the
        // same name and the same number, and only the artwork behind them
        // differs, which no reading of the text can see. The plain card wins the
        // name every time, so a pattern card was logged as the plain one and
        // looked certain doing it. Ask instead, and lead the chip with the
        // family so the answer is one tap away.
        // The chosen card first, then its siblings. The order matters: the
        // separation test below measures every other printing against this
        // one, and artwork may have chosen a card the score did not rank top.
        let siblings = scored.filter { isVariantSibling($0.hit, of: product) }
        let family = siblings.filter { $0.hit.productId == product.productId }
            + siblings.filter { $0.hit.productId != product.productId }
        var chipOrder = ordered
        if family.count > 1 {
            // Artwork is the one thing that can separate these, and it can: the
            // Poké Ball printing is stamped across the whole card and reads as a
            // different picture, not a different word. When every sibling has a
            // reference image and the nearest is clearly nearer, that is the
            // answer and he is not asked.
            //
            // When it is not clearly nearer, ask. That covers poor light, and it
            // covers the common case where TCGplayer holds no image for the
            // pattern printing at all — most of them have none.
            // A positive identification, not merely the least unlike. The
            // printings of one card sit about 0.5 apart, so "nearest" is a
            // coin toss between two cards that are both far away — which is
            // what a Master Ball scan looks like when only the plain card has
            // a reference. The top must be much nearer than that, and every
            // sibling that *has* a reference must be clearly further. A sibling
            // with no reference is ignored: we cannot see it, and that is not
            // evidence against it, which is why the bar to its left is tight.
            let rivals = family.dropFirst().compactMap(\.artDistance)
            let separated = (top.artDistance ?? .greatestFiniteMagnitude) <= artSamePrinting
                && rivals.allSatisfy { $0 - (top.artDistance ?? 0) >= artFamilyGap }
            if separated {
                // The camera has answered the only question this family raises,
                // and answered it better than any reading of the text could.
                if top.fromNumber { confidence = .certain }
            } else {
                confidence = .uncertain
            }
            let familyIds = Set(family.map(\.hit.productId))
            chipOrder = family.map(\.hit) + ordered.filter { !familyIds.contains($0.productId) }
        }

        let printings = try availablePrintings(db, productId: product.productId)
        let choice = PrintingRules.choose(available: printings, rarity: product.rarity, sessionDefault: defaultPrinting)
        if choice.guessed && confidence != .uncertain {
            confidence = .uncertain
        }

        return MatchResult(
            productId: product.productId,
            confidence: confidence,
            candidates: Array(chipOrder.prefix(candidateCap)),
            printing: choice.printing,
            printingGuessed: choice.guessed
        )
    }

    /// How many different set totals a group must hold before it is a shelf
    /// rather than a set.
    ///
    /// A real set numbers every card out of one total: 165 of the English
    /// groups hold exactly one, and Silver Tempest's 215 cards all say 195.
    /// A catalogue shelf holds whatever was left over, from every era at once
    /// — World Championship Decks holds 70 different totals and Prize Pack
    /// Series Cards 31. Three keeps Aquapolis and the other two-numbering sets
    /// on the right side of the line.
    ///
    /// This decides nothing on its own. Scoring every shelf card down was
    /// measured over 300 readings and lost a card in each condition, because it
    /// moved wrong answers around rather than fixing them. It earns its place
    /// only inside the coin toss below, where the question is narrower and it
    /// is the only thing left to answer it with.
    static let shelfTotals = 3

    /// How near the runner-up may score before the two are a coin toss.
    ///
    /// Reprints are what is left of the scanner's errors: one illustration
    /// printed in two sets under one name, often carrying one collector number.
    /// Nothing on the face of the card separates them — not the picture, which
    /// is the same picture, and not the number, which is the same number. The
    /// scanner was picking between them on the third decimal place of a score,
    /// which is to say by accident, and it was wrong about as often as it was
    /// right.
    ///
    /// The right card was in the chip every single time this happened. So ask,
    /// rather than guess: a tap costs him a second, and a Prize Pack Froslass
    /// filed as a Chilling Reign Froslass costs him a wrong price on a card he
    /// will not look at again. docs/03: a wrong card that looks confident is
    /// worse than a card marked unknown.
    static let coinTossGap = 0.02

    /// The groups, among those given, that are catalogue shelves rather than
    /// sets: they hold cards numbered out of `shelfTotals` different totals or
    /// more, which no print run does.
    static func shelfGroups(_ db: Database, groupIds: Set<Int>) throws -> Set<Int> {
        guard !groupIds.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: groupIds.count).joined(separator: ",")
        let sql = "SELECT groupId FROM product WHERE groupId IN (\(placeholders))"
            + " AND setTotal IS NOT NULL AND isSealed = 0"
            + " GROUP BY groupId HAVING COUNT(DISTINCT setTotal) >= \(shelfTotals)"
        return Set(try Int.fetchAll(db, sql: sql, arguments: StatementArguments(Array(groupIds))))
    }

    /// The card's name as the card prints it: the catalog's name with the
    /// qualifier in parentheses and the sub-name in brackets both dropped, then
    /// cleaned the way the catalog's own names are.
    ///
    /// TCGplayer uses the two brackets for two different things, and neither
    /// belongs to the title the camera reads. "Snivy (Poke Ball Pattern)" is a
    /// printing of Snivy, and the pattern is stamped, not written. "Professor's
    /// Research [Professor Oak]" prints "Professor's Research" as its title and
    /// "Professor Oak" as a separate line lower down, so the title alone scored
    /// 0.75 against the catalog's name — under the bar a name must clear when
    /// it is the only signal, which is why the card came back as nothing
    /// whenever his hand covered the number.
    ///
    /// A promo or an Energy also carries its number in the name: "Pikachu ex -
    /// 109 (30th Celebration)". The card prints "Pikachu ex", so the number
    /// goes too. With it, a Jumbo "Pikachu EX" outscored the real card on the
    /// name while the number pointed at the real one.
    static func printedName(of hit: SearchHit) -> String {
        let cut = [
            hit.name.firstIndex(of: "("),
            hit.name.firstIndex(of: "["),
            hit.name.firstMatch(of: numberSuffix)?.range.lowerBound,
        ].compactMap { $0 }.min()
        guard let cut else { return hit.cleanName }
        return NameCleaner.clean(String(hit.name[hit.name.startIndex..<cut]))
    }

    /// " - 109", " - SVP193", " - 001": TCGplayer's number inside a name.
    private static let numberSuffix = #/\s-\s[A-Z]{0,4}\d{1,3}[a-z]?(?=\s|$)/#

    /// The parenthetical part of a product's name, which is what distinguishes
    /// one printing of a card from another: "Poke Ball Pattern". Nil for the
    /// plain card, whose name carries no qualifier at all.
    static func qualifier(of hit: SearchHit) -> String? {
        guard let open = hit.name.firstIndex(of: "("),
              let close = hit.name[open...].firstIndex(of: ")")
        else { return nil }
        let inside = hit.name[hit.name.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return inside.isEmpty ? nil : inside
    }

    /// True when two products are the same card printed twice in one set: the
    /// same set, the same number, and a name that is the other's name plus a
    /// qualifier. "Snivy" and "Snivy (Poké Ball Pattern)" are such a pair.
    static func isVariantSibling(_ a: SearchHit, of b: SearchHit) -> Bool {
        guard a.groupId == b.groupId, let number = a.numberNum, number == b.numberNum else { return false }
        if a.cleanName == b.cleanName { return true }
        return a.cleanName.hasPrefix(b.cleanName + " ") || b.cleanName.hasPrefix(a.cleanName + " ")
    }

    /// True when two products carry the same picture.
    ///
    /// A card reprinted in another set is the same picture in a second row,
    /// and so is a promo of it, and so is a pattern printing of it. None of
    /// them is a rival for "which card is this" — the picture cannot tell them
    /// apart and is not asked to. Same name is the test, because TCGplayer
    /// files a reprint under the name it was first printed with, and a pattern
    /// printing under that name plus a qualifier.
    static func isSameArtwork(_ a: SearchHit, as b: SearchHit) -> Bool {
        a.productId == b.productId || a.cleanName == b.cleanName || isVariantSibling(a, of: b)
    }

    /// The line that reads best as a card name, and what it found.
    ///
    /// Each candidate is scored by how well the catalog's answer matches the
    /// line itself. "Sableye" finds a card called Sableye and scores 1.0.
    /// "Scratch" finds a Scramble Switch and scores 0.53, so it loses to any
    /// line that names a real card. A line agreeing with the number wins
    /// outright, because that is two signals pointing the same way.
    static func readName(_ db: Database, observation: ScanObservation, numberHits: [SearchHit]) throws -> (String?, [SearchHit]) {
        let read = observation.nameCandidates.isEmpty
            ? [observation.name].compactMap { $0 }
            : observation.nameCandidates
        // A name printed in Japanese cannot match the catalog, which files the
        // card under its English name. Such a line is not a weak signal, it is
        // no signal, and scoring it dragged every Japanese card down to
        // "nothing agrees" and assigned it no product at all. Drop the line and
        // let the number decide.
        let lines = read.filter { !FrameInterpreter.isJapanese($0) }
        guard !lines.isEmpty else { return (nil, []) }

        // The catalog holds every card name there is, so membership settles it
        // outright: "Sableye" is a card and "Scratch" is not. The lines arrive
        // best-first, so the first real card name wins.
        for line in lines {
            let cleaned = NameCleaner.clean(line)
            guard !cleaned.isEmpty, try isACardName(db, cleaned) else { continue }
            if numberHits.contains(where: { $0.cleanName == cleaned }) {
                // The line names one of the number's cards. Two signals agree.
                return (line, [])
            }
            return (line, try nameCandidates(db, name: line))
        }

        // Nothing he read is a card name. Fall back to the closest fuzzy match,
        // because OCR misreads a name as often as it reads the wrong line.
        var best: (line: String, hits: [SearchHit], score: Double)?
        for line in lines {
            let cleaned = NameCleaner.clean(line)
            guard !cleaned.isEmpty else { continue }

            // A line that names one of the number's cards settles it.
            if let agreeing = numberHits.map({ Similarity.dice(cleaned, $0.cleanName) }).max(), agreeing >= nameAgreement {
                return (line, [])
            }

            let hits = try nameCandidates(db, name: line)
            let score = hits.map { Similarity.dice(cleaned, $0.cleanName) }.max() ?? 0
            if best == nil || score > best!.score {
                best = (line, hits, score)
            }
        }
        guard let best else { return (lines.first, []) }
        return (best.line, best.hits)
    }

    private struct Candidate {
        var hit: SearchHit
        var score: Double
        var similarity: Double
        var fromNumber: Bool
        var fromName: Bool
        /// True when the artwork shortlist proposed this candidate.
        var fromArt: Bool
        /// How far the card in the frame is from this candidate's artwork. Nil
        /// when the frame held no card, or the catalog holds no image for it.
        var artDistance: Float?
    }

    /// Re-resolve a card inside one set by its number. Used by review's
    /// "reassign to set". Returns nil when the set has no such number.
    static func product(_ db: Database, inGroup groupId: Int, numberNum: Int) throws -> SearchHit? {
        let ids = try Int.fetchAll(db, sql: "SELECT productId FROM product WHERE groupId = ? AND numberNum = ? ORDER BY isSealed, productId", arguments: [groupId, numberNum])
        guard let first = ids.first else { return nil }
        return try CatalogSearch.fetchHits(db, ids: [first], filter: SearchFilter()).first
    }

    /// Every card carrying this number in any of these sets.
    ///
    /// The scope's widening pass. Unlike `product(_:inGroup:numberNum:)` above
    /// it returns them all, because the point is to add candidates and let the
    /// scoring choose, not to assert an answer.
    static func product(_ db: Database, inGroups groupIds: [Int], numberNum: Int) throws -> [SearchHit] {
        guard !groupIds.isEmpty else { return [] }
        let list = Set(groupIds).sorted().map(String.init).joined(separator: ",")
        let ids = try Int.fetchAll(
            db,
            sql: "SELECT productId FROM product WHERE groupId IN (\(list)) AND numberNum = ? AND isSealed = 0 LIMIT 50",
            arguments: [numberNum]
        )
        guard !ids.isEmpty else { return [] }
        return try CatalogSearch.fetchHits(db, ids: ids, filter: SearchFilter())
    }

    static func availablePrintings(_ db: Database, productId: Int) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT subTypeName FROM price WHERE productId = ? ORDER BY subTypeName", arguments: [productId])
    }

    private static func numberCandidates(_ db: Database, parsed: CollectorNumber) throws -> [SearchHit] {
        guard let n = parsed.numberNum else { return [] }
        let ids: [Int]
        if let code = parsed.setCode {
            // The promo and Energy sets store a bare "109" and no set code on
            // the product, so the code is found on the set instead: MEP is the
            // abbreviation of ME: Mega Evolution Promo.
            ids = try Int.fetchAll(db, sql: """
                SELECT productId FROM product
                WHERE numberNum = ? AND isSealed = 0
                  AND (setCode = ? COLLATE NOCASE
                       OR groupId IN (SELECT groupId FROM cardSet WHERE abbreviation = ? COLLATE NOCASE))
                LIMIT 50
                """, arguments: [n, code, code])
        } else if let total = parsed.setTotal {
            ids = try Int.fetchAll(db, sql: "SELECT productId FROM product WHERE setTotal = ? AND numberNum = ? AND isSealed = 0 LIMIT 50", arguments: [total, n])
        } else {
            return []
        }
        guard !ids.isEmpty else { return [] }
        return try CatalogSearch.fetchHits(db, ids: ids, filter: SearchFilter())
    }

    /// True when the catalog holds a single card by exactly this name.
    /// Backed by `idx_product_clean`, so it is one indexed lookup per line.
    static func isACardName(_ db: Database, _ cleanName: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS (SELECT 1 FROM product WHERE cleanName = ? AND isSealed = 0)",
            arguments: [cleanName]
        ) ?? false
    }

    private static func nameCandidates(_ db: Database, name: String) throws -> [SearchHit] {
        var filter = SearchFilter()
        filter.kind = .singles
        // By relevance, not by value. The candidate cap must never drop the
        // closest name in favour of a dearer card that reads like it.
        let request = SearchRequest(text: name, context: .scanning, filter: filter, ranking: .byRelevance)
        return Array(try CatalogSearch.search(db, request: request).prefix(candidateCap))
    }
}

enum Similarity {
    /// Sørensen–Dice over character bigrams. Tolerant of OCR misreads and of a
    /// suffix like "ex" that one side lacks. 1 is identical, 0 is disjoint.
    static func dice(_ a: String, _ b: String) -> Double {
        let x = bigrams(a)
        let y = bigrams(b)
        guard !x.isEmpty, !y.isEmpty else { return a == b ? 1 : 0 }
        var counts: [String: Int] = [:]
        for g in x { counts[g, default: 0] += 1 }
        var shared = 0
        for g in y {
            if let c = counts[g], c > 0 {
                counts[g] = c - 1
                shared += 1
            }
        }
        return 2.0 * Double(shared) / Double(x.count + y.count)
    }

    private static func bigrams(_ s: String) -> [String] {
        let chars = Array(s.replacingOccurrences(of: " ", with: ""))
        guard chars.count >= 2 else { return chars.map(String.init) }
        return (0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) }
    }
}
