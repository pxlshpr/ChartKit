import SwiftUI

/// The drawing primitives a custom chart renders with (#2682, extracted from #2673's weight
/// chart): the decimator that bounds a frame's work by the width of the plot, the monotone
/// cubic path builder, and the bar geometry.

// MARK: - Decimation

/// One drawn column: the raw readings that fall inside a single point of plot width,
/// collapsed to the band they span plus whatever trend runs through them.
public struct ChartColumn {
    public var x: Double
    public var low: Double
    public var high: Double
    public var trend: Double
}

public enum ChartDecimator {
    /// Collapses `range` into at most `buckets` columns. Below twice the bucket count the
    /// readings are passed through untouched — zoomed in, the chart draws exactly what was
    /// recorded; zoomed out, it draws the envelope, and either way the path it builds is
    /// bounded by the width of the plot rather than the length of the history.
    ///
    /// Buckets by *x*, not by index: index bucketing distorts wherever the data has gaps.
    public static func columns(
        from series: ChartLineSeries,
        range: Range<Int>,
        domain: ClosedRange<Double>,
        buckets: Int
    ) -> [ChartColumn] {
        guard !range.isEmpty else { return [] }
        let bucketCount = max(buckets, 1)
        let hasTrend = series.hasTrend

        if range.count <= bucketCount * 2 {
            return range.map { index in
                ChartColumn(
                    x: series.xs[index],
                    low: series.values[index],
                    high: series.values[index],
                    trend: hasTrend ? series.trend[index] : series.values[index]
                )
            }
        }

        let span = max(domain.upperBound - domain.lowerBound, .ulpOfOne)
        // Parallel arrays rather than `[ChartColumn?]` — no allocation per bucket, and the
        // whole thing stays in one contiguous run.
        var sumX = [Double](repeating: 0, count: bucketCount)
        var sumTrend = [Double](repeating: 0, count: bucketCount)
        var low = [Double](repeating: .infinity, count: bucketCount)
        var high = [Double](repeating: -.infinity, count: bucketCount)
        var counts = [Int](repeating: 0, count: bucketCount)

        for index in range {
            let x = series.xs[index]
            let position = (x - domain.lowerBound) / span * Double(bucketCount)
            let bucket = min(max(Int(position), 0), bucketCount - 1)
            let value = series.values[index]
            sumX[bucket] += x
            sumTrend[bucket] += hasTrend ? series.trend[index] : value
            low[bucket] = Swift.min(low[bucket], value)
            high[bucket] = Swift.max(high[bucket], value)
            counts[bucket] += 1
        }

        var result = [ChartColumn]()
        result.reserveCapacity(bucketCount)
        for bucket in 0..<bucketCount where counts[bucket] > 0 {
            let n = Double(counts[bucket])
            result.append(
                ChartColumn(
                    x: sumX[bucket] / n,
                    low: low[bucket],
                    high: high[bucket],
                    trend: sumTrend[bucket] / n
                )
            )
        }
        return result
    }
}

// MARK: - Paths

public enum ChartPath {
    /// A monotone cubic through `points` (ascending x) — the same shape Swift Charts'
    /// `.monotone` interpolation drew, without its per-mark layout cost. Fritsch–Carlson
    /// tangents, so the curve never overshoots a reading, which matters wherever the plotted
    /// quantity is something a user recognises the exact value of.
    public static func monotone(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }

        let count = points.count
        var slopes = [CGFloat](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            let dx = points[index + 1].x - points[index].x
            slopes[index] = dx > 0 ? (points[index + 1].y - points[index].y) / dx : 0
        }

        // Tangents: zero at a local extremum, the mean of the neighbouring slopes otherwise.
        var tangents = [CGFloat](repeating: 0, count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]
        for index in 1..<(count - 1) {
            tangents[index] = slopes[index - 1] * slopes[index] <= 0
                ? 0
                : (slopes[index - 1] + slopes[index]) / 2
        }

        // Fritsch–Carlson clamp: keep (a, b) inside the circle of radius 3.
        for index in 0..<(count - 1) {
            let slope = slopes[index]
            if slope == 0 {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }
            let a = tangents[index] / slope
            let b = tangents[index + 1] / slope
            let magnitude = a * a + b * b
            if magnitude > 9 {
                let scale = 3 / sqrt(magnitude)
                tangents[index] = scale * a * slope
                tangents[index + 1] = scale * b * slope
            }
        }

        for index in 0..<(count - 1) {
            let from = points[index]
            let to = points[index + 1]
            let third = (to.x - from.x) / 3
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x + third, y: from.y + tangents[index] * third),
                control2: CGPoint(x: to.x - third, y: to.y - tangents[index + 1] * third)
            )
        }
        return path
    }

    /// A plain polyline. Cheaper than the monotone cubic and honest at high density, where
    /// the curve's extra control points buy nothing the eye can see.
    public static func polyline(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

// MARK: - Bar geometry

/// How wide a bar is at a given level of detail, and whether bars are worth drawing at all.
///
/// Below about 2pt of bar the chart stops being a bar chart: 400 sub-pixel slivers are a
/// noisy area chart with worse performance, so the renderer falls back to the line case's
/// envelope there instead.
public struct ChartBarGeometry {
    public let bucketWidth: CGFloat
    public let barWidth: CGFloat
    public let corner: CGFloat
    /// False once the bars are too thin to read as bars. A "bar chart" of sub-pixel slivers is
    /// a noisy area chart with worse performance, so below this the renderer draws the range
    /// the buckets span instead.
    public var drawsBars: Bool { barWidth >= 2 }

    /// One bucket's own width. Calendar periods aren't uniform — February is a tenth
    /// narrower than March — and a bar that ignores that drifts off the interval it is
    /// supposed to cover.
    public func width(ofBucket index: Int, in level: ChartBarSeries.Level, transform: ChartTransform) -> CGFloat {
        guard level.starts.indices.contains(index) else { return barWidth }
        let length = level.ends[index] - level.starts[index]
        return min(max(CGFloat(length) * transform.pointsPerSecond * 0.62, 0.5), Self.maximumWidth)
    }

    /// However few bars are on screen, a column past this reads as a slab rather than a bar —
    /// a week's window on a landscape plot would otherwise draw them 160pt across.
    public static let maximumWidth: CGFloat = 40

    public init(bucketLength: Double, transform: ChartTransform) {
        bucketWidth = max(CGFloat(bucketLength) * transform.pointsPerSecond, 0.5)
        // ~38% gap is what reads as a bar chart rather than a filled area.
        barWidth = min(max(bucketWidth * 0.62, 0.5), Self.maximumWidth)
        corner = min(barWidth * 0.35, 4)
    }
}

// MARK: - Bars

public enum ChartBars {
    /// Adds one bar to `path`. Bars of a single colour accumulate into ONE path and are
    /// filled once — a fill per bar is the bar-chart version of the per-mark gradient
    /// mistake, and at forty bars a frame it is the whole budget.
    public static func add(
        to path: inout Path,
        centreX: CGFloat,
        top: CGFloat,
        bottom: CGFloat,
        width: CGFloat,
        corner: CGFloat
    ) {
        let height = bottom - top
        guard height > 0.01 else { return }
        let rect = CGRect(x: centreX - width / 2, y: top, width: width, height: height)
        if corner > 0.01, height > corner {
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: corner, height: corner))
        } else {
            path.addRect(rect)
        }
    }

    /// Adds the CAP of a stacked bar to `path` (#2899) — rounded shoulders, square feet.
    ///
    /// `add` rounds all four corners, which is right for a bar that runs to the axis (its feet
    /// sit on the baseline, where they don't read) and wrong for the top segment of a stack
    /// that is CUT from the segment below: rounded feet in the middle of a column read as a
    /// pill floating over the rest of the bar.
    ///
    /// The radius is clamped to what the segment can carry rather than dropped when it can't
    /// — a thin cap stays a cap, instead of being the one square-topped bar in a row of
    /// rounded ones.
    public static func addCap(
        to path: inout Path,
        centreX: CGFloat,
        top: CGFloat,
        bottom: CGFloat,
        width: CGFloat,
        corner: CGFloat
    ) {
        let height = bottom - top
        guard height > 0.01, width > 0.01 else { return }
        let rect = CGRect(x: centreX - width / 2, y: top, width: width, height: height)
        let radius = max(0, min(corner, width / 2, height))
        guard radius > 0.01 else {
            path.addRect(rect)
            return
        }
        path.addPath(UnevenRoundedRectangle(
            topLeadingRadius: radius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: radius
        ).path(in: rect))
    }

    /// The min/max envelope the bar renderer falls back to once the bars are thinner than
    /// they are apart. A "bar chart" of four hundred sub-pixel slivers is a noisy area chart
    /// with worse performance, so below ~2pt of bar width it draws the range instead.
    public static func envelope(
        xs: [CGFloat],
        tops: [CGFloat],
        baseline: CGFloat
    ) -> Path {
        var path = Path()
        guard let firstX = xs.first else { return path }
        path.move(to: CGPoint(x: firstX, y: baseline))
        for index in xs.indices {
            path.addLine(to: CGPoint(x: xs[index], y: tops[index]))
        }
        if let lastX = xs.last {
            path.addLine(to: CGPoint(x: lastX, y: baseline))
        }
        path.closeSubpath()
        return path
    }
}
