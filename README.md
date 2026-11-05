# ChartKit

NutriKit's custom chart engine (#2682) as a package of its own (#3919), shared by **NutriKit**,
**NK Insights** and **Overload**. Zoomable, pannable time-series charts drawn in a SwiftUI
`Canvas`, with UIKit gestures that coexist with a scrolling list, momentum and rubber-banding,
preset ranges, an eased value axis, a press-and-hold readout and a full-screen presentation.

- iOS 26+, UIKit underneath (CADisplayLink, gesture recognisers), so iOS only.
- `swift-tools-version: 5.10` (Swift 5 language mode, like NutriKit's packages). The value types
  are `Sendable`, so Swift 6 apps with strict concurrency use it as is.
- Extracted from NutriKit's `NutriKitCore/Views/Charts` at `385dfbe23`. What stayed in NutriKit:
  `WeightOutlookSeries`, the remembered panel keys and the themed `chartCard()` /
  `chartPanelCard()` wrappers.

## How it works

- **Data** is structure-of-arrays of `Double` seconds since the reference date
  (`Date.timeIntervalSinceReferenceDate`), ascending, already in display units, built once per
  data change. A frame binary-searches the visible window and decimates it to at most one column
  per point of plot width, so its cost scales with the plot, not the history.
- **`ChartViewport<Series>`** (`@MainActor @Observable`) holds the window, the eased value axis,
  the selection and the callout fade. One `ChartTicker` (a display link that runs only while
  something moves) drives momentum, spring-back, preset glides, the axis, the intro and morphs.
- **`ChartPlot`** reads `viewport.frame` in `body`, passes plain values into a `Canvas` draw
  closure you write, and lays a SwiftUI "band" (header, callout) over the plot.

## Public API in brief

| Area | Types |
|---|---|
| Data | `ChartSeries` (protocol), `ChartLineSeries` (x, value, optional trend), `ChartBarSeries` (5 calendar LODs, `.build(samples:aggregate:)`), `ChartAggregate`, `ChartBucket`, `ChartMetrics.day`, `[Double].chartLowerBound(_:)` |
| Viewport | `ChartViewport<Series>`, `ChartViewportConfiguration` (`.line`, `.bars`), `ChartRange` (presets and ladders), `ChartFrame`, `ChartTransform` |
| Plot | `ChartPlot` (canvas + axis labels + band + gestures), `GraphicsContext.drawChartGrid`, `ChartAxis` (ticks, gutters, formatters), `ChartLayout` |
| Drawing | `ChartDecimator`, `ChartColumn`, `ChartPath` (monotone cubic, polyline), `ChartBarGeometry`, `ChartBars` |
| Readout | `ChartSummaryHeader`, `ChartValueLine`, `ChartCallout`, `ChartCalloutCard`, `ChartRangePicker` (`.pills` / `.segmented`) |
| Full screen | `.chartFullScreenChrome(title:viewport:isLandscape:onClose:)`, `ChartScaleMenu`, `ChartCloseButton`, `ChartPresentation` |
| Chart + panel | `ChartWithPanel`, `ChartPanelToggle`, `ChartPanelLayout`, `.chartCardSurface(_:)`, `.chartPanelCardSurface(_:)` (you pass the fill) |
| Legend | `LegendLineSwatch` |
| Host hooks | `ChartHooks` (below) |

Range presets: `.week`, `.twoWeeks`, `.month`, `.threeMonths`, `.sixMonths`, `.year`,
`.twoYears`, `.all`. Ladders: `ChartRange.standard` (1M 3M 6M 1Y All, the default), `.daily`
(1W 1M 3M 6M 1Y All) and `.longHistory` (3M 6M 1Y 2Y All). `twoYears` and `longHistory` are
opt-in only; no default uses them. `availableRanges` hides any preset at least as long as the
history.

A minimal line chart:

```swift
@State private var viewport = ChartViewport<ChartLineSeries>(
    configuration: ChartViewportConfiguration(ranges: ChartRange.longHistory, defaultRange: .year)
)

ChartPlot(viewport: viewport, layout: ChartLayout(), valueGutter: 32, valueLabel: { "\(Int($0))" },
          draw: { context, frame, transform in
              context.drawChartGrid(frame: frame, transform: transform)
              // binary-search frame.visibleRange, decimate, stroke a ChartPath…
          },
          band: { frame, transform, size in /* header, ChartCallout */ })
    .onChange(of: points, initial: true) { _, new in viewport.load(ChartLineSeries(xs: …, values: …)) }
```

`load(_:)` ignores an equal series and keeps a window the user framed. Wrap a `ChartLineSeries`
in your own `ChartSeries` struct to carry per-datum facts for the readout or markers.

## Hooks: what a host app plugs in

Every hook is a static on `@MainActor public enum ChartHooks` with a plain default, so an app that
installs nothing gets UIKit haptics, the system number face and no orientation handling.

| Hook | Default | Used by |
|---|---|---|
| `impact: (UIImpactFeedbackGenerator.FeedbackStyle) -> Void` | a `UIImpactFeedbackGenerator` | preset applied, tap-to-open, ✕, panel toggle |
| `selection: () -> Void` | a `UISelectionFeedbackGenerator` | a scrub landing on a new datum |
| `numberFont: ((AnyView, CGFloat, Font.Weight, Bool) -> AnyView)?` | nil: `.system(size:weight:)` | `ChartValueLine`'s number and unit |
| `fullScreenAppeared` / `fullScreenDisappeared: () -> Void` | no-ops | `chartFullScreenChrome` (e.g. an orientation lock) |
| `tapTargetFrame: ((String, CGRect) -> Void)?` *(DEBUG only)* | nil | range pills (`"range.<label>"`) |
| `plotRectChanged: ((ObjectIdentifier, CGRect) -> Void)?` *(DEBUG only)* | nil | `ChartPlot`'s plot rect, keyed by viewport |

Install them once on the main actor, before the first chart draws. In an `App`, a stored-property
bootstrap runs before `body`:

```swift
@main
struct MyApp: App {
    private let _chartHooks: Void = ChartSetup.install()
    var body: some Scene { … }
}

enum ChartSetup {
    @MainActor static func install() {
        ChartHooks.impact = { Haptics.feedback(style: $0) }      // your haptics, honouring your setting
        ChartHooks.selection = { Haptics.selectionFeedback() }
        ChartHooks.numberFont = { view, size, weight, mono in
            AnyView(view.numberFont(size: size, weight: weight, monospacedDigit: mono))
        }
        ChartHooks.fullScreenAppeared = { OrientationLock.shared.acquire() }
        ChartHooks.fullScreenDisappeared = { OrientationLock.shared.release() }
        #if DEBUG
        ChartHooks.tapTargetFrame = { id, frame in … }
        #endif
    }
}
```

The DEBUG hooks exist only in DEBUG builds, so wrap their assignments in `#if DEBUG`.

ChartKit declares nothing public named `Haptics`, `MenuItems`, `numberFont` (as a View method),
`allowsLandscape` or `snippetTapTarget`: NutriKit's own modules declare those, and two imported
modules declaring one name make it ambiguous. Keep it that way.

## Swift 6 apps

- With default `MainActor` isolation, mark your own series, point and builder types
  `nonisolated` so the `Canvas` draw closure and background builders can read them.
- `ChartLineSeries`, `ChartBarSeries`, `ChartRange`, `ChartViewportConfiguration` and
  `ChartFrame` are `Sendable`: `static let` presets and configurations compile, and series can be
  built in a detached task and handed to `viewport.load(_:)` on the main actor.

## Where it's developed, and releasing

The one working copy is `~/Developer/Packages/ChartKit` on each Mac (pxlbook and pxlhome),
tracking `github.com/pxlshpr/ChartKit` (private). Make every change there:

1. Edit and build: `xcodebuild -scheme ChartKit -destination 'generic/platform=iOS Simulator' build`.
2. Commit and push `main`.
3. Tag a release: `git tag 1.0.1 && git push origin 1.0.1` (semver: a breaking API change is a
   new major).
4. Bump consumers:
   - **NutriKit** depends on the URL (`from: "1.0.0"`) in `Packages/Features/Package.swift`, and
     the project's local package reference (`../Packages/ChartKit`) overrides it, so it builds the
     checkout directly and picks changes up at once, like GlassNumPad.
   - **Overload** (`path: ../Packages/ChartKit`) and **Insights** (`path: ../../Packages/ChartKit`
     in `ios/project.yml`) build the checkout by path, so they pick changes up at once too. They
     use a path rather than the URL because pxlhome's Xcode can't fetch the private repo.
   - A later app that depends on tagged releases raises `from:` when it needs the new API, then
     re-resolves (`xcodebuild -resolvePackageDependencies`).
5. Pull the checkout on the other Mac (`git pull --ff-only`), so both machines build the same
   code.

The repo is private, so a consumer that resolves it by URL needs GitHub credentials in that
Mac's Xcode (or the ssh URL). The local-checkout consumers above don't fetch it.
