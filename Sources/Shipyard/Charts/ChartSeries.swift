import Foundation

/// The data half of the custom chart core (#2682): the flat, ascending, display-unit
/// arrays a renderer wants, built once per change of the data and never rebuilt while the
/// user pans or pinches.
///
/// Structure-of-arrays, not array-of-structs, and `Double` seconds rather than `Date` —
/// `Date` comparison in a per-frame loop is measurable, and a frame here binary-searches
/// the visible window out of the whole history several times.

public enum ChartMetrics {
    public static let day: Double = 86_400
}

// MARK: - The contract

/// What a viewport needs to know about the data underneath it. Deliberately small: the
/// series answers where the data starts and ends, what its values span across a window,
/// and what datum sits under a domain value. Everything else — decimation, bucketing,
/// drawing — is the concrete series' and the renderer's business.
public protocol ChartSeries: Equatable {
    static var empty: Self { get }
    var isEmpty: Bool { get }

    /// The full plottable x range, including whatever lead-in the series wants at each end
    /// so an edge datum sits in from the plot border rather than on it.
    var domainStart: Double { get }
    var domainEnd: Double { get }

    /// The lowest and highest plotted value across `window`, or nil when it holds nothing.
    func valueExtent(in window: ClosedRange<Double>) -> (low: Double, high: Double)?

    /// The x of the datum under `value` — the nearest reading for a line, the centre of the
    /// containing bucket for a bar. The window comes along because a bucketed series
    /// resolves its level of detail from how much is on screen.
    ///
    /// The viewport stores this *x* rather than an index, which is what lets a bar chart's
    /// selection survive a change of bucket level: the callout re-resolves against whatever
    /// level is current instead of pointing at a stale row.
    func datumX(nearest value: Double, in window: ClosedRange<Double>) -> Double?

    /// The same two questions, asked with the plot's width in hand.
    ///
    /// A bucketed series needs it: what one bar covers depends on how much room there is to
    /// draw it, so the same ninety days is a dozen weekly columns on a phone held upright and
    /// ninety daily ones turned sideways. Everything else ignores it — hence the defaults
    /// below, which keep the four non-bucketed series from having to know the plot exists.
    func valueExtent(in window: ClosedRange<Double>, plotWidth: CGFloat) -> (low: Double, high: Double)?
    func datumX(nearest value: Double, in window: ClosedRange<Double>, plotWidth: CGFloat) -> Double?

    /// #2877 — this series with its values part-way between `previous`'s and its own,
    /// `progress` 0…1: what the viewport draws while a rebuild that kept the SHAPE and moved
    /// the VALUES glides from one to the other (`ChartViewport.load(_:morphing:)`) — a curve
    /// refined by a derivation that landed after the chart drew, an amount edited under a
    /// column. Nil when the two don't share a shape (a different count of columns, a run
    /// re-split) and the viewport swaps, as it always did. The default is nil: a series that
    /// never morphs needs to know nothing about it.
    func morphed(from previous: Self, progress: Double) -> Self?

    /// #3729 — the span at the end of the domain past the history (the Weight screen's projection
    /// runs, from today to their horizon) that every preset's window carries on top of its days,
    /// so 1M is a month of history and where it heads rather than a month of runs. Zero (the
    /// default): a preset counts back from the domain's end.
    var presetTail: Double { get }
}

extension ChartSeries {
    /// The whole plottable span, never shorter than `floor`.
    ///
    /// The floor is not cosmetic: a series holding a single reading spans nothing at all, and
    /// a zero-width domain would make every window bound — `minSpan`, `maxSpan`, what "All"
    /// resolves to — degenerate. A day is the right floor for anything measured in days; a
    /// chart whose whole subject is shorter than that says so through
    /// `ChartViewportConfiguration.minimumFullSpan` (#2697).
    public func fullSpan(floor: Double) -> Double { max(domainEnd - domainStart, floor) }

    public var fullSpan: Double { fullSpan(floor: ChartMetrics.day) }

    public var presetTail: Double { 0 }

    public func valueExtent(in window: ClosedRange<Double>, plotWidth: CGFloat) -> (low: Double, high: Double)? {
        valueExtent(in: window)
    }

    public func datumX(nearest value: Double, in window: ClosedRange<Double>, plotWidth: CGFloat) -> Double? {
        datumX(nearest: value, in: window)
    }

    public func morphed(from previous: Self, progress: Double) -> Self? { nil }
}

// MARK: - Binary search

extension Array where Element == Double {
    /// The first index whose element is >= `value`. O(log n) — this is what keeps a frame's
    /// work proportional to what's visible instead of to the whole history.
    public func chartLowerBound(_ value: Double) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

// MARK: - Line series

/// A sampled series: one value (and optionally one smoothed trend value) per x.
public struct ChartLineSeries: ChartSeries, Sendable {
    /// Ascending x positions, seconds since the reference date.
    public let xs: [Double]
    /// The plotted values, already in the display unit — converted once, here.
    public let values: [Double]
    /// A precomputed derived series drawn over the raw one, or empty when the chart has no
    /// trend to draw. Same length as `values` when present.
    public let trend: [Double]
    /// Half a bucket's lead on either side of the data.
    public let lead: Double

    public static let empty = ChartLineSeries(xs: [], values: [], trend: [], lead: ChartMetrics.day / 2)

    public init(xs: [Double], values: [Double], trend: [Double] = [], lead: Double = ChartMetrics.day / 2) {
        self.xs = xs
        self.values = values
        self.trend = trend.count == values.count ? trend : []
        self.lead = lead
    }

    public var count: Int { xs.count }
    public var isEmpty: Bool { xs.isEmpty }
    public var hasTrend: Bool { !trend.isEmpty }

    public var firstX: Double { xs.first ?? Date.now.timeIntervalSinceReferenceDate }
    public var lastX: Double { xs.last ?? Date.now.timeIntervalSinceReferenceDate }

    public var domainStart: Double { firstX - lead }
    public var domainEnd: Double { lastX + lead }

    public func lowerBound(_ x: Double) -> Int { xs.chartLowerBound(x) }

    /// The indices covering `range`, widened by one reading on each side so the lines run
    /// off the edges of the plot instead of stopping at them. The widening isn't cosmetic:
    /// without it the line visibly detaches from the plot edge as you pan, which reads as
    /// stuttering even when the frame rate is fine.
    public func indices(coveringX range: ClosedRange<Double>) -> Range<Int> {
        guard !xs.isEmpty else { return 0..<0 }
        let lower = Swift.max(0, lowerBound(range.lowerBound) - 1)
        let upper = Swift.min(xs.count, lowerBound(range.upperBound) + 1)
        return lower..<Swift.max(lower, upper)
    }

    public func nearestIndex(to x: Double) -> Int? {
        guard !xs.isEmpty else { return nil }
        let candidate = lowerBound(x)
        if candidate == 0 { return 0 }
        if candidate >= xs.count { return xs.count - 1 }
        let before = candidate - 1
        return (x - xs[before]) <= (xs[candidate] - x) ? before : candidate
    }

    public func valueExtent(in window: ClosedRange<Double>) -> (low: Double, high: Double)? {
        extent(over: indices(coveringX: window)) ?? extent(over: 0..<count)
    }

    public func extent(over range: Range<Int>) -> (low: Double, high: Double)? {
        guard !range.isEmpty else { return nil }
        var low = Double.infinity
        var high = -Double.infinity
        let hasTrend = self.hasTrend
        for index in range {
            let value = values[index]
            low = Swift.min(low, value)
            high = Swift.max(high, value)
            if hasTrend {
                let smoothed = trend[index]
                low = Swift.min(low, smoothed)
                high = Swift.max(high, smoothed)
            }
        }
        return low <= high ? (low, high) : nil
    }

    public func datumX(nearest value: Double, in window: ClosedRange<Double>) -> Double? {
        nearestIndex(to: value).map { xs[$0] }
    }
}

// MARK: - Bar series

/// How a period's bar is aggregated out of the days inside it. Getting this wrong is a
/// correctness bug rather than a rendering one — a week of *calories* is a sum, a week of
/// *weight* is a mean — so the intent is carried in the series and can't be chosen at a
/// call site by accident.
public enum ChartAggregate: Sendable {
    case sum, mean
}

/// The calendar periods a bar chart aggregates into. Bars are aggregates over intervals,
/// not samples at points, so they bucket by real calendar boundaries rather than by pixel
/// column the way the line decimator does.
public enum ChartBucket: Int, CaseIterable, Comparable {
    case day, week, month, quarter, year

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .quarter: .month
        case .year: .year
        }
    }

    public var step: Int { self == .quarter ? 3 : 1 }

    /// Roughly how long a bucket lasts, for picking a level without touching the calendar.
    public var approximateLength: Double {
        switch self {
        case .day: ChartMetrics.day
        case .week: 7 * ChartMetrics.day
        case .month: 30.44 * ChartMetrics.day
        case .quarter: 91.3 * ChartMetrics.day
        case .year: 365.25 * ChartMetrics.day
        }
    }
}

/// A bar chart's data: every level of detail precomputed once at load, so a frame is an
/// O(1) level lookup plus a binary search rather than a re-bucket.
///
/// Five levels is 5 × O(n) at build time and O(2n) memory — cheap next to re-aggregating
/// per frame, which is what a `Chart` over a `ForEach` of raw days ends up doing.
public struct ChartBarSeries: ChartSeries, Sendable {
    /// One precomputed level of detail.
    public struct Level: Equatable, Sendable {
        /// Bucket boundaries and centres, ascending.
        public let starts: [Double]
        public let ends: [Double]
        public let mids: [Double]
        /// The aggregate the bar draws.
        public let values: [Double]
        /// How many raw samples landed in the bucket — a partial period has to be drawn
        /// honestly, and a mean needs it.
        public let counts: [Int]
        /// Optional stack segments, one array per segment, each parallel to `values`.
        /// Empty when the bars aren't stacked.
        public let segments: [[Double]]

        public static let empty = Level(starts: [], ends: [], mids: [], values: [], counts: [], segments: [])

        public var count: Int { starts.count }

        /// The buckets overlapping `range`, widened by one each side so a bar half off the
        /// edge is still drawn (and clipped) rather than popping in.
        public func indices(covering range: ClosedRange<Double>) -> Range<Int> {
            guard !starts.isEmpty else { return 0..<0 }
            let lower = Swift.max(0, starts.chartLowerBound(range.lowerBound) - 1)
            let upper = Swift.min(starts.count, starts.chartLowerBound(range.upperBound) + 1)
            return lower..<Swift.max(lower, upper)
        }

        /// The bucket whose interval contains `value`. Containment, not nearest-neighbour:
        /// a bar owns an interval, and snapping the readout to the bucket is most of what
        /// makes bar scrubbing feel solid rather than mushy.
        ///
        /// The boundary case matters — a caller asking about a day's own start lands exactly
        /// on `starts[i]`, and that day is bucket `i`, not `i - 1`.
        public func index(containing value: Double) -> Int? {
            guard !starts.isEmpty else { return nil }
            var candidate = starts.chartLowerBound(value)
            if candidate == starts.count || starts[candidate] > value { candidate -= 1 }
            guard starts.indices.contains(candidate) else { return nil }
            return value < ends[candidate] ? candidate : nil
        }

        /// The bucket containing `value`, or the nearest one when it falls in a gap —
        /// which is what a scrub past the ends of the data wants.
        public func nearestIndex(to value: Double) -> Int? {
            guard !starts.isEmpty else { return nil }
            if let contained = index(containing: value) { return contained }
            let candidate = starts.chartLowerBound(value)
            if candidate == 0 { return 0 }
            if candidate >= starts.count { return starts.count - 1 }
            let before = candidate - 1
            return (value - mids[before]) <= (mids[candidate] - value) ? before : candidate
        }
    }

    /// Indexed by `ChartBucket.rawValue`, so a level lookup is an array subscript.
    public let levels: [Level]
    public let aggregate: ChartAggregate
    /// How many segments each bucket's `segments` carries — 0 for a plain bar.
    public let segmentCount: Int

    /// The domain covers WHOLE buckets at every level the chart can actually reach — not just
    /// the span of the logged days.
    ///
    /// A bar is drawn across its calendar period, and the periods at each end of a history are
    /// partial: the newest week runs past today, the oldest starts before the first day on
    /// record. A domain that stopped at the last logged day therefore clipped half of the
    /// first and last bars behind the value gutter and the trailing edge at full zoom-out —
    /// they were only visible by rubber-banding past the end.
    ///
    /// Levels coarser than the chart could ever select are excluded, or a fortnight of data
    /// would open its domain out to the whole calendar year its one year-bucket spans.
    public let domainStart: Double
    public let domainEnd: Double

    public static let empty = ChartBarSeries(
        levels: Array(repeating: .empty, count: ChartBucket.allCases.count),
        aggregate: .sum,
        segmentCount: 0,
        domainStart: 0,
        domainEnd: ChartMetrics.day
    )

    public var isEmpty: Bool { levels[ChartBucket.day.rawValue].starts.isEmpty }

    public func level(_ bucket: ChartBucket) -> Level { levels[bucket.rawValue] }

    /// Each column needs at least this much room, in points, before the level is worth
    /// drawing; the finest level that clears it is the one used.
    ///
    /// This one number is what makes a phone held upright group a long history into weeks and
    /// the same phone turned sideways resolve it into one bar per day: three months across a
    /// ~290pt card gives a day only 3.3pt, so it groups, while the same three months across a
    /// ~910pt landscape plot gives a day 10pt and every one of them gets its own column.
    /// Nothing chooses between them — the width does.
    public static let minimumBucketPitch: Double = 5

    /// What a plot assumes when nobody has told it how wide it is yet — a phone's, upright.
    public static let assumedPlotWidth: CGFloat = 330

    /// The level that puts bars on screen you can actually see.
    ///
    /// Chosen from the plot's WIDTH as well as the span, which is the part the first cut got
    /// wrong: a fixed "no more than 60 buckets" rule reads the same for a 330pt card and an
    /// 1800pt landscape plot, so turning the phone sideways kept the weekly columns and drew
    /// them a hundred points wide. Ask instead how much room each column would get, and the
    /// sideways chart resolves into ninety daily bars on its own.
    public func bucket(forSpan span: Double, plotWidth: CGFloat = ChartBarSeries.assumedPlotWidth) -> ChartBucket {
        let width = max(Double(plotWidth), 1)
        for candidate in ChartBucket.allCases {
            guard !level(candidate).starts.isEmpty else { continue }
            let count = span / candidate.approximateLength
            if count <= 1 || width / count >= Self.minimumBucketPitch { return candidate }
        }
        return .year
    }

    public func valueExtent(in window: ClosedRange<Double>) -> (low: Double, high: Double)? {
        valueExtent(in: window, plotWidth: Self.assumedPlotWidth)
    }

    public func datumX(nearest value: Double, in window: ClosedRange<Double>) -> Double? {
        datumX(nearest: value, in: window, plotWidth: Self.assumedPlotWidth)
    }

    public func valueExtent(in window: ClosedRange<Double>, plotWidth: CGFloat) -> (low: Double, high: Double)? {
        let level = level(bucket(forSpan: window.upperBound - window.lowerBound, plotWidth: plotWidth))
        let range = level.indices(covering: window)
        guard !range.isEmpty else {
            guard let low = level.values.min(), let high = level.values.max() else { return nil }
            return (low, high)
        }
        var low = Double.infinity
        var high = -Double.infinity
        for index in range {
            low = Swift.min(low, level.values[index])
            high = Swift.max(high, level.values[index])
        }
        return low <= high ? (low, high) : nil
    }

    public func datumX(nearest value: Double, in window: ClosedRange<Double>, plotWidth: CGFloat) -> Double? {
        let level = level(bucket(forSpan: window.upperBound - window.lowerBound, plotWidth: plotWidth))
        return level.nearestIndex(to: value).map { level.mids[$0] }
    }
}

// MARK: - Building bar levels

extension ChartBarSeries {
    /// One raw daily sample going into the aggregation.
    public struct Sample {
        public let x: Double
        public let value: Double
        /// Stack segments for this sample, or empty for a plain bar.
        public var segments: [Double] = []

        public init(
            x: Double,
            value: Double,
            segments: [Double] = []
        ) {
            self.x = x
            self.value = value
            self.segments = segments
        }
    }

    /// Aggregates `samples` (ascending x) into all five calendar levels at once.
    ///
    /// The bucketing walks the calendar rather than dividing by a nominal length, so a
    /// month bar covers a real month and a week bar starts on the locale's own first
    /// weekday — which is what keeps bars aligned with the axis labels drawn over them.
    public static func build(
        samples: [Sample],
        aggregate: ChartAggregate,
        segmentCount: Int = 0,
        calendar: Calendar = .autoupdatingCurrent
    ) -> ChartBarSeries {
        guard !samples.isEmpty else { return .empty }
        // Ascending is a hard requirement, not a convention: the bucketing below closes a
        // period the moment it sees a sample outside it, and every lookup afterwards is a
        // binary search. Sorting here is O(n log n) once per data change; getting it wrong is
        // a silently wrong chart.
        let samples = samples.sorted { $0.x < $1.x }
        var levels = [Level]()
        levels.reserveCapacity(ChartBucket.allCases.count)
        for bucket in ChartBucket.allCases {
            levels.append(
                buildLevel(
                    samples: samples,
                    bucket: bucket,
                    aggregate: aggregate,
                    segmentCount: segmentCount,
                    calendar: calendar
                )
            )
        }
        let (start, end) = domain(over: levels)
        return ChartBarSeries(
            levels: levels,
            aggregate: aggregate,
            segmentCount: segmentCount,
            domainStart: start,
            domainEnd: end
        )
    }

    /// The widest extent of any level the chart can reach — see `domainStart`.
    ///
    /// Which level that is depends on the span, and the span depends on the extent, so this
    /// settles it: widen, re-pick, repeat. Two passes is always enough in practice (a level
    /// only changes if the widening pushes the bar count past `bucket(forSpan:)`'s threshold,
    /// and a level's own widening can't push it past the next one's), and the loop is capped
    /// rather than trusting that.
    /// The narrowest plot a chart on this core is drawn into — a card in a list row. The
    /// domain is sized for it, since that is the width that picks the coarsest level.
    private static let narrowestPlotWidth: CGFloat = 300

    private static func domain(over levels: [Level]) -> (start: Double, end: Double) {
        let day = levels[ChartBucket.day.rawValue]
        guard let firstDay = day.starts.first, let lastDay = day.ends.last else {
            let now = Date.now.timeIntervalSinceReferenceDate
            return (now, now + ChartMetrics.day)
        }
        var start = firstDay
        var end = lastDay
        for _ in 0..<3 {
            let span = end - start
            // The coarsest level `bucket(forSpan:)` would pick with the whole history on
            // screen. Mirrors that method's rule exactly, so the two can't disagree.
            // The coarsest level any plot could pick with the whole history on screen — a
            // NARROW plot picks the coarsest, so that is what the domain has to cover.
            var coarsest = ChartBucket.day
            for candidate in ChartBucket.allCases where !levels[candidate.rawValue].starts.isEmpty {
                coarsest = candidate
                let count = span / candidate.approximateLength
                if count <= 1 || Double(narrowestPlotWidth) / count >= minimumBucketPitch { break }
            }
            var widenedStart = firstDay
            var widenedEnd = lastDay
            for candidate in ChartBucket.allCases where candidate <= coarsest {
                let level = levels[candidate.rawValue]
                if let value = level.starts.first { widenedStart = Swift.min(widenedStart, value) }
                if let value = level.ends.last { widenedEnd = Swift.max(widenedEnd, value) }
            }
            if widenedStart == start, widenedEnd == end { break }
            start = widenedStart
            end = widenedEnd
        }
        return (start, end)
    }

    private static func buildLevel(
        samples: [Sample],
        bucket: ChartBucket,
        aggregate: ChartAggregate,
        segmentCount: Int,
        calendar: Calendar
    ) -> Level {
        var starts = [Double]()
        var ends = [Double]()
        var values = [Double]()
        var counts = [Int]()
        var segments = [[Double]](repeating: [], count: segmentCount)

        var currentStart: Date?
        var currentEnd: Date?
        var total = 0.0
        var count = 0
        var segmentTotals = [Double](repeating: 0, count: segmentCount)

        func flush() {
            guard let start = currentStart, let end = currentEnd, count > 0 else { return }
            starts.append(start.timeIntervalSinceReferenceDate)
            ends.append(end.timeIntervalSinceReferenceDate)
            values.append(aggregate == .sum ? total : total / Double(count))
            counts.append(count)
            for index in 0..<segmentCount {
                let raw = segmentTotals[index]
                segments[index].append(aggregate == .sum ? raw : raw / Double(count))
            }
        }

        for sample in samples {
            let date = Date(timeIntervalSinceReferenceDate: sample.x)
            let interval = Self.interval(containing: date, bucket: bucket, calendar: calendar)
            if currentStart != interval.start {
                flush()
                currentStart = interval.start
                currentEnd = interval.end
                total = 0
                count = 0
                if segmentCount > 0 { segmentTotals = [Double](repeating: 0, count: segmentCount) }
            }
            total += sample.value
            count += 1
            for index in 0..<Swift.min(segmentCount, sample.segments.count) {
                segmentTotals[index] += sample.segments[index]
            }
        }
        flush()

        let mids = zip(starts, ends).map { ($0 + $1) / 2 }
        return Level(starts: starts, ends: ends, mids: mids, values: values, counts: counts, segments: segments)
    }

    /// The calendar interval of `bucket` containing `date`. Quarters aren't a calendar
    /// component, so they're derived from the month.
    private static func interval(
        containing date: Date,
        bucket: ChartBucket,
        calendar: Calendar
    ) -> (start: Date, end: Date) {
        switch bucket {
        case .quarter:
            var components = calendar.dateComponents([.year, .month], from: date)
            if let month = components.month { components.month = month - ((month - 1) % 3) }
            components.day = 1
            let start = calendar.date(from: components) ?? calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .month, value: 3, to: start) ?? start
            return (start, end)
        default:
            if let interval = calendar.dateInterval(of: bucket.component, for: date) {
                return (interval.start, interval.end)
            }
            let start = calendar.startOfDay(for: date)
            return (start, start.addingTimeInterval(ChartMetrics.day))
        }
    }
}

// MARK: - Readouts

extension ChartBarSeries {
    /// The daily average across `window`, plus the first and last day it covers — a bar
    /// chart's resting header.
    ///
    /// Always read off the DAY level whatever level the chart is currently drawing, so
    /// "daily average" keeps meaning the same thing at every zoom.
    public func dailyAverage(in window: ClosedRange<Double>) -> (value: Double, first: Double, last: Double)? {
        let day = level(.day)
        guard !day.starts.isEmpty else { return nil }
        let lower = day.starts.chartLowerBound(window.lowerBound)
        let upper = day.starts.chartLowerBound(window.upperBound)
        guard upper > lower else { return nil }
        var total = 0.0
        for index in lower..<upper { total += day.values[index] }
        return (total / Double(upper - lower), day.starts[lower], day.starts[upper - 1])
    }

    /// The whole series' value range, for measuring the axis gutter off something that
    /// doesn't move while the axis eases.
    public var valueBounds: (low: Double, high: Double)? {
        let day = level(.day)
        guard let low = day.values.min(), let high = day.values.max() else { return nil }
        return (low, high)
    }

    /// #3217 — the same buckets with their values part-way between `previous`'s and these:
    /// the carb sheet's History card re-reads its thirty days when Total/Net is flipped, and
    /// the bars glide to the other figures instead of jumping. Only when every level buckets
    /// the same periods — a day that drops out (net carbs of zero) changes the shape, and the
    /// viewport swaps as it always did.
    public func morphed(from previous: ChartBarSeries, progress: Double) -> ChartBarSeries? {
        guard previous.levels.count == levels.count,
              previous.segmentCount == segmentCount,
              previous.aggregate == aggregate,
              zip(previous.levels, levels).allSatisfy({
                  $0.starts == $1.starts && $0.ends == $1.ends && $0.counts == $1.counts
                      && $0.segments.count == $1.segments.count
              })
        else { return nil }
        let t = Swift.min(Swift.max(progress, 0), 1)
        func blend(_ from: [Double], _ to: [Double]) -> [Double] {
            guard from.count == to.count else { return to }
            return zip(from, to).map { $0 + ($1 - $0) * t }
        }
        return ChartBarSeries(
            levels: zip(previous.levels, levels).map { from, to in
                Level(
                    starts: to.starts,
                    ends: to.ends,
                    mids: to.mids,
                    values: blend(from.values, to.values),
                    counts: to.counts,
                    segments: zip(from.segments, to.segments).map { blend($0, $1) }
                )
            },
            aggregate: aggregate,
            segmentCount: segmentCount,
            domainStart: domainStart,
            domainEnd: domainEnd
        )
    }
}
