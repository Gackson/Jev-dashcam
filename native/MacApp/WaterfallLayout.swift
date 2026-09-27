import SwiftUI

/// Lazy columns instantiate only the viewport and SwiftUI's small prefetch area.
/// Unlike Layout.Subviews, they do not measure every screenshot in the library.
struct LazyWaterfall<Item: Identifiable, Card: View>: View {
    let items: [Item]
    let width: CGFloat
    var minimumColumnWidth: CGFloat = 250
    var spacing: CGFloat = 16
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        let count = max(1, min(4, Int((width + spacing) / (minimumColumnWidth + spacing))))
        let columnWidth = max(1, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<count, id: \.self) { column in
                LazyVStack(spacing: spacing) {
                    ForEach(stride(from: column, to: items.count, by: count).map { items[$0] }) { item in
                        card(item)
                    }
                }.frame(width: columnWidth)
            }
        }
    }
}
