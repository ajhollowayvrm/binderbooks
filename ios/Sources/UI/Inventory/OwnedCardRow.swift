import SwiftUI

/// One inventory line. Dense: slab or thumbnail, identity, market, basis.
///
/// It draws one card, or one stack of copies: the price stays the price of one
/// — the list sorted by it — and the cost and the gain are the stack's, with
/// the total value under the price so the two are never read as one figure.
struct OwnedCardRow: View {
    let row: InventoryRow
    /// Set when the line stands for several copies of the same thing. Nil
    /// wherever a screen lists cards one at a time: a picker, an export, the
    /// copies inside a stack.
    var stack: InventoryStack?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if row.card.isSlabbed {
                SlabBadge(imageUrl: row.hit?.imageUrl, grader: row.card.graderRaw, grade: row.card.gradeLabel, cert: row.card.certNumber)
                    .frame(width: 48, height: 74)
            } else {
                ProductThumbnail(urlString: row.hit?.imageUrl, isSealed: row.card.isSealedSelf)
                    .frame(width: 44, height: 62)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .lineLimit(1)
                    ConfidenceMarker(confidence: row.card.matchConfidence, identified: row.card.hasIdentity, isBulk: row.card.isBulk)
                }
                if let setName = row.setName {
                    Text(setName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if row.card.isSealedSelf {
                        Text("Sealed")
                    } else {
                        if let number = row.number { Text(number).monospacedDigit() }
                        if !row.card.printing.isEmpty { Text(row.card.printing) }
                        Text(CardCondition(rawValue: row.card.condition)?.short ?? row.card.condition)
                        if let language = CardLanguage.badge(row.card.language) { Text(language) }
                    }
                    if copies > 1 { Text("×\(copies)") }
                    if row.card.isPersonalCollection { Text("PC") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                TagBadgeRow(tags: row.card.tags)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(row.priceText)
                    .font(.body.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let grader = row.graderAtGrader, row.projectedRange != nil {
                    Text("if \(grader.uppercased()) grades it")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if isStacked, let total = stack?.totalValueCents {
                    Text("\(total.asCurrency) total")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if row.card.isBulk {
                    Text("bulk")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if row.projectedRange == nil, let diff = gainCents {
                    // The gain against what the card cost, split basis or not.
                    // This is the number he reads before he sells. Not shown
                    // under a projection, because it is a gain on the raw
                    // price and the row no longer leads with that.
                    Text((diff >= 0 ? "+" : "−") + abs(diff).asCurrency)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(diff >= 0 ? .green : .red)
                } else if basisCents > 0 {
                    Text("cost \(basisCents.asCurrency)")
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

    /// Cards, not lines: a bulk line of 40 counts 40, and a stack of nine
    /// packs counts nine.
    private var copies: Int { stack?.copies ?? max(1, row.card.quantity) }

    /// True only for a line that stands for more than one card. A bulk line of
    /// 40 is one card, and its figures are already its own.
    private var isStacked: Bool { stack?.isStacked ?? false }

    /// The cost and the gain cover every copy the line stands for, so they can
    /// be read against the total above them.
    private var basisCents: Int { isStacked ? (stack?.totalBasisCents ?? 0) : row.card.totalBasisCents }

    private var gainCents: Int? { isStacked ? stack?.unrealizedCents : row.unrealizedCents }
}

/// The look of a grader's label. PSA prints a red label with white text. CGC
/// prints a black label with a blue band. Anything else keeps the plain gray
/// label the app started with.
struct SlabStyle {
    var label: Color
    var text: Color
    var accent: Color
    var shell: Color
    var border: Color

    static func of(_ grader: String?) -> SlabStyle {
        switch grader?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "psa":
            return SlabStyle(
                label: Color(red: 0.78, green: 0.09, blue: 0.13),
                text: .white,
                accent: .white,
                shell: Color(white: 0.93),
                border: Color(white: 0.7)
            )
        case "cgc":
            return SlabStyle(
                label: Color(white: 0.1),
                text: .white,
                accent: Color(red: 0.2, green: 0.55, blue: 0.9),
                shell: Color(white: 0.88),
                border: Color(white: 0.6)
            )
        default:
            return SlabStyle(
                label: Color(white: 0.96),
                text: .primary,
                accent: .secondary,
                shell: Color(white: 0.9),
                border: Color(white: 0.75)
            )
        }
    }
}

/// A small slab: label strip with grader, grade, and cert on top, the card
/// below.
struct SlabBadge: View {
    var imageUrl: String?
    var grader: String?
    var grade: String?
    var cert: String?

    var body: some View {
        let style = SlabStyle.of(grader)
        VStack(spacing: 0) {
            SlabLabel(grader: grader, grade: grade, cert: cert, style: style)
            ProductThumbnail(urlString: imageUrl, isSealed: false)
                .padding(3)
        }
        .background(style.shell)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(style.border, lineWidth: 1))
    }
}

/// The strip across the top of a slab: grader name, the grade large, and the
/// cert number. The grade is what he reads first on a real label.
struct SlabLabel: View {
    var grader: String?
    var grade: String?
    var cert: String?
    var style: SlabStyle
    var scale: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            Text((grader ?? "slab").uppercased())
                .font(.system(size: 7 * scale, weight: .heavy))
                .foregroundStyle(style.text)
            if let grade, !grade.isEmpty {
                Text(grade.uppercased())
                    .font(.system(size: 10 * scale, weight: .black))
                    .foregroundStyle(style.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if let cert, !cert.isEmpty {
                Text(cert)
                    .font(.system(size: 6.5 * scale, weight: .medium).monospacedDigit())
                    .foregroundStyle(style.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2 * scale)
        .background(style.label)
    }
}
