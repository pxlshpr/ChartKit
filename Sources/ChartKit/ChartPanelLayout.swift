import SwiftUI

// MARK: - A chart and its panel (#3280)
//
// The full history sheet is a chart over a list of the days it draws; the meal spread's full
// view had the chart alone. Upright, a chart above a list is the right shape. Sideways there is
// no height for two things stacked, and until #3280 the history sheet answered by dropping the
// list — rotating WAS the full-screen affordance — which threw away half the screen's content
// to gain the width.
//
// Since #3280 the two halves stand SIDE BY SIDE sideways, the diary's own landscape grammar
// (#3275: the dashboard leading, the log trailing; #3276: the picker's controls beside its
// list): the chart in a card on the leading side, the panel in a card of its own trailing, and a
// bar button (`ChartPanelToggle`) that hides the panel to give the chart the whole width and
// shows it again — SwiftUI's `.inspector` paradigm, laid out by hand because `.inspector` on an
// iPhone is a sheet, not a column, and the width class it keys on differs between a Max (regular
// wide sideways) and every other phone (compact). Compact HEIGHT is the rule here, as it is for
// the picker's column and the diary's panel sheets (§23, §24).
//
// Both cards wear the status sheet's own card surface (`SurfaceTheme.adaptiveCell`, corner 15,
// the Meal Spread card's padding) on the flow's themed gradient — which is also the answer to
// the history chart's background: it used to sit bare on the page, and the meal spread's full
// view on a flat `systemGroupedBackground` that no other nutrient screen uses.
//
// Since ChartKit (#3919) the fill is the caller's: `chartCardSurface(_:)` and
// `chartPanelCardSurface(_:)` take it, because the themed surface is NutriKit's. NutriKit keeps
// `chartCard()` / `chartPanelCard()` (and its remembered-panel keys) as one-line wrappers in
// NutriKitCore that pass `SurfaceTheme.adaptiveCell`, read in body so theme changes still redraw.

/// The two halves of a chart screen: upright the chart above its panel, sideways beside it with
/// the panel on the trailing side, hidden or shown by `panelShown`.
public struct ChartWithPanel<Chart: View, Panel: View>: View {
    /// Whether the halves stand side by side — an iPhone turned sideways (compact height).
    public let isSideways: Bool
    /// Whether the panel is up while sideways. Upright the panel is always shown.
    @Binding public var panelShown: Bool
    /// The panel's width sideways. Fixed, not a share (#3276's rule): a share of a mini's
    /// ~640 pt would starve a list whose rows carry a date, a bar and a reading, and the chart
    /// keeps the rest — ≈ 330 pt on a mini, ≈ 440 on a Max, both wider than the upright card's
    /// plot, or the whole width with the panel put away.
    public var panelWidth: CGFloat = ChartPanelLayout.panelWidth
    @ViewBuilder public let chart: () -> Chart
    @ViewBuilder public let panel: () -> Panel

    public var body: some View {
        if isSideways {
            HStack(spacing: ChartPanelLayout.gap) {
                chart()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if panelShown {
                    panel()
                        .frame(width: panelWidth)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.32), value: panelShown)
            // #3296 — no scroll bars in a split (`SidewaysSplit`): the panel's list shows none.
            .scrollIndicators(.hidden)
        } else {
            VStack(spacing: ChartPanelLayout.gap) {
                chart()
                panel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    public init(
        isSideways: Bool,
        panelShown: Binding<Bool>,
        panelWidth: CGFloat = ChartPanelLayout.panelWidth,
        @ViewBuilder chart: @escaping () -> Chart,
        @ViewBuilder panel: @escaping () -> Panel
    ) {
        self.isSideways = isSideways
        self._panelShown = panelShown
        self.panelWidth = panelWidth
        self.chart = chart
        self.panel = panel
    }
}

/// The bar button that hides and shows the panel sideways.
public struct ChartPanelToggle: View {
    @Binding public var isOn: Bool

    public var body: some View {
        Button {
            ChartHooks.impact(.soft)
            isOn.toggle()
        } label: {
            // The trailing half of the screen, filled while the panel is up; the same glyph
            // outlined when it is away. (`sidebar.trailing` has no filled variant.)
            Image(systemName: isOn ? "rectangle.trailinghalf.inset.filled" : "sidebar.trailing")
                .font(.subheadline.weight(.semibold))
        }
        // Label ink, not the accent — chrome for getting around the screen (`ChartScaleMenu`).
        .foregroundStyle(Color(.label))
        .accessibilityLabel(isOn ? "Hide list" : "Show list")
    }

    public init(
        isOn: Binding<Bool>
    ) {
        self._isOn = isOn
    }
}

public enum ChartPanelLayout {
    /// The page's margins around the two cards, and the gap between them: the status sheet's
    /// 20 pt gutter and the 12 pt its content keeps from the bar.
    public static let margin: CGFloat = 20
    public static let gap: CGFloat = 12
    public static let topInset: CGFloat = 12
    public static let panelWidth: CGFloat = 300
    /// The cards' corner — the status sheet's cards (`NutrientSpreadChartCell`).
    public static let cornerRadius: CGFloat = 15
}

extension View {
    /// The chart's card: the Meal Spread card's padding on `fill` — NutriKit's status sheet
    /// passes its themed cell surface; another app, e.g. `.secondarySystemGroupedBackground`.
    public func chartCardSurface<Fill: ShapeStyle>(_ fill: Fill) -> some View {
        padding(.horizontal, 17)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: ChartPanelLayout.cornerRadius)
                    .fill(fill)
            )
    }

    /// The panel's card: the same corner on `fill`, the content clipped to its corners because a
    /// list scrolls in it.
    public func chartPanelCardSurface<Fill: ShapeStyle>(_ fill: Fill) -> some View {
        background(
            RoundedRectangle(cornerRadius: ChartPanelLayout.cornerRadius)
                .fill(fill)
        )
        .clipShape(RoundedRectangle(cornerRadius: ChartPanelLayout.cornerRadius))
    }
}
