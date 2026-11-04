import SwiftUI

/// The scaffolding every custom chart on this core shares (#2682): the plot rect, the canvas,
/// the axis labels, the band above the plot, and the four recognisers.
///
/// A chart supplies three things and nothing else — how wide its value gutter is, what to
/// draw, and what goes in the band. Everything structural is here, so a second chart can't
/// quietly diverge from the first on the parts that ought to be identical.
public struct ChartPlot<Series: ChartSeries, Band: View>: View {
    public let viewport: ChartViewport<Series>
    public let layout: ChartLayout
    /// Measured off the SERIES, never the live eased domain — see `ChartAxis.valueGutter`.
    public let valueGutter: CGFloat
    public let valueLabel: (Double) -> String
    public var tickLimit: Int = 8
    /// A tap has nothing to inspect — the readout only lives under a finger — so on a chart
    /// shown in a row it opens the full-screen one instead. nil leaves taps alone.
    public var onTap: (() -> Void)?
    /// The drawing. Given plain values, captured by the `Canvas` closure, so nothing reaches
    /// back into the observable model mid-draw.
    public let draw: (GraphicsContext, ChartFrame, ChartTransform) -> Void
    /// The band above the plot: the resting header, and the readout that replaces it. Both
    /// ride `frame.calloutOpacity` so they cross-fade on the ticker's clock — a SwiftUI
    /// transition could fade the card but never the marker inside the canvas.
    @ViewBuilder public let band: (ChartFrame, ChartTransform, CGSize) -> Band

    public var body: some View {
        GeometryReader { geometry in
            // Read the moving values HERE, in `body`. Observation tracking is registered
            // where a view's body is evaluated; reading the model inside the canvas closure
            // is not reliably tracked.
            let frame = viewport.frame
            let rect = layout.plotRect(in: geometry.size, valueGutter: valueGutter)
            let transform = ChartTransform(plot: rect, frame: frame)

            ZStack(alignment: .topLeading) {
                Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, _ in
                    draw(context, frame, transform)
                }
                ChartAxisLabels(
                    size: geometry.size,
                    frame: frame,
                    transform: transform,
                    dateGutter: layout.dateGutter,
                    valueLabel: valueLabel,
                    tickLimit: tickLimit
                )
                band(frame, transform, geometry.size)
            }
            .chartGestures(viewport: viewport, transform: transform, onTap: onTap)
            // Reported rather than read during body: a bucketed series picks what one bar
            // covers from the width, and writing it inside the body pass that reads it would
            // be a mutation mid-update.
            .onChange(of: rect.width, initial: true) { _, width in
                viewport.setPlotWidth(width)
            }
            #if DEBUG
            // #3153 — where the plot sits inside the chart, for a take's drawn finger.
            .onChange(of: rect, initial: true) { _, rect in
                ChartHooks.plotRectChanged?(ObjectIdentifier(viewport), rect)
            }
            #endif
        }
    }

    public init(
        viewport: ChartViewport<Series>,
        layout: ChartLayout,
        valueGutter: CGFloat,
        valueLabel: @escaping (Double) -> String,
        tickLimit: Int = 8,
        onTap: (() -> Void)? = nil,
        draw: @escaping (GraphicsContext, ChartFrame, ChartTransform) -> Void,
        @ViewBuilder band: @escaping (ChartFrame, ChartTransform, CGSize) -> Band
    ) {
        self.viewport = viewport
        self.layout = layout
        self.valueGutter = valueGutter
        self.valueLabel = valueLabel
        self.tickLimit = tickLimit
        self.onTap = onTap
        self.draw = draw
        self.band = band
    }
}

// MARK: - Grid

extension GraphicsContext {
    /// The value-axis gridlines. Drawn before the clip, so they run the full width of the
    /// plot rather than stopping where the data does.
    public func drawChartGrid(frame: ChartFrame, transform: ChartTransform, tickLimit: Int = 8) {
        let rect = transform.plot
        var grid = Path()
        for tick in ChartAxis.valueTicks(frame, limit: tickLimit) {
            let y = transform.y(tick)
            guard y >= rect.minY - 1, y <= rect.maxY + 1 else { continue }
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        stroke(grid, with: .color(.secondary.opacity(0.14)), lineWidth: 0.5)
    }
}
