import SwiftUI

/// The chrome every full-screen chart wears (#2682, extracted from #2673's weight chart).
///
/// Full screen the range pills come off: five capsules across the top is a lot of chart to
/// spend on a control the nav bar can hold as one word. The scale moves into a menu beside
/// the back button, and that menu's label is a *live readout of the zoom* rather than a
/// stale selection — a preset says its own name, a pinch says roughly what is on screen and
/// keeps saying it as the fingers move.

// MARK: - Scale menu

public struct ChartScaleMenu<Series: ChartSeries>: View {
    public let viewport: ChartViewport<Series>

    public var body: some View {
        Menu {
            ChartMenuItems {
                ForEach(viewport.availableRanges) { choice in
                    Button {
                        viewport.apply(choice)
                    } label: {
                        // Plain buttons carrying their own checkmark, not a `Picker`: a Picker
                        // over a computed binding silently drops the setter, and the selection
                        // here is nil the moment the user pinches.
                        if viewport.preset == choice {
                            Label(choice.menuLabel, systemImage: "checkmark")
                        } else {
                            Text(choice.menuLabel)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(viewport.windowLabel)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            // Label ink, not the accent: these are chrome for getting around the screen, and
            // the accent belongs to the chart. Tinting them makes them compete with the
            // plotted data for the same "this is the important colour" signal.
            .foregroundStyle(Color(.label))
            // The label changes width as the zoom changes ("1 year" → "7 weeks"); without
            // this the toolbar re-lays-out on every frame of a pinch.
            .animation(nil, value: viewport.windowLabel)
        }
    }

    public init(
        viewport: ChartViewport<Series>
    ) {
        self.viewport = viewport
    }
}

// MARK: - Close

/// ✕ dismisses the whole flow, not the push. Opening a chart from the dashboard and closing
/// it should return to the dashboard, not one level up in a stack the user was only passing
/// through — so the presenting screen passes its own `dismiss` down as `onClose`.
public struct ChartCloseButton: View {
    public let onClose: () -> Void

    public var body: some View {
        Button {
            ChartHooks.impact(.soft)
            onClose()
        } label: {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel("Close")
        .foregroundStyle(Color(.label))
    }

    public init(
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
    }
}

// MARK: - The screen

/// Everything a pushed full-screen chart needs: the title, the scale menu beside the back
/// button, ✕ at the trailing edge, and landscape.
///
/// The back button stays. `.navigationBarBackButtonHidden(true)` also kills the interactive
/// swipe-back, and ✕ means something different from "back" — both affordances are wanted.
public struct ChartFullScreenChrome<Series: ChartSeries>: ViewModifier {
    public let title: String
    public let viewport: ChartViewport<Series>
    public let isLandscape: Bool
    public let onClose: (() -> Void)?

    public func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ChartScaleMenu(viewport: viewport) }
                if let onClose {
                    ToolbarItem(placement: .topBarTrailing) { ChartCloseButton(onClose: onClose) }
                }
            }
            // The home indicator is the one piece of chrome the plot can safely draw under.
            .ignoresSafeArea(.container, edges: isLandscape ? .bottom : [])
            // The app is portrait everywhere else. This screen is the one that earns
            // landscape: sideways the plot goes from roughly 340pt wide to 850pt, which for a
            // long history is the difference between a smudge and a shape. Without this the
            // rotation silently never happens — iOS never offers landscape at all, so nothing
            // in the view code has any effect. A hook since ChartKit (#3919): NutriKit installs
            // its orientation lock's acquire/release; an app that allows landscape everywhere
            // leaves the no-op defaults.
            .onAppear { ChartHooks.fullScreenAppeared() }
            .onDisappear { ChartHooks.fullScreenDisappeared() }
    }
}

extension View {
    public func chartFullScreenChrome<Series: ChartSeries>(
        title: String,
        viewport: ChartViewport<Series>,
        isLandscape: Bool,
        onClose: (() -> Void)?
    ) -> some View {
        modifier(
            ChartFullScreenChrome(
                title: title,
                viewport: viewport,
                isLandscape: isLandscape,
                onClose: onClose
            )
        )
    }
}

// MARK: - Presentation

/// How a chart is being shown. In a row it takes a fixed height and a tap opens the
/// full-screen version; on that screen it fills whatever it is given, which is what makes
/// rotating to landscape worth doing.
///
/// A mode rather than a second view: everything else is already driven by the plot rect, so
/// it scales for free.
public enum ChartPresentation {
    case card, expanded
}
