import SwiftUI

/// The chrome a custom chart wears (#2682, extracted from #2673's weight chart): the band
/// above the plot that the readout lives in, the card that rides the finger, the connector
/// that ties it to the data, and the range pills.
///
/// The band is the important idea. The card must never cover the thing it is describing, so
/// the height is reserved rather than floated over — and it costs nothing, because the
/// chart's resting header (latest value, daily average) lives in that same band and is what
/// the card *replaces*. Both read the same ticker-eased opacity, so they cross-fade against
/// each other and the marker drawn into the canvas leaves at exactly the same moment. A
/// SwiftUI `.transition` can fade the card but cannot reach inside a `Canvas`, which is why
/// the fade is a number rather than an animation.

// MARK: - Layout

/// Where a chart's band, plot and date gutter sit. One struct so the renderer, the gestures
/// and the readout all agree on the geometry without passing five numbers around.
public struct ChartLayout {
    public var bandHeight: CGFloat = 78
    public var dateGutter: CGFloat = 20
    public var plotHeight: CGFloat = 212

    /// Roughly how tall the readout card is, and how far the connector tucks under it.
    public var cardHalfHeight: CGFloat = 33
    public var cardLineOverlap: CGFloat = 4

    /// The card's centre inside the band.
    public var cardCentreY: CGFloat { bandHeight / 2 - 1 }
    /// The chart's total height when it is shown at a fixed size in a row.
    public var cardHeight: CGFloat { bandHeight + plotHeight + dateGutter }

    public func plotRect(in size: CGSize, valueGutter: CGFloat) -> CGRect {
        CGRect(
            x: valueGutter,
            y: bandHeight,
            width: max(size.width - valueGutter - 2, 1),
            height: max(size.height - bandHeight - dateGutter, 1)
        )
    }

    /// The landscape full-screen variant: vertical space is the scarce thing there, but the
    /// band can only give back a little. The card and the header it replaces are both ~67pt
    /// tall, so trimming below ~72 clips them and the header's date line lands on the top
    /// axis label — which shipped broken at 64 on the weight chart and had to be fixed.
    public func tightened() -> ChartLayout {
        var copy = self
        copy.bandHeight = max(bandHeight - 4, 74)
        return copy
    }

    public init(
        bandHeight: CGFloat = 78,
        dateGutter: CGFloat = 20,
        plotHeight: CGFloat = 212,
        cardHalfHeight: CGFloat = 33,
        cardLineOverlap: CGFloat = 4
    ) {
        self.bandHeight = bandHeight
        self.dateGutter = dateGutter
        self.plotHeight = plotHeight
        self.cardHalfHeight = cardHalfHeight
        self.cardLineOverlap = cardLineOverlap
    }
}

// MARK: - The resting header

/// The band at rest: a caption, a big number, its unit, and a line of context underneath —
/// deliberately the same size and shape as the readout card that replaces it, so scrubbing
/// reads as *that* number following your finger rather than as a second, smaller thing
/// appearing beside it.
public struct ChartSummaryHeader<Accessory: View>: View {
    public let caption: String
    public let value: String
    public let unit: String
    public let subtitle: String
    /// Animates the number when it changes on its own (a settle after a pan). Off during a
    /// scrub, where a numeric transition visibly lags the finger.
    public var animatesValue: Bool = false
    @ViewBuilder public var accessory: () -> Accessory

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(caption)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                ChartValueLine(value: value, unit: unit, animatesValue: animatesValue)
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    // One line, always. Every caller passes a short generated string except
                    // Top Foods, whose subtitle carries a user-supplied food name — and a
                    // second line there would push the band's height out from under it.
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            accessory()
        }
    }

    public init(
        caption: String,
        value: String,
        unit: String,
        subtitle: String,
        animatesValue: Bool = false,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.caption = caption
        self.value = value
        self.unit = unit
        self.subtitle = subtitle
        self.animatesValue = animatesValue
        self.accessory = accessory
    }
}

extension ChartSummaryHeader where Accessory == EmptyView {
    public init(caption: String, value: String, unit: String, subtitle: String, animatesValue: Bool = false) {
        self.init(
            caption: caption, value: value, unit: unit,
            subtitle: subtitle, animatesValue: animatesValue,
            accessory: { EmptyView() }
        )
    }
}

/// The number and its unit at header scale. 28pt bold monospaced digits: the thing being
/// interrogated should be the largest thing on screen.
public struct ChartValueLine: View {
    public let value: String
    public let unit: String
    public var animatesValue: Bool = false

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .modifier(ChartNumberFont(size: 28, weight: .bold, monospacedDigit: true))
                .foregroundStyle(.primary)
                .modifier(ChartNumericTransition(enabled: animatesValue))
                // #3217 — the roll needs a transaction; a series loaded from an `onChange`
                // (the carb sheet's Total/Net flip) arrives without one.
                .animation(animatesValue ? .snappy : nil, value: value)
            if !unit.isEmpty {
                Text(unit)
                    .modifier(ChartNumberFont(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
    }

    public init(
        value: String,
        unit: String,
        animatesValue: Bool = false
    ) {
        self.value = value
        self.unit = unit
        self.animatesValue = animatesValue
    }
}

private struct ChartNumericTransition: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        // One branch, so a morph ending (#3217 turns this on only while one glides) doesn't
        // swap the text's identity under the figure it just rolled.
        content.contentTransition(enabled ? .numericText() : .identity)
    }
}

// MARK: - The readout

/// The card that rides the scrub, and the line that ties it to the datum underneath.
///
/// The card tracks x but clamps to the container, so it slides flush to either edge instead
/// of hanging off — measured from its own laid-out width rather than a guessed half-width,
/// which is what lets the connector stay under it at the edges.
public struct ChartCallout<Content: View>: View {
    /// Where the datum sits, in the chart's own coordinates.
    public let x: CGFloat
    /// Where the connector should stop — the top of a bar, or the plot's bottom for a line.
    public let anchorY: CGFloat
    public let opacity: Double
    public let layout: ChartLayout
    public let containerWidth: CGFloat
    @ViewBuilder public let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    /// Measured once laid out, so the card can slide all the way to either edge.
    @State private var cardWidth: CGFloat = 0

    public var body: some View {
        let lineTop = layout.cardCentreY + layout.cardHalfHeight - layout.cardLineOverlap
        let lineHeight = max(anchorY - lineTop, 0)

        ZStack(alignment: .topLeading) {
            // One stroke from under the card down to the datum, so the eye never has to work
            // out which reading the number belongs to.
            Rectangle()
                .fill(Color.primary.opacity(0.35))
                .frame(width: 1.5, height: lineHeight)
                .position(x: x, y: lineTop + lineHeight / 2)

            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        // A solid raised surface in both schemes — a material would take the
                        // chart's colour through it and stop reading as a card.
                        .fill(colorScheme == .dark ? Color(.tertiarySystemBackground) : Color(.systemBackground))
                        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                )
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { _, newWidth in
                    cardWidth = newWidth
                }
                .position(x: clampedX, y: layout.cardCentreY)
        }
        .opacity(opacity)
        // Neither may swallow the scrub that raised them.
        .allowsHitTesting(false)
    }

    private var clampedX: CGFloat {
        let half = cardWidth > 0 ? cardWidth / 2 : 60
        guard containerWidth > half * 2 else { return x }
        return min(max(x, half), containerWidth - half)
    }

    public init(
        x: CGFloat,
        anchorY: CGFloat,
        opacity: Double,
        layout: ChartLayout,
        containerWidth: CGFloat,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.x = x
        self.anchorY = anchorY
        self.opacity = opacity
        self.layout = layout
        self.containerWidth = containerWidth
        self.content = content
    }
}

/// The standard card contents: the value at header scale with the datum's own label under
/// it. No `.contentTransition` on either line — during a scrub these change once per datum,
/// and a numeric transition visibly lags the finger.
public struct ChartCalloutCard: View {
    public let value: String
    public let unit: String
    public let subtitle: String

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ChartValueLine(value: value, unit: unit)
            Text(subtitle)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    public init(
        value: String,
        unit: String,
        subtitle: String
    ) {
        self.value = value
        self.unit = unit
        self.subtitle = subtitle
    }
}

// MARK: - Range pills

/// How the preset zoom control is drawn.
public enum ChartRangePickerStyle {
    /// A row of separate capsules, the selected one filled with the chart's tint — the one
    /// place in this chrome the accent is right, because there it is showing state rather
    /// than offering an action. The default, and what the weight and workout charts wear.
    case pills
    /// A stock `UISegmentedControl`. Used where a segmented control already sits on the same
    /// screen and two different-looking pickers would read as two different controls — the
    /// nutrient sheet, where TOP FOODS' own picker is segmented (#2690).
    case segmented
}

/// The preset zoom control. Both styles drive the same thing — they read `viewport.preset` and
/// call `viewport.apply(_:)`, which brings the haptic and the glide with it.
public struct ChartRangePicker<Series: ChartSeries>: View {
    public let viewport: ChartViewport<Series>
    public let tint: Color
    public var style: ChartRangePickerStyle = .pills

    public var body: some View {
        switch style {
        case .pills:      ChartRangePills(viewport: viewport, tint: tint)
        case .segmented:  ChartRangeSegments(viewport: viewport, tint: tint)
        }
    }

    public init(
        viewport: ChartViewport<Series>,
        tint: Color,
        style: ChartRangePickerStyle = .pills
    ) {
        self.viewport = viewport
        self.tint = tint
        self.style = style
    }
}

/// The capsule row. Reads `viewport.preset` directly in `body`, which is where Observation
/// registers the dependency, and acts through plain `Button`s.
private struct ChartRangePills<Series: ChartSeries>: View {
    let viewport: ChartViewport<Series>
    let tint: Color

    var body: some View {
        let selected = viewport.preset
        HStack(spacing: 6) {
            ForEach(viewport.availableRanges) { choice in
                let isSelected = selected == choice
                Button {
                    viewport.apply(choice)
                } label: {
                    Text(choice.label)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary.opacity(0.5))
                            )
                        )
                }
                .buttonStyle(.plain)
                .animation(.snappy(duration: 0.2), value: isSelected)
                .chartTapTarget("range.\(choice.label)")
            }
        }
    }
}

/// The stock segmented control, over a REAL `@State` selection mirrored to the viewport in
/// both directions.
///
/// Not a computed `Binding` straight onto `viewport.preset`, for two independent reasons — both
/// of which this codebase has already been bitten by:
///
/// 1. A `Picker` over a computed binding silently drops the setter (see `ChartScaleMenu`, which
///    is plain Buttons for exactly this). A segmented control that shows the right thing and
///    does nothing when tapped is worse than one that looks wrong.
/// 2. A read that only happens inside a getter closure never registers with Observation, which
///    tracks reads made while a body is being evaluated. `viewport.preset` is therefore read
///    HERE, in `body`, so a pinch clearing the preset actually clears the highlight.
///
/// The two `onChange`s can't loop: each guards on the value it is about to write already being
/// the value it would write.
private struct ChartRangeSegments<Series: ChartSeries>: View {
    let viewport: ChartViewport<Series>
    let tint: Color

    /// An Optional selection is the honest model: `preset` goes nil the moment a pinch lands
    /// between two presets, and a segmented control with no matching tag simply shows no
    /// highlight.
    @State private var selection: ChartRange?

    var body: some View {
        let preset = viewport.preset
        Picker("Range", selection: $selection) {
            ForEach(viewport.availableRanges) { choice in
                Text(choice.label).tag(choice as ChartRange?)
            }
        }
        .pickerStyle(.segmented)
        // Carried for source compatibility with `.pills`; a segmented control draws its
        // indicator in the system fill, exactly as TOP FOODS' picker does.
        .tint(tint)
        .onChange(of: selection) { _, new in
            guard let new, new != viewport.preset else { return }
            viewport.apply(new)
        }
        .onChange(of: preset, initial: true) { _, new in
            guard selection != new else { return }
            selection = new
        }
    }
}
