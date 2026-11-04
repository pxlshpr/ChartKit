import SwiftUI
import UIKit

/// What a host app plugs into the chart core (#3919).
///
/// The engine came out of NutriKit, where it called NutriKit's own haptics, number face,
/// orientation lock and scripted-take registries directly. Those are app concerns, so each is a
/// hook here with a plain default: an app that installs nothing gets UIKit haptics, the system
/// number face and no orientation handling — the same behaviour Insights' vendored copy had
/// from its shims.
///
/// Install the hooks once, on the main actor, before the first chart draws: NutriKit does it
/// from a stored-property bootstrap in `NutriKitApp` (`ChartKitBridge.install()`).
///
/// Named `ChartHooks`, not `ChartKit`: a type named like its module breaks `ChartKit.X`
/// qualification. And nothing in this package is public under the names the hosts already use
/// (`Haptics`, `MenuItems`, `numberFont`, `allowsLandscape`, `snippetTapTarget`) — two imported
/// modules declaring the same top-level name make it ambiguous in every file that sees both.
@MainActor
public enum ChartHooks {
    /// A soft tap: a preset applied, the chart tapped open, ✕, the panel toggle.
    /// NutriKit: `{ Haptics.feedback(style: $0) }`, so its haptics setting still applies.
    public static var impact: (UIImpactFeedbackGenerator.FeedbackStyle) -> Void = { style in
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// The tick of a scrub landing on a new datum.
    public static var selection: () -> Void = {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Restyles a header-scale number (`ChartValueLine`): the view, its size, weight and whether
    /// its digits are monospaced. Nil: the system face at that size. NutriKit:
    /// `{ view, size, weight, mono in AnyView(view.numberFont(size: size, weight: weight, monospacedDigit: mono)) }`.
    ///
    /// A static hook rather than an environment value because NutriKit hosts some charts in
    /// views that don't inherit the environment (a hand-passed diary host, UIKit-presented
    /// sheets). The host's own modifier still runs in the tree, so anything it observes
    /// (an `@AppStorage` face setting) still invalidates it.
    public static var numberFont: ((AnyView, CGFloat, Font.Weight, Bool) -> AnyView)?

    /// A full-screen chart (`chartFullScreenChrome`) came on screen / left it. NutriKit is
    /// portrait-only elsewhere and acquires / releases its orientation lock here; an app that
    /// allows landscape everywhere leaves the no-ops.
    public static var fullScreenAppeared: () -> Void = {}
    public static var fullScreenDisappeared: () -> Void = {}

    #if DEBUG
    /// A range pill's frame in global space, by id (`"range.<label>"`) — NutriKit's scripted
    /// takes record it to draw a finger on the pill.
    public static var tapTargetFrame: ((String, CGRect) -> Void)?
    /// A plot's rect in its chart's space, keyed by its viewport — for a take's drawn finger.
    public static var plotRectChanged: ((ObjectIdentifier, CGRect) -> Void)?
    #endif
}

/// `ChartValueLine`'s number face: the host's if it installed one, else the system's.
struct ChartNumberFont: ViewModifier {
    let size: CGFloat
    var weight: Font.Weight = .regular
    var monospacedDigit: Bool = false

    func body(content: Content) -> some View {
        if let hook = ChartHooks.numberFont {
            hook(AnyView(content), size, weight, monospacedDigit)
        } else {
            let font = Font.system(size: size, weight: weight)
            content.font(monospacedDigit ? font.monospacedDigit() : font)
        }
    }
}

/// A menu's items in the label colour rather than the app's tint (NutriKit's Essentials
/// `MenuItems`, #3347). Internal so it can't collide with the host's own.
struct ChartMenuItems<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.tint(.primary)
    }
}

extension View {
    /// Reports this view's frame to `ChartHooks.tapTargetFrame` in DEBUG; nothing in Release.
    /// Internal, in place of NutriKit's `snippetTapTarget(_:)`.
    @ViewBuilder
    func chartTapTarget(_ id: String) -> some View {
        #if DEBUG
        // One view type always, never `if hooked { … } else { self }`: inside a List, a Button
        // with a `.contextMenu` over conditional content segfaulted copying the Button (#3153).
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            ChartHooks.tapTargetFrame?(id, frame)
        }
        #else
        self
        #endif
    }
}
