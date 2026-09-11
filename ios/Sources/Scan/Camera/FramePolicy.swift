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
        goodEnoughSharpness: Double = 160
    ) {
        self.textInterval = textInterval
        self.cardInterval = cardInterval
        self.minimumSharpness = minimumSharpness
        self.goodEnoughSharpness = goodEnoughSharpness
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

    mutating func reset() {
        lastText = nil
        lastCard = nil
    }
}
