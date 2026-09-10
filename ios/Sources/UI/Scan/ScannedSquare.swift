import SwiftUI

/// One scanned card. Certain matches stay quiet. Uncertain ones are marked so
/// he can see, at a glance, which six of three hundred need a look.
struct ScannedSquare: View {
    let card: OwnedCard
    let hit: SearchHit?
    let marketCents: Int?

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                ProductThumbnail(urlString: hit?.imageUrl, isSealed: false)
                    .aspectRatio(0.72, contentMode: .fit)
                    .overlay(alignment: .bottom) {
                        if let cert = card.certNumber {
                            Text("Cert \(cert)")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(2)
                                .frame(maxWidth: .infinity)
                                .background(.thinMaterial)
                        } else if let number = hit?.number {
                            Text(number)
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .padding(2)
                                .frame(maxWidth: .infinity)
                                .background(.thinMaterial)
                        }
                    }
                ConfidenceMarker(confidence: card.matchConfidence, identified: card.isIdentified, isBulk: card.isBulk)
                    .padding(3)
            }
            Text(hit?.name ?? card.ocrName ?? (card.certNumber != nil ? "Slab" : "Unknown"))
                .font(.system(size: 10))
                .lineLimit(1)
            Text(marketCents?.asCurrency ?? " ")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

struct ConfidenceMarker: View {
    let confidence: MatchConfidence
    let identified: Bool
    var isBulk: Bool = false

    var body: some View {
        if !identified {
            badge("?", color: .gray)
        } else if isBulk {
            badge("B", color: .secondary)
        } else {
            switch confidence {
            case .certain:
                EmptyView()
            case .manual:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .background(Circle().fill(.white))
            case .likely:
                Circle()
                    .fill(.secondary)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.white, lineWidth: 1))
            case .uncertain:
                badge("?", color: .orange)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 1))
    }
}
