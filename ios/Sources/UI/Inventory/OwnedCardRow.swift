import SwiftUI

/// One inventory line. Dense: slab or thumbnail, identity, market, basis.
struct OwnedCardRow: View {
    let row: InventoryRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let cert = row.card.certNumber {
                SlabBadge(imageUrl: row.hit?.imageUrl, grader: row.card.graderRaw, cert: cert)
                    .frame(width: 48, height: 70)
            } else {
                ProductThumbnail(urlString: row.hit?.imageUrl, isSealed: false)
                    .frame(width: 44, height: 62)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.hit?.name ?? row.card.ocrName ?? "Unknown")
                        .lineLimit(1)
                    ConfidenceMarker(confidence: row.card.matchConfidence, identified: row.card.isIdentified, isBulk: row.card.isBulk)
                }
                if let hit = row.hit {
                    Text(hit.setName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let number = row.hit?.number { Text(number).monospacedDigit() }
                    if !row.card.printing.isEmpty { Text(row.card.printing) }
                    Text(CardCondition(rawValue: row.card.condition)?.short ?? row.card.condition)
                    if row.card.quantity > 1 { Text("×\(row.card.quantity)") }
                    if row.card.isPersonalCollection { Text("PC") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                TagBadgeRow(tags: row.card.tags)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(row.marketCents?.asCurrency ?? "—")
                    .font(.body.monospacedDigit())
                if row.card.isBulk {
                    Text("bulk")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let diff = row.unrealizedCents {
                    // The gain against what the card cost, split basis or not.
                    // This is the number he reads before he sells.
                    Text((diff >= 0 ? "+" : "−") + abs(diff).asCurrency)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(diff >= 0 ? .green : .red)
                } else if row.card.totalBasisCents > 0 {
                    Text("cost \(row.card.totalBasisCents.asCurrency)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("no cost")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A small slab: label strip with grader and cert on top, the card below.
struct SlabBadge: View {
    var imageUrl: String?
    var grader: String?
    var cert: String

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text((grader ?? "slab").uppercased())
                    .font(.system(size: 7, weight: .heavy))
                Text(cert)
                    .font(.system(size: 6.5, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .background(Color(white: 0.96))
            ProductThumbnail(urlString: imageUrl, isSealed: false)
                .padding(3)
        }
        .background(Color(white: 0.9))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.75), lineWidth: 1))
    }
}
