import SwiftUI
import UIKit

/// The axes of a custom chart (#2682, extracted from #2673's weight chart): which values and
/// dates get a tick, how wide the value gutter needs to be, and the labels themselves.
///
/// Labels are drawn as SwiftUI views rather than into the `Canvas`. `context.draw(Text(…))`
/// re-resolves and re-lays-out the text on every frame — ten labels at 120Hz is 1,200 text
/// layouts a second — where an overlay of positioned `Text`s reuses the laid-out strings and
/// only moves them.
public enum ChartAxis {

    // MARK: - Value ticks

    public static func valueTicks(_ frame: ChartFrame, limit: Int = 8) -> [Double] {
        guard frame.yStep > 0, frame.yHigh > frame.yLow else { return [] }
        var ticks: [Double] = []
        var value = (frame.yLow / frame.yStep).rounded(.up) * frame.yStep
        while value <= frame.yHigh + frame.yStep * 0.001, ticks.count < limit {
            ticks.append((value / frame.yStep).rounded() * frame.yStep)
            value += frame.yStep
        }
        return ticks
    }

    // MARK: - The value gutter

    /// The width the value axis actually needs, measured with `UIFont` so it holds under
    /// Dynamic Type. A fixed gutter is always wrong in one direction: too wide and there is
    /// dead space at the leading edge before the numbers start, too narrow and a long label
    /// collides with the plot.
    ///
    /// Measure this off the *series* bounds, never the live eased domain. Deriving it from
    /// `yLow`/`yHigh` looks more correct and is worse — those ease continuously, so the
    /// gutter would change while the axis settles and the whole plot would slide sideways
    /// after every pan.
    public static func valueGutter(
        low: Double?,
        high: Double?,
        pinsZero: Bool = false,
        format: (Double) -> String
    ) -> CGFloat {
        guard let low, let high else { return 26 }
        // The axis pads out beyond the data and rounds to whole ticks, so measure a little
        // past both ends — and against a ".5" tick, which is the widest form a label takes.
        let margin = max((high - low) * 0.3, 1)
        var candidates = [format(high + margin), format((high + margin).rounded(.down) + 0.5)]
        candidates.append(format(pinsZero ? min(0, low) : low - margin))
        let widest = candidates.map(labelWidth).max() ?? 22
        return min(max(widest + 5, 20), 60)
    }

    public static func labelWidth(_ text: String) -> CGFloat {
        let size = UIFont.preferredFont(forTextStyle: .caption2).pointSize
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: - Date ticks

    public struct DateTick: Hashable {
        public let date: Date
        public let label: String
    }

    public enum TickStride: Hashable, Sendable {
        case minutes(Int), hours(Int), days(Int), months(Int), years(Int)

        /// Roughly how many days one step covers. Only ever used to compare strides against
        /// each other and against the plot's width, so a nominal month and a nominal year are
        /// close enough — nothing is positioned off this.
        public var approximateDays: Double {
            switch self {
            case .minutes(let step): Double(step) / 1_440
            case .hours(let step):   Double(step) / 24
            case .days(let step):    Double(step)
            case .months(let step):  Double(step) * 30.44
            case .years(let step):   Double(step) * 365.25
            }
        }
    }

    public static let calendar = Calendar.autoupdatingCurrent

    /// Every stride the axis can land on, coarsest last. `tickStride` picks a starting rung off
    /// the visible span and then walks *up* this ladder until the labels stop colliding, so the
    /// escalation only ever swaps one aligned grid for a coarser aligned grid — the ticks stay
    /// on round clock/calendar boundaries either way.
    private static let strideLadder: [TickStride] = [
        .minutes(5), .minutes(10), .minutes(15), .minutes(30),
        .hours(1), .hours(2), .hours(3), .hours(6), .hours(12),
        .days(1), .days(2), .days(4), .days(7), .days(14),
        .months(1), .months(2), .months(3), .months(6),
        .years(1), .years(2), .years(5), .years(10),
    ]

    /// Clear space demanded between two adjacent labels (#2749). Measured against the WIDEST
    /// form each format takes, so a typical pair ends up further apart than this — which is why
    /// it can be as small as it is without the axis reading as one run-on string. Scales with
    /// Dynamic Type, since the labels do.
    private static var minimumLabelGap: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: .caption2).pointSize * 0.36)
    }

    /// The stride to mark, given the visible span and — when the caller knows it — how wide the
    /// plot is (#2749).
    ///
    /// The span alone can only ever aim for a tick *count*; whether that count fits is a
    /// question about the labels and the width. An hour-and-a-quarter workout picked the
    /// 10-minute rung and printed eight 43pt `7:20 PM` labels at a 42pt pitch — every label
    /// touching its neighbours. So the span picks the starting rung and the width has the last
    /// word: step up until a label plus `minimumLabelGap` fits in the pitch between ticks.
    public static func tickStride(forVisibleDays days: Double, plotWidth: CGFloat = 0) -> TickStride {
        let base = baseTickStride(forVisibleDays: days)
        guard plotWidth > 0, days > 0,
              var cursor = strideLadder.firstIndex(of: base) else { return base }

        while true {
            let candidate = strideLadder[cursor]
            let pitch = plotWidth * candidate.approximateDays / days
            let needed = labelWidth(for: formatter(for: candidate, visibleDays: days)) + minimumLabelGap
            if pitch >= needed { return candidate }
            let next = cursor + 1
            // A coarser rung that can't fit two labels on the plot is worse than a tight one —
            // a lone label at one end isn't a scale.
            guard next < strideLadder.count,
                  days / strideLadder[next].approximateDays >= 2 else { return candidate }
            cursor = next
        }
    }

    /// Aim for roughly four to six labels across the plot.
    private static func baseTickStride(forVisibleDays days: Double) -> TickStride {
        switch days {
        case ..<0.04: .minutes(5)
        case ..<0.09: .minutes(10)
        case ..<0.22: .minutes(30)
        case ..<0.5: .hours(1)
        // A whole day's window wants a clean 3-hourly clock — six labels across the plot,
        // landing on the times a person reads without thinking (9am / 12pm / 3pm).
        case ..<1.1: .hours(3)
        case ..<2.5: .hours(6)
        case ..<13: .days(2)
        case ..<26: .days(4)
        case ..<55: .days(7)
        case ..<110: .days(14)
        case ..<200: .months(1)
        case ..<400: .months(2)
        case ..<800: .months(3)
        case ..<1_600: .months(6)
        case ..<3_600: .years(1)
        case ..<7_300: .years(2)
        default: .years(5)
        }
    }

    /// The dates the x axis marks, aligned to real calendar boundaries *and* to a fixed
    /// multiple of the stride — so the ticks sit still while the window slides across them
    /// instead of crawling along with it.
    public static func dateTicks(for frame: ChartFrame, plotWidth: CGFloat = 0, limit: Int = 14) -> [DateTick] {
        let start = Date(timeIntervalSinceReferenceDate: frame.start)
        let end = Date(timeIntervalSinceReferenceDate: frame.start + frame.span)
        let stride = tickStride(forVisibleDays: frame.visibleDays, plotWidth: plotWidth)
        var dates: [Date] = []

        switch stride {
        case .minutes(let step):
            dates = alignedByFixedInterval(
                start: start, end: end, seconds: Double(step) * 60, limit: limit
            )

        case .hours(let step):
            dates = alignedByFixedInterval(
                start: start, end: end, seconds: Double(step) * 3_600, limit: limit
            )

        case .days(let step):
            var cursor = calendar.startOfDay(for: start)
            let epoch = Date(timeIntervalSinceReferenceDate: 0)
            let index = calendar.dateComponents([.day], from: epoch, to: cursor).day ?? 0
            let offset = ((index % step) + step) % step
            if offset != 0 {
                cursor = calendar.date(byAdding: .day, value: -offset, to: cursor) ?? cursor
            }
            while cursor <= end, dates.count < limit {
                if cursor >= start { dates.append(cursor) }
                guard let next = calendar.date(byAdding: .day, value: step, to: cursor) else { break }
                cursor = next
            }

        case .months(let step):
            var components = calendar.dateComponents([.year, .month], from: start)
            if let month = components.month { components.month = month - ((month - 1) % step) }
            components.day = 1
            if var cursor = calendar.date(from: components) {
                while cursor <= end, dates.count < limit {
                    if cursor >= start { dates.append(cursor) }
                    guard let next = calendar.date(byAdding: .month, value: step, to: cursor) else { break }
                    cursor = next
                }
            }

        case .years(let step):
            var components = calendar.dateComponents([.year], from: start)
            if let year = components.year { components.year = year - (((year % step) + step) % step) }
            components.month = 1
            components.day = 1
            if var cursor = calendar.date(from: components) {
                while cursor <= end, dates.count < limit {
                    if cursor >= start { dates.append(cursor) }
                    guard let next = calendar.date(byAdding: .year, value: step, to: cursor) else { break }
                    cursor = next
                }
            }
        }

        let formatter = self.formatter(for: stride, visibleDays: frame.visibleDays)
        return dates.map { DateTick(date: $0, label: formatter.string(from: $0)) }
    }

    /// Sub-day strides divide the day evenly, so aligning to a multiple of the interval from
    /// midnight keeps the ticks on round clock times.
    private static func alignedByFixedInterval(
        start: Date, end: Date, seconds: Double, limit: Int
    ) -> [Date] {
        var dates: [Date] = []
        let midnight = calendar.startOfDay(for: start).timeIntervalSinceReferenceDate
        let elapsed = start.timeIntervalSinceReferenceDate - midnight
        var cursor = midnight + (elapsed / seconds).rounded(.down) * seconds
        while cursor <= end.timeIntervalSinceReferenceDate, dates.count < limit {
            if cursor >= start.timeIntervalSinceReferenceDate {
                dates.append(Date(timeIntervalSinceReferenceDate: cursor))
            }
            cursor += seconds
        }
        return dates
    }

    /// A fixed date whose label runs about as wide as each format ever gets — a two-digit day
    /// in a long month name, a two-digit afternoon hour, a four-digit year. Measuring the
    /// widest form rather than the live labels is what keeps the stride from flapping as the
    /// window slides across noon or a month boundary.
    private static let widestLabelSample: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 12
        components.day = 30
        components.hour = 12
        components.minute = 38
        return calendar.date(from: components) ?? Date(timeIntervalSinceReferenceDate: 0)
    }()

    /// Measured once per format (and per Dynamic Type size) and kept — `tickStride` asks on
    /// every frame, and laying out a string to answer it 120 times a second is exactly the cost
    /// `ChartAxisLabels` exists to avoid.
    private static var measuredLabelWidths: [String: CGFloat] = [:]

    public static func labelWidth(for formatter: DateFormatter) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .caption2)
        let key = "\(formatter.dateFormat ?? "")|\(font.pointSize)"
        if let cached = measuredLabelWidths[key] { return cached }
        let width = ceil(
            (formatter.string(from: widestLabelSample) as NSString)
                .size(withAttributes: [.font: font]).width
        )
        measuredLabelWidths[key] = width
        return width
    }

    private static func formatter(for stride: TickStride, visibleDays: Double) -> DateFormatter {
        switch stride {
        // On the hour there is no minute worth printing: "6 AM" reads as a scale where
        // "6:00 AM" reads as a timestamp.
        case .minutes: timeTickFormatter
        case .hours: hourTickFormatter
        case .days: dayTickFormatter
        case .months: visibleDays > 400 ? monthYearTickFormatter : monthTickFormatter
        case .years: yearTickFormatter
        }
    }

    // MARK: - Formatters

    // Cached as `static let` — `Date.FormatStyle` is slower and these are read per frame.
    public static let timeTickFormatter = localizedFormatter("jmm")
    public static let hourTickFormatter = localizedFormatter("j")
    public static let dayTickFormatter = localizedFormatter("MMMd")
    public static let monthTickFormatter = localizedFormatter("MMM")
    public static let monthYearTickFormatter = localizedFormatter("MMMyy")
    public static let yearTickFormatter = localizedFormatter("yyyy")
    public static let calloutDateFormatter = localizedFormatter("MMMdyyyy")
    public static let calloutDayFormatter = localizedFormatter("MMMd")
    public static let calloutMonthFormatter = localizedFormatter("MMMyyyy")

    public static func localizedFormatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    /// What a bucket at `level` calls itself in a readout — a day says "Aug 12", a month
    /// says "Aug 2026", a week says the span it covers.
    public static func bucketLabel(start: Date, end: Date, bucket: ChartBucket) -> String {
        switch bucket {
        case .day:
            return calloutDateFormatter.string(from: start)
        case .week:
            let last = end.addingTimeInterval(-1)
            let from = calloutDayFormatter.string(from: start)
            if calendar.isDate(start, equalTo: last, toGranularity: .month) {
                return "\(from) – \(calendar.component(.day, from: last))"
            }
            return "\(from) – \(calloutDayFormatter.string(from: last))"
        case .month:
            return calloutMonthFormatter.string(from: start)
        case .quarter:
            let last = end.addingTimeInterval(-1)
            return "\(monthTickFormatter.string(from: start))–\(monthYearTickFormatter.string(from: last))"
        case .year:
            return yearTickFormatter.string(from: start)
        }
    }
}

// MARK: - The labels

/// The axis labels as positioned views. Ticks sliding out of the window fade rather than
/// popping, which is the difference between a chart that glides and one that flickers.
public struct ChartAxisLabels: View {
    public let size: CGSize
    public let frame: ChartFrame
    public let transform: ChartTransform
    public let dateGutter: CGFloat
    /// How a value-axis tick is written. Supplied by the chart, since a weight, a calorie
    /// count and a percentage all round differently.
    public let valueLabel: (Double) -> String
    public var tickLimit: Int = 8

    public var body: some View {
        let rect = transform.plot
        ZStack(alignment: .topLeading) {
            ForEach(ChartAxis.valueTicks(frame, limit: tickLimit), id: \.self) { tick in
                let y = transform.y(tick)
                if y >= rect.minY - 6, y <= rect.maxY + 6 {
                    Text(valueLabel(tick))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: max(rect.minX - 4, 1), alignment: .trailing)
                        .position(x: max(rect.minX - 4, 1) / 2, y: y)
                }
            }
            ForEach(ChartAxis.dateTicks(for: frame, plotWidth: rect.width), id: \.date) { tick in
                let x = transform.x(tick.date.timeIntervalSinceReferenceDate)
                if x >= rect.minX - 2, x <= rect.maxX + 2 {
                    Text(tick.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .opacity(Double(min(1, min(x - rect.minX, rect.maxX - x) / 22)))
                        .position(x: x, y: size.height - dateGutter / 2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
