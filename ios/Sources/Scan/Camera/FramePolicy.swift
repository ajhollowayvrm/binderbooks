import Foundation

/// What to spend on each camera frame.
///
/// Owning the session means about thirty frames a second arrive, and running
/// text recognition, rectangle detection and a feature print on all of them
/// would heat the phone and drop the frame rate without reading anything
/// better. Each kind of work gets its own cadence, and the expensive work is
/// gated on the cheap work having found something worth looking at.
///
/// Pure and time-injected, so the cadence is testable without a camera.
struct FramePolicy {
    /// Text is the most expensive request and the slowest-changing signal: the
    /// name and number do not move while he holds the card still.
    var textInterval: TimeInterval = 0.25

    /// Finding the card is cheap and wanted often, because it drives the
    /// viewfinder outline he aims with.
    var cardInterval: TimeInterval = 0.1

    /// Below this the frame is too soft to sign. Measured: blur is the only
    /// degradation that really costs artwork accuracy.
    var minimumSharpness: Double = 25

    /// How long a card may sit in view with nothing signed at all before a
    /// soft frame is signed anyway.
    ///
    /// `minimumSharpness` is the right bar when a sharp frame is coming. In a
    /// dim room none is: the whole run stays under it, no signature is ever
    /// taken, and artwork silently stops being a signal at exactly the moment
    /// the words are struggling too. A soft signature is worse evidence than a
    /// sharp one and far better than none, so after this long the scanner takes
    /// what it can get and marks it — see `ScanObservation.artIsBestEffort`.
    var signingPatience: TimeInterval = 0.8

    /// The floor even a best-effort signature will not go below. An empty
    /// chute and a lens cap also score low, and signing those describes the
    /// room rather than a card.
    var bestEffortFloor: Double = 4

    /// Once a frame this sharp has been signed, stop signing. Anything better
    /// is not going to change the answer.
    var goodEnoughSharpness: Double = 160

    private var lastText: Date?
    private var lastCard: Date?

    /// Spelled out because the private state above would otherwise make the
    /// memberwise initializer private, and the cadences have to be settable
    /// from a test that has no camera.
    init(
        textInterval: TimeInterval = 0.25,
        cardInterval: TimeInterval = 0.1,
        minimumSharpness: Double = 25,
        goodEnoughSharpness: Double = 160,
        signingPatience: TimeInterval = 0.8,
        bestEffortFloor: Double = 4
    ) {
        self.textInterval = textInterval
        self.cardInterval = cardInterval
        self.minimumSharpness = minimumSharpness
        self.goodEnoughSharpness = goodEnoughSharpness
        self.signingPatience = signingPatience
        self.bestEffortFloor = bestEffortFloor
    }

    struct Decision: Equatable {
        var readText = false
        var findCard = false
    }

    /// What this frame is worth doing.
    mutating func decide(at now: Date) -> Decision {
        var decision = Decision()
        if lastText == nil || now.timeIntervalSince(lastText!) >= textInterval {
            decision.readText = true
            lastText = now
        }
        if lastCard == nil || now.timeIntervalSince(lastCard!) >= cardInterval {
            decision.findCard = true
            lastCard = now
        }
        return decision
    }

    /// Whether a card found in this frame is worth the cost of signing it.
    ///
    /// A soft frame is not worth it at any price, and once something sharp has
    /// been signed for the card in view, signing again buys nothing.
    func shouldSign(sharpness: Double, bestSoFar: Double) -> Bool {
        guard sharpness >= minimumSharpness else { return false }
        guard bestSoFar < goodEnoughSharpness else { return false }
        // Only an improvement is worth the work.
        return sharpness > bestSoFar
    }

    /// Whether to sign a frame the bar above rejected, because the card has sat
    /// in view this long and **nothing** has been signed for it.
    ///
    /// Only ever true while `bestSoFar` is zero. Once any signature exists, the
    /// ordinary bar governs again: this exists to break a starvation, not to
    /// lower the standard.
    func shouldSignBestEffort(sharpness: Double, bestSoFar: Double, unsignedFor: TimeInterval) -> Bool {
        guard bestSoFar <= 0 else { return false }
        guard unsignedFor >= signingPatience else { return false }
        guard sharpness >= bestEffortFloor else { return false }
        // Still below the real bar, or the caller would not be asking.
        return sharpness < minimumSharpness
    }

    mutating func reset() {
        lastText = nil
        lastCard = nil
    }

    /// Whether this frame holds something he is trying to scan, and no card.
    ///
    /// A card held so close that its left and right edges leave the frame has
    /// no quadrilateral for Vision to find, and since everything is read from
    /// inside that quadrilateral, such a frame reads nothing at all: no words,
    /// no signature, no outline, no card logged. Measured on a 1080 by 1920
    /// frame, a card fills the width at 0.79 of the frame's height, and above
    /// that the detection stops: at 0.85 the number no longer reads, and at
    /// 0.90 no rectangle is found at all.
    ///
    /// An empty chute also has no card in it, and it is not a problem. The two
    /// are told apart by how much detail the frame holds, which is the same
    /// score that decides whether a frame is worth signing.
    func looksFilledButUnread(sawCard: Bool, sharpness: Double) -> Bool {
        !sawCard && sharpness >= minimumSharpness
    }
}
