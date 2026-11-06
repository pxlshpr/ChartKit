# Shipyard

The pxlshpr apps' shared UI components: where the things they ship get built (pxlshpr, the pixel
shipper). One package for **NutriKit**, **NK Insights** and **Overload**, `import Shipyard`.

| Family | What | Since |
|---|---|---|
| **Charts** | NutriKit's chart engine: zoomable, pannable time-series charts in a SwiftUI `Canvas`, with UIKit gestures that coexist with a scrolling list, momentum and rubber-banding, preset ranges, an eased value axis, a press-and-hold readout and a full-screen presentation | 1.0.0 (as ChartKit, #3919) |
| **TimeSlider** | A day's 30-hour timeline: a picked time, an interval with both ends draggable, or NutriKit's live home-card timeline | 2.0.0 (#3950) |
| **EmojiCircle** | A circle of emojis or SF Symbols (a meal's foods, a workout's activities) | 2.0.0 |
| **DestructiveButton** | A tinted-red capsule for delete, remove, reset | 2.0.0 (from PxlKit) |

- iOS 26+, UIKit underneath (CADisplayLink, gesture recognisers), so iOS only.
- `swift-tools-version: 5.10` (Swift 5 language mode, like NutriKit's packages). The value types
  are `Sendable`, so Swift 6 apps with strict concurrency use it as is.
- What a host plugs in (haptics, its number face, colours) are static hooks with plain defaults:
  `ChartHooks` for the charts, `TimeSliderHooks` for the slider. Static rather than environment
  values because NutriKit hosts some of these in views that don't inherit a SwiftUI environment
  (a UIKit cell, a hand-passed diary host, UIKit-presented sheets).

History: this was **ChartKit** (1.x), the chart engine extracted from NutriKit in #3919. In #3950
it became Shipyard (2.0.0): the GitHub repo was renamed, so `github.com/pxlshpr/ChartKit` still
redirects here and the 1.x tags still resolve; the TimeSlider moved in from NutriKit's `UI`
package with Overload's interval mode (#3948); and **PxlKit** ("the pxlshpr design system", which
held only `DestructiveButton`) was folded in and archived.

## Charts

Extracted from NutriKit's `NutriKitCore/Views/Charts` at `385dfbe23`. What stayed in NutriKit:
`WeightOutlookSeries`, the remembered panel keys and the themed `chartCard()` /
`chartPanelCard()` wrappers.

### How it works

- **Data** is structure-of-arrays of `Double` seconds since the reference date
  (`Date.timeIntervalSinceReferenceDate`), ascending, already in display units, built once per
  data change. A frame binary-searches the visible window and decimates it to at most one column
  per point of plot width, so its cost scales with the plot, not the history.
- **`ChartViewport<Series>`** (`@MainActor @Observable`) holds the window, the eased value axis,
  the selection and the callout fade. One `ChartTicker` (a display link that runs only while
  something moves) drives momentum, spring-back, preset glides, the axis, the intro and morphs.
- **`ChartPlot`** reads `viewport.frame` in `body`, passes plain values into a `Canvas` draw
  closure you write, and lays a SwiftUI "band" (header, callout) over the plot.

### Public API in brief

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

### Chart hooks

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

Shipyard declares nothing public named `Haptics`, `MenuItems`, `numberFont` (as a View method),
`allowsLandscape` or `snippetTapTarget`: NutriKit's own modules declare those, and two imported
modules declaring one name make it ambiguous. Keep it that way.

### Swift 6 apps

- With default `MainActor` isolation, mark your own series, point and builder types
  `nonisolated` so the `Canvas` draw closure and background builders can read them.
- `ChartLineSeries`, `ChartBarSeries`, `ChartRange`, `ChartViewportConfiguration` and
  `ChartFrame` are `Sendable`: `static let` presets and configurations compile, and series can be
  built in a detached task and handed to `viewport.load(_:)` on the main actor.

## TimeSlider

A pill over a needle over a bar of quarter-hours. The day is **30 hours**, NutriKit's model: from
the day's local midnight through 6 AM of the next calendar day (120 quarter-hour slots), so a meal
or a session at 00:45 on Nov 5 belongs to (and sits on) Nov 4's evening. A time past midnight
reads "Past Midnight"; the axis reads 12a, 1a… past 24h, never 24, 25.

A drag moves the needle, and holding still zooms in (1× → 3× → 15×: 15, 5, then 1-minute steps);
a tap moves it to where it lands. The pan is UIKit's, begun only by a clearly horizontal move, so a
vertical swipe still reaches a sheet's swipe-to-dismiss or a scroll view. The wheel (a tap on the
pill) picks a clock time and places it on the 30 hours at whichever end lies nearer the time being
edited, so 11 PM rolled on to 1 AM is past midnight.

Three shapes, picked by the init:

```swift
// One time on the day (Overload's workout start). The pill opens a wheel; markers are drawn filled.
TimeSlider(day: day, time: $start, markers: otherStarts, allowedRange: dayStart...now)

// An interval: both ends draggable, the stretch between them coloured, the length between the pills.
// A drag or tap takes the nearer end; the start carries the end at its length, the end alone resizes.
TimeSlider(day: day, start: $start, end: $end, markers: otherStarts,
           allowedRange: allowedRange, minimumDuration: 5 * 60, accessibilityName: "Workout time")

// NutriKit's: a sheet's picker, or (liveMode) the home card's live timeline with meal and
// workout bubbles, a drag or long press that places a new meal, and drag-state bindings the
// host keeps across view recreations.
TimeSlider(date: date, existingTimeSlots: slots, currentTime: $time, currentTimeSlot: 0,
           allowedTimeRange: range, mealBubbles: meals, workoutBubbles: workouts,
           style: .compact, precisePicker: $isPickingPreciseTime)
```

- `style`: `.standard` (a 50 pt bar of one stripe per quarter-hour, drawn in one `Canvas` with
  every stripe on whole device pixels, so there's no moiré) or `.compact` (a 30 pt continuous
  track with a tick at each marker).
- `options` (`TimeSliderOptions`, all on for the `day:` inits, off for `date:`):
  `.pastMidnightLabel`, `.rollingDigits` (the digits roll; the pill trails the needle on a heavy
  spring), `.wholeAreaTouches`.
- `precisePicker` (the `date:` init): the host's popover state for the wheel; nil keeps a pill
  tap a bar tap. The `day:` inits keep their own.
- VoiceOver: one adjustable element (a quarter-hour per swipe, the wheel on a double-tap); an
  interval adds "Longer" / "Shorter".

### TimeSlider hooks

`@MainActor public enum TimeSliderHooks`, installed once before the first slider draws:

| Hook | Default | NutriKit installs |
|---|---|---|
| `impact`, `selection` | UIKit generators | Essentials' `Haptics` (honours the haptics setting) |
| `numberFont: ((AnyView, Font.TextStyle, Font.Weight, Bool) -> AnyView)?` | nil: the system face at the text style | App's `numberFont`, the Appearance number face |
| `pillColors: (TimeSliderPillContext, Color, ColorScheme) -> TimeSliderPillColors` | white on a flat accent pill, accent needle | its `SecondaryControlStyle` variants (#2702), sheet and live |

The accent is the slider's `accentColor:` or the app's `Color.accentColor`. Overload sets only
`pillColors` (white on its `AccentFill`, which keeps white digits legible in dark mode).

The arithmetic (slots, the clamp, the wheel's placement, the interval's carry and squeeze) is in
`TimelineMath.swift`, apart from the view, and tested: `Tests/ShipyardTests`.

## EmojiCircle and DestructiveButton

```swift
EmojiCircle(emojis: ["🥚", "🥯", "☕️"], size: 28, fillMaterial: .ultraThinMaterial)
EmojiCircle(symbols: ["figure.run", "dumbbell.fill"], size: 24)
DestructiveButton("Delete Meal") { deleteMeal() }
DestructiveButton("Reset", systemImage: "arrow.counterclockwise") { reset() }
```

## Where it's developed, and releasing

The one working copy is `~/Developer/Packages/Shipyard` on each Mac (pxlbook and pxlhome),
tracking `github.com/pxlshpr/Shipyard` (public). Make every change there:

1. Edit and build: `xcodebuild -scheme Shipyard -destination 'generic/platform=iOS Simulator' build`.
2. Test on a simulator (pxlhome; there are none on pxlbook to spare):
   `xcodebuild -scheme Shipyard -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' test`.
3. Commit and push `main`.
4. Tag a release: `git tag 2.0.1 && git push origin 2.0.1` (semver: a breaking API change is a
   new major).
5. Bump consumers:
   - **NutriKit** depends on the URL (`from: "2.0.0"`) in `Packages/Features/Package.swift` and
     `Packages/UI/Package.swift`, and the project's local package reference
     (`../Packages/Shipyard`) overrides it, so it builds the checkout directly and picks changes
     up at once, like GlassNumPad.
   - **Overload** (`path: ../Packages/Shipyard`) and **Insights** (`path: ../../Packages/Shipyard`
     in `ios/project.yml`) build the checkout by path, so they pick changes up at once too.
   - A later app that depends on tagged releases raises `from:` when it needs the new API, then
     re-resolves (`xcodebuild -resolvePackageDependencies`).
6. Pull the checkout on the other Mac (`git pull --ff-only`), so both machines build the same
   code.

Any app can also depend on it by URL with no credentials:
`.package(url: "https://github.com/pxlshpr/Shipyard.git", from: "2.0.0")`.

A clone of an app made before #3950 still names `../Packages/ChartKit` (and NutriKit's,
`../Packages/PxlKit`). Those checkouts stay on both Macs at their last ChartKit / PxlKit commit
until every such branch has merged, then can be deleted. `~/Developer/Packages/ChartKit` is
frozen: its `origin` points at itself, so a script's `git pull origin main` (an old branch's
`tools/duo_probe/remote-sim-build.sh`) is a no-op instead of pulling in Shipyard's renamed
module.
