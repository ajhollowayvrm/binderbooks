import SwiftUI

/// Owned cards as large art, three per row. It carries no scroll view, so it
/// also works inside one row of a list.
///
/// One cell per stack, not per card: nine identical packs are one cell with
/// "×9" on the art. A tap on a stacked cell opens its copies.
///
/// A cell cannot hold the basis or the gain. Those stay in the list layout, in
/// the summary tiles, and on the card detail screen.
struct OwnedCardGrid: View {
    var stacks: [InventoryStack]
    var columns = 3
    var isSelecting = false
    var selection: Set<UUID> = []
    /// Every card in the cell, because a cell stands for all of its copies.
    var onToggle: ([UUID]) -> Void = { _ in }
    /// Starts selection with the cell's cards ticked.
    var onLongPress: ([UUID]) -> Void = { _ in }

    private var gridItems: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: columns)
    }

    var body: some View {
        LazyVGrid(columns: gridItems, spacing: 14) {
            ForEach(stacks) { stack in
                if isSelecting {
                    Button {
                        onToggle(stack.cardIds)
                    } label: {
                        OwnedCardCard(stack: stack, isSelected: isSelected(stack), isSelecting: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    OwnedCardCard(stack: stack)
                        .pushOrSelect(stack) { onLongPress(stack.cardIds) }
                }
            }
        }
    }

    /// Ticked when every copy is, so the mark and the count agree.
    private func isSelected(_ stack: InventoryStack) -> Bool {
        stack.cardIds.allSatisfy(selection.contains)
    }
}

/// One owned cell: art, market price, set, then a compact identity line. It
/// draws one card, or one stack of copies with a count on the art.
struct OwnedCardCard: View {
    var stack: InventoryStack
    var isSelected = false
    var isSelecting = false

    /// The copy the cell draws. Every copy in a stack would draw the same one.
    private var row: InventoryRow { stack.lead }

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
                    identified: row.card.hasIdentity,
                    isBulk: row.card.isBulk
                )
            }
            // The name leads, then the set. The art names a card faster than
            // text does — until it does not: a slab covers its own art with a
            // label, and a cell whose image is still loading has nothing else
            // to say which card it is.
            Text(row.name)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let setName = row.setName {
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

    /// The number and the condition. The count sits on the art, so it is read
    /// the same on a stack of sealed packs as on a stack of singles. A slab
    /// shows the grader and the cert number instead, because that is how he
    /// reads a slab.
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
            } else if row.card.isSealedSelf {
                Image(systemName: "shippingbox")
                Text("Sealed")
            } else {
                if let number = row.number {
                    Text(number)
                        .monospacedDigit()
                }
                Text(CardCondition(rawValue: row.card.condition)?.short ?? row.card.condition)
                if let language = CardLanguage.badge(row.card.language) {
                    Text(language)
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
        .overlay(alignment: .topLeading) {
            if stack.copies > 1 {
                Text("×\(stack.copies)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(4)
            }
        }
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

extension View {
    /// A tap pushes the stack's card. A long press selects it, and only
    /// selects it.
    ///
    /// Not a `NavigationLink` with a simultaneous long press: the link took the
    /// lift that ends the long press as a tap, so it opened the card, and he
    /// had to come back to use the selection. Here the tap and the long press
    /// exclude each other.
    func pushOrSelect(_ stack: InventoryStack, onLongPress: @escaping () -> Void) -> some View {
        modifier(PushOrSelect(route: stack.route, onLongPress: onLongPress))
    }
}

private struct PushOrSelect: ViewModifier {
    var route: AppRoute
    var onLongPress: () -> Void

    @Environment(\.pushRoute) private var push

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { push(route) }
            .onLongPressGesture(minimumDuration: 0.4) { onLongPress() }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Select") { onLongPress() }
    }
}
