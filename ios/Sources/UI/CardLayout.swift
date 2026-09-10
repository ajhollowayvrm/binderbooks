import SwiftUI

/// The one stored key. `search.layout` was the old, search-only name.
let cardLayoutKey = "cardLayout"

/// How the app draws any list of cards. One global preference: it rules the
/// inventory page, the collection section, and the catalog section. The choice
/// persists, because AJ picks one and keeps it.
enum CardLayout: String, CaseIterable, Sendable {
    /// The dense row: thumbnail, name, set, number, price. An owned row also
    /// carries the basis and the gain, which a grid cell cannot hold.
    case list
    /// Three large arts per row, with the market price under each.
    case grid

    var next: CardLayout { self == .list ? .grid : .list }

    var systemImage: String {
        switch self {
        case .list: return "square.grid.3x3"
        case .grid: return "list.bullet"
        }
    }

    /// Names what the button switches to, not the current layout.
    var switchLabel: String {
        switch self {
        case .list: return "Show large art"
        case .grid: return "Show list"
        }
    }
}

/// The layout button. It sits beside the filter chips, outside their scroll
/// view, so it stays visible. The divider and the opaque background stop the
/// chips from sliding under it.
struct CardLayoutButton: View {
    @Binding var layout: CardLayout

    var body: some View {
        HStack(spacing: 8) {
            Divider()
                .frame(height: 22)
            Button {
                layout = layout.next
            } label: {
                Image(systemName: layout.systemImage)
                    .font(.body)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(layout.switchLabel)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .background(Color(.systemBackground))
    }
}

/// A section header for the grid layout. The grid cannot live in a `List`,
/// because a `NavigationLink` inside a list row draws a disclosure chevron on
/// every cell, so the grid layout builds its own headers.
struct CardSectionHeader: View {
    var title: String
    var trailing: AnyView?

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}
