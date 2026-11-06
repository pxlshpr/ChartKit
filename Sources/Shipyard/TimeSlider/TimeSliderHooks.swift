import SwiftUI
import UIKit

/// What a host app plugs into `TimeSlider` (#3950), as `ChartHooks` is for the charts.
///
/// The slider came out of NutriKit, where it called NutriKit's haptics (which honour its haptics
/// setting), its Appearance number face and its admin-picked secondary-control dress directly.
/// Those are app concerns, so each is a hook with a plain default: an app that installs nothing
/// gets UIKit haptics, the system face at the text style asked for, and white digits on a flat
/// accent pill over an accent needle.
///
/// Static hooks rather than environment values because NutriKit hosts its live timeline in a
/// UIKit cell, which doesn't inherit a SwiftUI environment. A hook runs inside the slider's
/// `body`, so whatever it reads there (an `@Observable` setting, an `@AppStorage` face in a
/// modifier it returns) still invalidates the slider.
///
/// Install them once, on the main actor, before the first slider draws.
@MainActor
public enum TimeSliderHooks {
    /// A tap's impact: a pill tap, a bar tap, a bubble tap, the zoom stepping in, a long press.
    /// NutriKit: `{ Haptics.feedback(style: $0) }`.
    public static var impact: (UIImpactFeedbackGenerator.FeedbackStyle) -> Void = { style in
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// The tick of a drag landing on a new minute. NutriKit: `{ Haptics.selectionFeedback() }`.
    public static var selection: () -> Void = {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Restyles the slider's numerals (the pills, the axis, the length chip): the view, its text
    /// style, weight and whether its digits are monospaced. Nil: the system face at that text
    /// style. NutriKit:
    /// `{ view, style, weight, mono in AnyView(view.numberFont(style, weight: weight, monospacedDigit: mono)) }`.
    public static var numberFont: ((AnyView, Font.TextStyle, Font.Weight, Bool) -> AnyView)?

    /// How a pill and its needle are dressed, given where the pill is, the accent it would wear
    /// and the colour scheme. Called from `body`, so an observable setting it reads re-renders
    /// the slider when it changes. Default: `TimeSliderPillColors.standard`.
    public static var pillColors: (TimeSliderPillContext, Color, ColorScheme) -> TimeSliderPillColors = { context, accent, _ in
        .standard(context: context, accent: accent)
    }
}

/// Where a pill stands, for `TimeSliderHooks.pillColors`.
public enum TimeSliderPillContext: Equatable, Sendable {
    /// An interactive slider: a sheet's time picker, its single pill or an interval's two.
    case picker
    /// The live timeline's "now" pill (`liveMode`). `isActive` while a drag places a new time or
    /// holds it (the accent handed in is then green, NutriKit's "creating a meal" signal).
    case live(isActive: Bool)
}

/// A pill's dress and the needle hanging off it.
public struct TimeSliderPillColors {
    /// The pill's digits and words.
    public var foreground: Color
    /// The pill's fill.
    public var fill: AnyShapeStyle
    /// A ring round the pill, if it wears one.
    public var stroke: Color?
    public var strokeWidth: CGFloat
    /// The needle from the pill down through the bar.
    public var needle: AnyShapeStyle

    public init(
        foreground: Color,
        fill: AnyShapeStyle,
        stroke: Color? = nil,
        strokeWidth: CGFloat = 1.5,
        needle: AnyShapeStyle
    ) {
        self.foreground = foreground
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.needle = needle
    }

    /// White digits on a flat accent pill over an accent needle.
    public static func standard(context: TimeSliderPillContext, accent: Color) -> TimeSliderPillColors {
        TimeSliderPillColors(
            foreground: .white,
            fill: AnyShapeStyle(accent),
            needle: AnyShapeStyle(accent)
        )
    }
}

// MARK: - Internal

/// The slider's haptics, through the hooks.
@MainActor
enum TimeSliderHaptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) { TimeSliderHooks.impact(style) }
    static func selection() { TimeSliderHooks.selection() }
}

/// The slider's number face: the host's if it installed one, else the system's at the text style.
struct TimeSliderNumberFont: ViewModifier {
    let textStyle: Font.TextStyle
    var weight: Font.Weight = .regular
    var monospacedDigit: Bool = false

    func body(content: Content) -> some View {
        if let hook = TimeSliderHooks.numberFont {
            hook(AnyView(content), textStyle, weight, monospacedDigit)
        } else {
            let font = Font.system(textStyle, weight: weight)
            content.font(monospacedDigit ? font.monospacedDigit() : font)
        }
    }
}

extension View {
    /// Numerals in the host's number face (`TimeSliderHooks.numberFont`).
    func timeSliderNumberFont(_ textStyle: Font.TextStyle, weight: Font.Weight = .regular, monospacedDigit: Bool = false) -> some View {
        modifier(TimeSliderNumberFont(textStyle: textStyle, weight: weight, monospacedDigit: monospacedDigit))
    }

    /// NutriKit's Essentials `readSize`, exactly: a background `GeometryReader` reporting through
    /// a preference, so sizes arrive when they did in NutriKit.
    func timeSliderReadSize(_ onChange: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: TimeSliderSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(TimeSliderSizeKey.self, perform: onChange)
    }

    /// NutriKit's Essentials `cornerRadius(_:corners:)`: clipped to a rect with only some corners
    /// rounded.
    func timeSliderCornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(TimeSliderRoundedCorner(radius: radius, corners: corners))
    }
}

private struct TimeSliderSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {}
}

private struct TimeSliderRoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
