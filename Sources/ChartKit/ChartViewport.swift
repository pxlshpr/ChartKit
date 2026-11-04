import SwiftUI

/// The viewport half of the custom chart core (#2682, extracted from #2673's weight chart):
/// where the window sits, how wide it is, what the value axis is currently showing, which
/// datum is called out — plus the physics that move all of those.
///
/// Everything here is main-actor state mutated at most once per frame. A pan writes `start`,
/// a pinch writes `start` and `span`, and the ticker eases momentum, spring-back, preset
/// glides, the value axis and the readout's cross-fade. Nothing recomputes the series, so a
/// frame costs the same whether the history is a month or a decade.
///
/// It is generic over the series so a line chart and a bar chart share one set of physics:
/// the series answers "what's under this x" and "what do the values span here", and the
/// viewport does not care which shape the answer came from.

// MARK: - Range presets

/// A preset zoom level. A struct rather than an enum so each chart can offer the set its own
/// data justifies — a weight history wants months and years, a workout wants minutes.
public struct ChartRange: Identifiable, Hashable, Sendable {
    public let id: String
    /// The window this pins, in days. `nil` resolves to the whole series at apply time.
    public let days: Double?
    /// The pill's short form.
    public let label: String
    /// The full-screen scale menu's long form — a nav bar has room for words.
    public let menuLabel: String
    /// What a header's delta badge calls the window.
    public let caption: String

    public static let week = ChartRange(id: "1W", days: 7, label: "1W", menuLabel: "1 week", caption: "past week")
    public static let twoWeeks = ChartRange(id: "2W", days: 14, label: "2W", menuLabel: "2 weeks", caption: "past fortnight")
    public static let month = ChartRange(id: "1M", days: 30, label: "1M", menuLabel: "1 month", caption: "past month")
    public static let threeMonths = ChartRange(id: "3M", days: 91, label: "3M", menuLabel: "3 months", caption: "past 3 months")
    public static let sixMonths = ChartRange(id: "6M", days: 182, label: "6M", menuLabel: "6 months", caption: "past 6 months")
    public static let year = ChartRange(id: "1Y", days: 365, label: "1Y", menuLabel: "1 year", caption: "past year")
    /// Opt-in only (#3919): neither `standard` nor `daily` includes it, so NutriKit's and
    /// Insights' pills are unchanged. A strength history runs to years, and between 1Y and All
    /// there was nothing to read a two-year block by.
    public static let twoYears = ChartRange(id: "2Y", days: 730, label: "2Y", menuLabel: "2 years", caption: "past 2 years")
    public static let all = ChartRange(id: "All", days: nil, label: "All", menuLabel: "All time", caption: "all time")

    /// The default ladder for a long history.
    public static let standard: [ChartRange] = [.month, .threeMonths, .sixMonths, .year, .all]
    /// For daily data, where a week is a view worth having.
    public static let daily: [ChartRange] = [.week, .month, .threeMonths, .sixMonths, .year, .all]
    /// For years of sparse data — a lift trained once or twice a week (#3919, Overload). A
    /// month of that is a handful of dots, so the ladder starts at 3M and adds 2Y instead.
    /// Opt-in through `ChartViewportConfiguration(ranges:)`; no default uses it.
    public static let longHistory: [ChartRange] = [.threeMonths, .sixMonths, .year, .twoYears, .all]

    public init(
        id: String,
        days: Double?,
        label: String,
        menuLabel: String,
        caption: String
    ) {
        self.id = id
        self.days = days
        self.label = label
        self.menuLabel = menuLabel
        self.caption = caption
    }
}

// MARK: - Configuration

/// The per-chart knobs on otherwise identical physics.
public struct ChartViewportConfiguration: Sendable {
    public var ranges: [ChartRange] = ChartRange.standard
    /// The window the chart opens on when there is more than that on record.
    public var defaultRange: ChartRange = .threeMonths
    /// Below this the chart is showing individual data rather than a progression.
    public var minimumVisibleDays: Double = 10
    /// The shortest the whole domain is allowed to READ as (#2697).
    ///
    /// Everything about the window is measured off the domain — how far a pinch can zoom out,
    /// which presets are worth offering, what "All" resolves to — and a series has to be
    /// floored somewhere or a single reading would give all three a zero to divide by. A day
    /// is right for anything plotted in days. A workout is NOT: floored at a day, an eleven
    /// minute swim offered 15m, 30m and 1h scales that were mostly empty plot, and pinch
    /// could pull the trace down to a smear in the corner of an otherwise blank chart. Set it
    /// to something a chart's own subject can't be shorter than.
    public var minimumFullSpan: Double = ChartMetrics.day
    /// Headroom the value axis leaves around the visible data, as a fraction of its extent.
    public var valuePadFraction: Double = 0.22
    /// …and the floor in value units, so a flat series still gets air.
    public var valuePadMinimum: Double = 0.6
    /// Bar charts must include zero — a bar chart that doesn't start at zero misrepresents
    /// the ratio between its bars — so the bottom is pinned and only the top is quantised.
    public var pinsZero: Bool = false
    /// Roughly how many gridlines to aim for.
    public var targetTickCount: Double = 3.2
    /// Whether the chart grows in from the baseline the first time data lands. Bar charts in
    /// a card do; a chart the user is going to immediately start panning doesn't need it.
    /// It rides the ticker with everything else — `withAnimation` can't reach a `Canvas`, so
    /// a plain animated `@State` would set the value and the drawing would snap.
    public var introGrowth: Bool = false
    /// #2877 — how long a morph takes (`ChartViewport.load(_:morphing:)`): a rebuild that
    /// keeps the chart's shape and moves its values glides between the two over this, on the
    /// ticker, for the same reason the intro does. 0.9s is the `withAnimation` the GI-aware
    /// surfaces already wrap their refinement in (#2251) — which a `Canvas` never saw.
    public var morphDuration: Double = 0.9

    public static let line = ChartViewportConfiguration()
    public static let bars = ChartViewportConfiguration(
        ranges: ChartRange.daily,
        defaultRange: .month,
        minimumVisibleDays: 7,
        valuePadFraction: 0.15,
        valuePadMinimum: 0,
        pinsZero: true
    )

    public init(
        ranges: [ChartRange] = ChartRange.standard,
        defaultRange: ChartRange = .threeMonths,
        minimumVisibleDays: Double = 10,
        minimumFullSpan: Double = ChartMetrics.day,
        valuePadFraction: Double = 0.22,
        valuePadMinimum: Double = 0.6,
        pinsZero: Bool = false,
        targetTickCount: Double = 3.2,
        introGrowth: Bool = false,
        morphDuration: Double = 0.9
    ) {
        self.ranges = ranges
        self.defaultRange = defaultRange
        self.minimumVisibleDays = minimumVisibleDays
        self.minimumFullSpan = minimumFullSpan
        self.valuePadFraction = valuePadFraction
        self.valuePadMinimum = valuePadMinimum
        self.pinsZero = pinsZero
        self.targetTickCount = targetTickCount
        self.introGrowth = introGrowth
        self.morphDuration = morphDuration
    }
}

// MARK: - Frame snapshot

/// Everything a redraw depends on, read out of the viewport in `body` so the values are
/// captured by the `Canvas` closure — and so SwiftUI registers the dependency where it can
/// act on it. `Equatable` so a redraw that changes nothing is skipped outright.
public struct ChartFrame: Equatable, Sendable {
    public var start: Double
    public var span: Double
    public var yLow: Double
    public var yHigh: Double
    public var yStep: Double
    /// The x of the datum the readout is drawing, and how faded in it is. Both, because
    /// during the fade-out there is still something to draw at less than full opacity.
    public var calloutX: Double?
    public var calloutOpacity: Double
    /// 0 → 1 while the chart grows in from the baseline on first load; a flat 1 for charts
    /// that don't ask for the intro.
    public var introGrowth: Double = 1

    public var visibleRange: ClosedRange<Double> { start ... (start + span) }
    public var visibleDays: Double { span / ChartMetrics.day }

    public static let placeholder = ChartFrame(
        start: 0, span: ChartMetrics.day, yLow: 0, yHigh: 1, yStep: 1,
        calloutX: nil, calloutOpacity: 0, introGrowth: 1
    )
}

// MARK: - Transform

/// Maps between domain values and points inside the plot rect.
public struct ChartTransform {
    public let plot: CGRect
    public let start: Double
    public let span: Double
    public let yLow: Double
    public let yHigh: Double

    public init(plot: CGRect, frame: ChartFrame) {
        self.plot = plot
        self.start = frame.start
        self.span = frame.span
        self.yLow = frame.yLow
        self.yHigh = frame.yHigh
    }

    public func x(_ value: Double) -> CGFloat {
        plot.minX + CGFloat((value - start) / max(span, .ulpOfOne)) * plot.width
    }

    public func y(_ value: Double) -> CGFloat {
        plot.maxY - CGFloat((value - yLow) / max(yHigh - yLow, .ulpOfOne)) * plot.height
    }

    /// How wide one domain second is, in points — what a bar's geometry is built from.
    public var pointsPerSecond: CGFloat { plot.width / CGFloat(max(span, .ulpOfOne)) }

    public func domainValue(atX point: CGFloat) -> Double {
        start + Double((point - plot.minX) / max(plot.width, 1)) * span
    }
}

// MARK: - Viewport

@MainActor
@Observable
public final class ChartViewport<Series: ChartSeries> {
    public private(set) var series: Series = .empty
    public var configuration: ChartViewportConfiguration

    /// The visible window's leading edge and length, in seconds.
    public private(set) var start: Double = 0
    public private(set) var span: Double = 91 * ChartMetrics.day

    /// The value axis, eased toward whatever the visible window needs rather than snapped —
    /// a hard jump on every pan frame is what makes a chart feel like it's fighting you.
    public private(set) var yLow: Double = 0
    public private(set) var yHigh: Double = 1
    public private(set) var yStep: Double = 1

    /// The called-out datum, as its x in the domain. Live only while a finger is on the
    /// chart — the readout is an inspection tool, not a mode, so releasing puts it away.
    ///
    /// An *x* rather than an index on purpose: a bucketed bar series changes what index N
    /// means when the level of detail changes, and an x re-resolves correctly against
    /// whatever level is current.
    public private(set) var selectedX: Double?
    /// What the readout should DRAW. Tracks `selectedX` while there is one and then outlives
    /// it, holding the last datum until the fade has finished — otherwise the card and its
    /// marker would vanish on the frame the finger lifted and there'd be nothing to fade.
    public private(set) var calloutX: Double?
    /// The readout's opacity, eased on the ticker. Everything the readout is made of — the
    /// card, its connector, the marker drawn into the canvas, and the header it replaces —
    /// reads from this one number, so they cross-fade together instead of a SwiftUI
    /// transition fading the card while the canvas pops.
    public private(set) var calloutOpacity: Double = 0

    /// How far the intro growth has run. Starts at 1 for charts that don't want one, so the
    /// ticker has nothing to do.
    public private(set) var introGrowth: Double = 1

    /// #2877 — the series a morph is gliding away from, while one is in flight, and how far it
    /// has got (linear 0…1; eased where it is read, like the intro). Set by
    /// `load(_:morphing:)`, advanced by the ticker, read through `displayed(_:)`.
    private var morphFrom: Series?
    public private(set) var morphProgress: Double = 1
    /// Whether a morph is gliding right now — a header showing the settled figure rolls it
    /// (`.numericText`) only then, never while a pan moves the window under it (#3217).
    public var isMorphing: Bool { morphProgress < 1 }

    /// Which preset the window currently matches — nil once a pinch lands in between.
    public private(set) var preset: ChartRange?
    /// Set once the user has framed a view of their own, so data landing later (an async
    /// HealthKit fetch, an extended history load) stops resetting the window under them.
    private var hasUserAdjusted = false

    /// #3729 — where the history will reach once it is all loaded, for a screen that loads the
    /// recent part first (the Weight screen: Apple Health's earliest reading, before its whole
    /// history is read). The presets on offer and the opening window's choice measure from it, so
    /// neither changes as the rest lands. Nil: what is loaded is all there is.
    public var expectedDomainStart: Double?

    /// How wide the plot currently is, reported by `ChartPlot`. A bucketed series resolves
    /// what one bar covers from it — the same ninety days is a dozen weekly columns on a
    /// phone upright and ninety daily ones turned sideways — so the value axis has to be
    /// asked with it in hand or it would scale for bars the chart isn't drawing.
    public private(set) var plotWidth: CGFloat = ChartBarSeries.assumedPlotWidth

    public func setPlotWidth(_ width: CGFloat) {
        guard width > 1, abs(width - plotWidth) > 0.5 else { return }
        plotWidth = width
        refreshValueAxis(animated: true)
    }

    // MARK: Physics state

    private let ticker = ChartTicker()
    /// Momentum from a flick, in domain-seconds per second.
    private var velocity: Double = 0
    private var targetYLow: Double = 0
    private var targetYHigh: Double = 1
    private var calloutTarget: Double = 0
    /// A preset glide in progress: where it started, where it lands, how far along it is, and
    /// how long it takes (#2877: a morph whose domain moved glides the window over the morph's
    /// own span; a preset's is the quick 0.34s it always was).
    private var glide: (fromStart: Double, fromSpan: Double, toStart: Double, toSpan: Double, progress: Double, duration: Double)?

    /// Where a pan or pinch began, so every update is measured from the gesture's own origin
    /// rather than accumulated frame by frame (which drifts).
    private var gestureStart: Double?
    private var gestureSpan: Double?

    public init(configuration: ChartViewportConfiguration = .line) {
        self.configuration = configuration
        introGrowth = configuration.introGrowth ? 0 : 1
        ticker.onTick = { [weak self] delta in
            self?.tick(delta)
        }
    }

    // MARK: - Loading

    /// Hands the viewport a rebuilt series. A window the user framed themselves survives it;
    /// anything else opens on the default range.
    ///
    /// `morphing` (#2877) asks for the change to be GLIDED rather than drawn: when the chart is
    /// already up and the rebuilt series shares its shape (`Series.morphed(from:progress:)`
    /// says so), the values ease from the ones on screen to the new ones over
    /// `configuration.morphDuration`, on the ticker — the intro's arrangement, for the same
    /// reason: a `withAnimation` around the state a `Canvas` draws from changes nothing the
    /// canvas can see. The case this exists for is a refinement landing after the first draw
    /// — the meal-spread curve re-shaped by a GI derivation that came back a beat after the
    /// sheet appeared (#2251) — which read as the chart changing its mind. A series with a
    /// different shape, or one landing on an empty chart, is loaded as before.
    public func load(_ rebuilt: Series, morphing: Bool = false) {
        guard rebuilt != series else { return }
        let wasEmpty = series.isEmpty
        // From what is ON SCREEN — a morph interrupted by another continues from where it got
        // to rather than jumping back to where it started.
        let shown = displayed(series)
        let morphs = morphing && !wasEmpty && !rebuilt.isEmpty
            && rebuilt.morphed(from: shown, progress: 0) != nil
        if morphs {
            morphFrom = shown
            morphProgress = 0
        } else {
            morphFrom = nil
            morphProgress = 1
        }
        series = rebuilt
        select(nil)

        if wasEmpty || !hasUserAdjusted {
            if morphs {
                // The domain may have moved with the values (a refined curve's drop-off edge
                // sits later or sooner): the axis slides there with the curve rather than
                // jumping ahead of it.
                glideToOpeningWindow(over: configuration.morphDuration)
            } else {
                resetWindow()
            }
            if wasEmpty, configuration.introGrowth, !rebuilt.isEmpty { ticker.start() }
        } else {
            // The user has framed something — keep it, just make sure it still fits the
            // history that just grew underneath it.
            setWindow(start: start, span: min(span, maxSpan), animateValueAxis: true)
        }
        if morphs { ticker.start() }
    }

    /// The series to draw THIS FRAME (#2877): `series` as given — or, while a morph is in
    /// flight, the blend between the series it replaced and it. Read it in `body`, where the
    /// read is tracked, so every tick of the morph redraws; the eased progress is applied here
    /// so the stored value stays plain, as the intro's does.
    public func displayed(_ series: Series) -> Series {
        guard let morphFrom, morphProgress < 1 else { return series }
        let eased = morphProgress * morphProgress * (3 - 2 * morphProgress)
        return series.morphed(from: morphFrom, progress: eased) ?? series
    }

    /// `resetWindow`, eased (#2877): the opening window reached by a glide over `duration`
    /// rather than set — for a morph whose domain moved with its values. A domain that stayed
    /// put glides nowhere.
    private func glideToOpeningWindow(over duration: Double) {
        let fullDays = presetHistorySpan / ChartMetrics.day
        let defaultDays = configuration.defaultRange.days ?? .infinity
        let choice: ChartRange = fullDays > defaultDays * 1.1 ? configuration.defaultRange : .all
        preset = choice
        let length = clampedSpan(for: choice)
        let destination = series.domainEnd - length
        guard abs(destination - start) > 0.5 || abs(length - span) > 0.5 else {
            // Nowhere to glide; the value axis still chases whatever the values became.
            refreshValueAxis(animated: true)
            return
        }
        velocity = 0
        glide = (fromStart: start, fromSpan: span, toStart: destination, toSpan: length,
                 progress: 0, duration: duration)
    }

    /// The opening frame: the configured default range when there's more than that on
    /// record, otherwise everything.
    public func resetWindow() {
        let fullDays = presetHistorySpan / ChartMetrics.day
        let defaultDays = configuration.defaultRange.days ?? .infinity
        let choice: ChartRange = fullDays > defaultDays * 1.1 ? configuration.defaultRange : .all
        preset = choice
        let length = clampedSpan(for: choice)
        setWindow(start: series.domainEnd - length, span: length, animateValueAxis: false)
    }

    // MARK: - Bounds

    /// The whole domain as this chart measures it — the series' own span, floored by the
    /// configuration rather than by a flat day (#2697).
    public var fullSpan: Double { series.fullSpan(floor: configuration.minimumFullSpan) }

    /// #3729 — what the presets measure: the history on record, back to where it will reach
    /// (`expectedDomainStart`), less the tail every preset carries past it (`presetTail`).
    private var presetHistorySpan: Double {
        let start = min(series.domainStart, expectedDomainStart ?? series.domainStart)
        return max(series.domainEnd - start, configuration.minimumFullSpan) - series.presetTail
    }

    public var minSpan: Double {
        min(configuration.minimumVisibleDays * ChartMetrics.day, fullSpan)
    }

    public var maxSpan: Double { max(fullSpan, minSpan) }

    private var minStart: Double { series.domainStart }
    private var maxStart: Double { max(series.domainStart, series.domainEnd - span) }

    /// The presets that would actually change the view — one longer than the data itself
    /// just duplicates All, and offering both makes the control feel broken.
    public var availableRanges: [ChartRange] {
        let fullDays = presetHistorySpan / ChartMetrics.day
        return configuration.ranges.filter { choice in
            guard let days = choice.days else { return true }
            return days < fullDays
        }
    }

    public var frame: ChartFrame {
        ChartFrame(
            start: start,
            span: span,
            yLow: yLow,
            yHigh: yHigh,
            yStep: yStep,
            calloutX: calloutX,
            calloutOpacity: calloutOpacity,
            // Eased here rather than in the ticker, so the stored value stays a plain
            // linear progress and the chart gets a factor it can multiply straight in.
            introGrowth: 1 - pow(1 - introGrowth, 3)
        )
    }

    public var visibleRange: ClosedRange<Double> { start ... (start + span) }

    /// What the visible window is, in words. A preset says its own name; a pinch says
    /// roughly how much time is on screen and keeps saying it as the fingers move, so the
    /// scale menu's label is a live readout of the zoom rather than a stale selection.
    public var windowLabel: String {
        if let preset { return preset.menuLabel }
        let days = span / ChartMetrics.day
        if days < 1.5 {
            let hours = Int((days * 24).rounded())
            return hours <= 1 ? "1 hour" : "\(hours) hours"
        }
        if days < 10.5 { return "\(Int(days.rounded())) days" }
        if days < 56 {
            let weeks = Int((days / 7).rounded())
            return weeks <= 1 ? "1 week" : "\(weeks) weeks"
        }
        if days < 730 {
            let months = Int((days / 30.44).rounded())
            return months <= 1 ? "1 month" : "\(months) months"
        }
        let years = (days / 365.25 * 10).rounded() / 10
        if years == years.rounded() { return "\(Int(years)) years" }
        return String(format: "%.1f years", years)
    }

    private func clampedSpan(for choice: ChartRange) -> Double {
        // #3729 — a preset's days of history, and the tail past it (`presetTail`).
        let requested = choice.days.map { $0 * ChartMetrics.day + series.presetTail } ?? fullSpan
        return min(max(requested, minSpan), maxSpan)
    }

    // MARK: - Window

    /// The one place the window is written. Clamps, then recomputes what the value axis
    /// should be showing for it.
    private func setWindow(start newStart: Double, span newSpan: Double, animateValueAxis: Bool) {
        span = min(max(newSpan, minSpan), maxSpan)
        start = min(max(newStart, minStart), maxStart)
        refreshValueAxis(animated: animateValueAxis)
    }

    /// Moves the window from somewhere other than a gesture — a list scrolled in sync with
    /// the chart, say. Clamps exactly as a pan does and leaves the preset alone, and defers
    /// to any gesture or glide already in progress rather than fighting it.
    public func setLeadingEdge(_ newStart: Double) {
        guard gestureStart == nil, glide == nil else { return }
        guard abs(newStart - start) > span * 1e-6 else { return }
        velocity = 0
        hasUserAdjusted = true
        start = min(max(newStart, minStart), maxStart)
        refreshValueAxis(animated: true)
        ticker.start()
    }

    /// A preset, from a pill, the segmented control or the full-screen menu: the window glides
    /// to the new length AROUND WHERE THE USER IS (#3282), never back to the end of the data.
    public func apply(_ choice: ChartRange) {
        ChartHooks.impact(.soft)
        preset = choice
        hasUserAdjusted = true
        velocity = 0
        select(nil)

        let length = clampedSpan(for: choice)
        // Measured from the window the user is looking at — or, when a glide is still in
        // flight, from where it is taking them: a second pill tapped before the first has
        // landed frames off the first's destination, not off a frame halfway there.
        let reference = glide.map { (start: $0.toStart, span: $0.toSpan) } ?? (start: start, span: span)
        let destination = presetStart(length: length, keeping: reference)
        glide = (fromStart: start, fromSpan: span, toStart: destination, toSpan: length,
                 progress: 0, duration: 0.34)
        ticker.start()
    }

    /// Where a preset's window of `length` lands, given the window it replaces (#3282).
    ///
    /// It used to land at the end of the data whatever was on screen, so a user who had panned
    /// or scrolled back to look at a period and then changed the scale for more context (or
    /// more detail) was thrown back to today every time. Now the date in the MIDDLE of the
    /// window stays in the middle — the pinch's rule with the anchor at the plot's centre,
    /// which is where a control with no finger on the plot has to put it — and the new window
    /// is clamped to the data like any other.
    ///
    /// A window resting against an edge of the data stays against it, though. The end is the
    /// common case: the opening frame and every pan that runs out of history both sit there,
    /// and a user looking at the latest fortnight who taps 1W wants the latest week, not the
    /// seven days around the fortnight's midpoint with today off the right-hand side. Both
    /// edges holding (the whole history on screen, as after All) resolves to the end, which is
    /// where a zoom in from All has always landed.
    private func presetStart(length: Double, keeping reference: (start: Double, span: Double)) -> Double {
        let lastStart = max(series.domainEnd - length, series.domainStart)
        // Clamped values are exact to within rounding; a sliver of the span absorbs that
        // without ever reaching a window the user framed a real distance from the edge.
        let slack = reference.span * 0.001
        if reference.start >= max(series.domainEnd - reference.span, series.domainStart) - slack {
            return lastStart
        }
        if reference.start <= series.domainStart + slack {
            return series.domainStart
        }
        let centre = reference.start + reference.span / 2
        return min(max(centre - length / 2, series.domainStart), lastStart)
    }

    // MARK: - Panning

    public func beginPan() {
        gestureStart = start
        hasUserAdjusted = true
        velocity = 0
        glide = nil
        ticker.stop()
        select(nil)
    }

    /// `translation` is the gesture's total horizontal travel; `width` the plot's width.
    public func pan(translation: CGFloat, width: CGFloat) {
        guard let gestureStart, width > 0 else { return }
        let perPoint = span / Double(width)
        let proposed = gestureStart - Double(translation) * perPoint
        // Past either end the window keeps moving, but grudgingly — the same rubber band
        // every scroll view on the platform uses, so the edge announces itself.
        start = rubberBanded(proposed)
        refreshValueAxis(animated: true)
        ticker.start()
    }

    public func endPan(velocityX: CGFloat, width: CGFloat) {
        gestureStart = nil
        guard width > 0 else { return }
        if start < minStart || start > maxStart {
            velocity = 0
        } else {
            velocity = -Double(velocityX) * span / Double(width)
        }
        ticker.start()
    }

    private func rubberBanded(_ proposed: Double) -> Double {
        let limit = span * 0.3
        if proposed < minStart {
            return minStart - resisted(minStart - proposed, limit: limit)
        }
        if proposed > maxStart {
            return maxStart + resisted(proposed - maxStart, limit: limit)
        }
        return proposed
    }

    /// The platform's own resistance curve: asymptotic, so the window can never be pulled
    /// past `limit` however hard the finger tries.
    private func resisted(_ overshoot: Double, limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        return (1 - 1 / (overshoot / limit + 1)) * limit
    }

    // MARK: - Zooming

    public func beginPinch() {
        gestureStart = start
        gestureSpan = span
        velocity = 0
        glide = nil
        ticker.stop()
    }

    /// `scale` is the gesture's magnification since it began; `anchor` where its centre sits
    /// across the plot (0 leading, 1 trailing); `translation` how far that centre has moved.
    public func pinch(scale: CGFloat, anchor: CGFloat, translation: CGFloat, width: CGFloat) {
        guard let gestureStart, let gestureSpan, width > 0 else { return }
        preset = nil
        hasUserAdjusted = true
        select(nil)

        let proposedSpan = gestureSpan / max(Double(scale), 0.05)
        let newSpan = min(max(proposedSpan, minSpan), maxSpan)
        // Hold the date under the fingers still: the chart grows and shrinks around what
        // the user is actually looking at, rather than squirming away from them.
        let anchorFraction = Double(min(max(anchor, 0), 1))
        let anchorValue = gestureStart + anchorFraction * gestureSpan
        let shifted = anchorValue - Double(translation) * (newSpan / Double(width))
        span = newSpan
        start = rubberBanded(shifted - anchorFraction * newSpan)
        refreshValueAxis(animated: true)
        ticker.start()
    }

    public func endPinch() {
        gestureStart = nil
        gestureSpan = nil
        ticker.start()
    }

    // MARK: - Selection

    /// The one place the selection is written, so nothing can set it without also driving
    /// the fade. A newly called-out datum ticks; re-reporting the same one is silent, which
    /// is what keeps a scrub from buzzing once per frame.
    private func select(_ x: Double?) {
        guard x != selectedX else { return }
        selectedX = x
        if x != nil {
            calloutX = x
            calloutTarget = 1
            ChartHooks.selection()
        } else {
            // `calloutX` stays put; the ticker clears it once the fade is done.
            calloutTarget = 0
        }
        ticker.start()
    }

    public func beginScrub(atX point: CGFloat, transform: ChartTransform) {
        velocity = 0
        glide = nil
        scrub(atX: point, transform: transform)
    }

    public func scrub(atX point: CGFloat, transform: ChartTransform) {
        // A finger that wanders off the plot — or into the band above it — keeps scrubbing,
        // but only across what is actually on screen: the readout card has to stay somewhere
        // the user can read it.
        let clamped = min(max(point, transform.plot.minX), transform.plot.maxX)
        let value = min(max(transform.domainValue(atX: clamped), start), start + span)
        select(series.datumX(nearest: value, in: visibleRange, plotWidth: transform.plot.width))
    }

    /// Lifting the finger puts the readout away. It answers "what is this?" for as long as
    /// you are asking; leaving it up afterwards just covers the chart with a stale answer to
    /// a question nobody is asking any more.
    public func endScrub() {
        select(nil)
    }

    public func clearSelection() {
        select(nil)
    }

    #if DEBUG
    /// #3081 (w-6) — a scripted press-and-slide, for the take that films one.
    ///
    /// The real gesture arrives from `ChartPlot`, which owns the plot's geometry and hands
    /// `scrub(atX:transform:)` a point in its own coordinates. A take has no finger and no
    /// geometry, so it says WHERE across the plot instead — `fraction` 0 at the left edge, 1 at
    /// the right — and the transform is rebuilt here from the two things the viewport already
    /// tracks for itself: `plotWidth`, which `ChartPlot` reports every layout, and `frame`,
    /// which is the window being drawn. Everything past that point is the gesture's own code:
    /// the clamp, the domain conversion, the nearest-datum search, the selection haptic and
    /// the callout's fade all run exactly as they do under a thumb.
    ///
    /// The plot's height is irrelevant to a scrub (`scrub(atX:)` reads only the x axis), so the
    /// rect is one point tall rather than pretending to a height this type cannot know.
    public func snippetScrub(toFraction fraction: Double) {
        let plot = CGRect(x: 0, y: 0, width: max(plotWidth, 1), height: 1)
        let transform = ChartTransform(plot: plot, frame: frame)
        scrub(atX: plot.minX + CGFloat(min(max(fraction, 0), 1)) * plot.width, transform: transform)
    }
    #endif

    // MARK: - Value axis

    /// What the visible window needs the value axis to show, rounded out to whole ticks so
    /// the labels stay put while the window moves under them.
    private func refreshValueAxis(animated: Bool) {
        guard let extent = series.valueExtent(in: visibleRange, plotWidth: plotWidth) else { return }

        // A zero-pinned axis measures its headroom from zero, not from the data's own span:
        // a week where every day landed near 2,000 has almost no span, and padding off that
        // would leave the bars touching the top of the plot.
        let pinsZero = configuration.pinsZero
        let floorValue = min(0, extent.low)
        let reference = pinsZero ? extent.high - floorValue : extent.high - extent.low
        let pad = max(reference * configuration.valuePadFraction, configuration.valuePadMinimum)
        let low = pinsZero ? floorValue : extent.low - pad
        let high = extent.high + pad
        let step = Self.niceStep((high - low) / configuration.targetTickCount)
        yStep = step
        // A bar chart's floor is zero (or the data's own minimum when it goes negative) and
        // stays there; only the top quantises.
        targetYLow = pinsZero ? low : (low / step).rounded(.down) * step
        targetYHigh = (high / step).rounded(.up) * step
        if targetYHigh - targetYLow < step { targetYHigh = targetYLow + step }

        if animated {
            ticker.start()
        } else {
            yLow = targetYLow
            yHigh = targetYHigh
        }
    }

    /// 0.5, 1, 2, 5, 10 … — the ladder that keeps axis labels on numbers a person reads
    /// without thinking.
    public static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let exponent = (log10(raw)).rounded(.down)
        let magnitude = pow(10, exponent)
        let fraction = raw / magnitude
        let nice: Double
        switch fraction {
        case ..<1.5: nice = 1
        case ..<3: nice = 2
        case ..<7: nice = 5
        default: nice = 10
        }
        return nice * magnitude
    }

    // MARK: - The tick

    /// One frame of whatever is still moving. Stops the link the moment nothing is —
    /// a display link that never stops is a battery bug.
    private func tick(_ delta: CFTimeInterval) {
        var busy = false
        let step = max(delta, 1.0 / 120)

        if var glide {
            // A short ease-out for the pills, run here rather than through `withAnimation`
            // because the value it animates is read inside a `Canvas`.
            glide.progress = min(glide.progress + step / glide.duration, 1)
            let eased = 1 - pow(1 - glide.progress, 3)
            span = glide.fromSpan + (glide.toSpan - glide.fromSpan) * eased
            let interpolated = glide.fromStart + (glide.toStart - glide.fromStart) * eased
            start = min(max(interpolated, minStart), maxStart)
            refreshValueAxis(animated: true)
            if glide.progress >= 1 {
                self.glide = nil
            } else {
                self.glide = glide
                busy = true
            }
        } else if gestureStart == nil {
            if start < minStart || start > maxStart {
                // Spring back off the end, critically damped enough not to wobble.
                let target = start < minStart ? minStart : maxStart
                let settled = start + (target - start) * (1 - exp(-step / 0.09))
                start = abs(settled - target) < span * 0.0002 ? target : settled
                velocity = 0
                refreshValueAxis(animated: true)
                busy = start != target
            } else if velocity != 0 {
                start += velocity * step
                // The platform's own deceleration curve (UIScrollView's 0.998/ms), so a
                // flick here carries as far as a flick anywhere else in the app. It has to
                // be `pow(k, dt)` rather than a fixed multiply, or the deceleration depends
                // on the frame rate and feels different on a 60Hz device.
                velocity *= pow(0.135, step)
                if start < minStart || start > maxStart {
                    start = min(max(start, minStart), maxStart)
                    velocity = 0
                }
                // Below a fiftieth of the window per second there's nothing left to see.
                if abs(velocity) < span * 0.02 { velocity = 0 }
                refreshValueAxis(animated: true)
                busy = velocity != 0
            }
        }

        // The value axis chases the window a beat behind, which is what stops the chart from
        // twitching vertically on every pan frame.
        let settle = 1 - exp(-step / 0.11)
        let lowDelta = targetYLow - yLow
        let highDelta = targetYHigh - yHigh
        let epsilon = max((targetYHigh - targetYLow) * 0.0005, 0.0001)
        if abs(lowDelta) > epsilon || abs(highDelta) > epsilon {
            yLow += lowDelta * settle
            yHigh += highDelta * settle
            busy = true
        } else {
            yLow = targetYLow
            yHigh = targetYHigh
        }

        // The intro: bars rising out of the baseline the first time data lands. Ease-out
        // cubic over ~0.55s, on the ticker for the same reason everything else is.
        if introGrowth < 1 {
            introGrowth = min(introGrowth + step / 0.55, 1)
            if introGrowth < 1 { busy = true }
        }

        // #2877 — the morph: the values gliding from the series a rebuild replaced to the one
        // it loaded. On the ticker for the same reason the intro is.
        if morphProgress < 1 {
            morphProgress = min(morphProgress + step / max(configuration.morphDuration, 0.05), 1)
            if morphProgress < 1 {
                busy = true
            } else {
                morphFrom = nil
            }
        }

        // The readout cross-fades on the same clock. Quick — it is answering a finger, and a
        // slow fade reads as the card being reluctant to leave.
        if calloutOpacity != calloutTarget {
            let blend = 1 - exp(-step / 0.055)
            calloutOpacity += (calloutTarget - calloutOpacity) * blend
            if abs(calloutTarget - calloutOpacity) < 0.005 {
                calloutOpacity = calloutTarget
                // Fully faded out — only now is it safe to forget which datum it was.
                if calloutTarget == 0 { calloutX = nil }
            } else {
                busy = true
            }
        }

        if !busy && gestureStart == nil {
            ticker.stop()
        }
    }
}
