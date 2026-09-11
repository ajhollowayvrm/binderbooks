import SwiftUI

/// Owned cards as large art, three per row. It carries no scroll view, so it
/// also works inside one row of a list.
///
/// A cell cannot hold the basis or the gain. Those stay in the list layout, in
/// the summary tiles, and on the card detail screen.
struct OwnedCardGrid: View {
    var rows: [InventoryRow]
    var columns = 3
    var isSelecting = false
    var selection: Set<UUID> = []
    var onToggle: (UUID) -> Void = { _ in }
    /// Starts selection with this card ticked.
    var onLongPress: (UUID) -> Void = { _ in }

    private var gridItems: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: columns)
    }

    var body: some View {
        LazyVGrid(columns: gridItems, spacing: 14) {
            ForEach(rows) { row in
                if isSelecting {
                    Button {
                        onToggle(row.card.id)
                    } label: {
                        OwnedCardCard(row: row, isSelected: selection.contains(row.card.id), isSelecting: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(value: AppRoute.ownedCard(row.card.id)) {
                        OwnedCardCard(row: row)
                    }
                    .buttonStyle(.plain)
                    // A simultaneous gesture, so the long press cannot swallow
                    // the tap that pushes the card.
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.4).onEnded { _ in onLongPress(row.card.id) }
                    )
                }
            }
        }
    }
}

/// One owned cell: art, market price, set, then a compact identity line.
struct OwnedCardCard: View {
    var row: InventoryRow
    var isSelected = false
    var isSelecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            art
            HStack(spacing: 4) {
                Text(row.priceText)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                ConfidenceMarker(
                    confidence: row.card.matchConfidence,
                    identified: row.card.isIdentified,
                    isBulk: row.card.isBulk
                )
            }
            // The name leads, then the set. The art names a card faster than
            // text does — until it does not: a slab covers its own art with a
            // label, and a cell whose image is still loading has nothing else
            // to say which card it is.
            Text(row.hit?.name ?? row.card.ocrName ?? "Unknown")
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let setName = row.hit?.setName {
                Text(setName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            identity
            TagBadgeRow(tags: row.card.tags, limit: 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The number, the condition, and the count. A slab shows the grader and
    /// the cert number instead, because that is how he reads a slab.
    @ViewBuilder
    private var identity: some View {
        HStack(spacing: 5) {
            if row.card.isSlabbed {
                // The label above already shows all three. One line here
                // holds two of them without truncating.
                Text(((row.card.graderRaw ?? "").uppercased() + " " + (row.card.gradeLabel ?? "")).trimmingCharacters(in: .whitespaces))
                    .fontWeight(.semibold)
                if row.card.gradeLabel == nil, let cert = row.card.certNumber {
                    Text(cert)
                        .monospacedDigit()
                }
            } else {
                if let number = row.hit?.number {
                    Text(number)
                        .monospacedDigit()
                }
                Text(CardCondition(rawValue: row.card.condition)?.short ?? row.card.condition)
                if row.card.quantity > 1 {
                    Text("×\(row.card.quantity)")
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    /// A slab draws its label over the art, so a graded card reads as a slab
    /// at grid size the way it does in the list.
    private var art: some View {
        Group {
            if row.card.isSlabbed {
                let style = SlabStyle.of(row.card.graderRaw)
                VStack(spacing: 0) {
                    SlabLabel(grader: row.card.graderRaw, grade: row.card.gradeLabel, cert: row.card.certNumber, style: style, scale: 1.6)
                    artImage.padding(4)
                }
                .background(style.shell)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(style.border, lineWidth: 1))
            } else {
                artImage
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(5.0 / 7.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
                    .background(Circle().fill(.black.opacity(isSelected ? 0 : 0.25)))
                    .padding(4)
                    // The mark morphs between the two symbols, and scales in
                    // from the corner it sits in.
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.scale(scale: 0.4, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .overlay {
            if isSelecting, isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.tint, lineWidth: 3)
                    .transition(.opacity)
            }
        }
    }

    private var artImage: some View {
        AsyncImage(url: row.hit?.largeImageURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            case .empty:
                Rectangle().fill(.fill.quaternary)
            default:
                Rectangle()
                    .fill(.fill.quaternary)
                    .overlay {
                        Image(systemName: "rectangle.portrait")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
    }
}
