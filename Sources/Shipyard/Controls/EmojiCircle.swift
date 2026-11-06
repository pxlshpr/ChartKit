import SwiftUI
import UIKit

/// Circular badge that lays out a small set of glyphs (emojis or SF Symbols)
/// around the centre of a filled circle. Used by the meal-timing bubble row
/// to summarise a meal's foods or a workout cluster's activities.
public struct EmojiCircle: View {

    public enum Item: Equatable, Hashable {
        /// `tint` desaturates the emoji and multiplies it with the given colour —
        /// used for the app's dominant-macro emoji tint (task #1921). `nil` renders
        /// the emoji in its full original colours.
        case emoji(String, tint: Color?)
        case symbol(String)
    }

    let items: [Item]
    let size: CGFloat
    var fillColor: Color
    /// When set, the circle is filled with this material instead of `fillColor`.
    var fillMaterial: Material?
    var symbolColor: Color

    public init(
        emojis: [String],
        /// Optional per-emoji tints, matched by index (missing/`nil` = untinted).
        tints: [Color?] = [],
        size: CGFloat,
        fillColor: Color = Color(UIColor.systemGray5),
        fillMaterial: Material? = nil,
        symbolColor: Color = Color(UIColor.label)
    ) {
        self.items = emojis.enumerated().map { index, emoji in
            .emoji(emoji, tint: index < tints.count ? tints[index] : nil)
        }
        self.size = size
        self.fillColor = fillColor
        self.fillMaterial = fillMaterial
        self.symbolColor = symbolColor
    }

    public init(
        symbols: [String],
        size: CGFloat,
        fillColor: Color = Color(UIColor.systemGray5),
        fillMaterial: Material? = nil,
        symbolColor: Color = Color(UIColor.label)
    ) {
        self.items = symbols.map { .symbol($0) }
        self.size = size
        self.fillColor = fillColor
        self.fillMaterial = fillMaterial
        self.symbolColor = symbolColor
    }

    public init(
        items: [Item],
        size: CGFloat,
        fillColor: Color = Color(UIColor.systemGray5),
        fillMaterial: Material? = nil,
        symbolColor: Color = Color(UIColor.label)
    ) {
        self.items = items
        self.size = size
        self.fillColor = fillColor
        self.fillMaterial = fillMaterial
        self.symbolColor = symbolColor
    }

    public var body: some View {
        let count = items.count

        ZStack {
            Group {
                if let fillMaterial {
                    Circle().fill(fillMaterial)
                } else {
                    Circle().fill(fillColor)
                }
            }
            .frame(width: size, height: size)

            if count <= 1 {
                renderItem(items.first ?? .emoji("", tint: nil), pointSize: size * 0.6)
            } else {
                let pointSize = itemSize(for: count, in: size)
                let radius = placementRadius(for: count, in: size)
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let angle = angleFor(index: index, total: count)
                    renderItem(item, pointSize: pointSize)
                        .offset(
                            x: cos(angle) * radius,
                            y: sin(angle) * radius
                        )
                }
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func renderItem(_ item: Item, pointSize: CGFloat) -> some View {
        switch item {
        case .emoji(let emoji, let tint):
            // Desaturate + multiply when a tint is supplied (dominant-macro emoji
            // tint, task #1921); `.white` multiply is a no-op for untinted emojis.
            Text(emoji)
                .font(.system(size: pointSize))
                .grayscale(tint == nil ? 0 : 1)
                .colorMultiply(tint ?? .white)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: pointSize, weight: .semibold))
                .foregroundStyle(symbolColor)
        }
    }

    private func angleFor(index: Int, total: Int) -> CGFloat {
        let startAngle: CGFloat = -.pi / 2
        return startAngle + CGFloat(index) * (2 * .pi / CGFloat(total))
    }

    private func itemSize(for count: Int, in size: CGFloat) -> CGFloat {
        switch count {
        case 2: return size * 0.38
        case 3: return size * 0.32
        case 4: return size * 0.30
        case 5: return size * 0.26
        default: return size * 0.24
        }
    }

    private func placementRadius(for count: Int, in size: CGFloat) -> CGFloat {
        switch count {
        case 2: return size * 0.17
        case 3: return size * 0.19
        case 4: return size * 0.20
        case 5: return size * 0.22
        default: return size * 0.24
        }
    }
}

#Preview("EmojiCircle - emojis") {
    VStack(spacing: 16) {
        EmojiCircle(emojis: ["🍔"], size: 44)
        EmojiCircle(emojis: ["🍔", "🍟"], size: 44)
        EmojiCircle(emojis: ["🍔", "🍟", "🥤"], size: 44)
        EmojiCircle(emojis: ["🥚", "🥯", "🥑", "☕️", "🍌"], size: 44)
    }
    .padding()
}

#Preview("EmojiCircle - symbols") {
    VStack(spacing: 16) {
        EmojiCircle(symbols: ["figure.run"], size: 44)
        EmojiCircle(symbols: ["figure.run", "dumbbell.fill"], size: 44)
        EmojiCircle(symbols: ["figure.run", "dumbbell.fill", "figure.pool.swim"], size: 44)
    }
    .padding()
}
