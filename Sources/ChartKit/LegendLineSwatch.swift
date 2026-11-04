import SwiftUI

/// A short horizontal stroke for chart legends — dashed or dotted to match the mark it
/// explains. Moved here from NutriKit's WeightOutlookSeries.swift (#3919), which stays in
/// NutriKit: the swatch is generic, the weight projections it was filed beside are not.
public struct LegendLineSwatch: Shape {
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }

    public init() {}
}
