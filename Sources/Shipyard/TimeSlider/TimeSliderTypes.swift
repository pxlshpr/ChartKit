import SwiftUI

/// A meal entry rendered as an emoji bubble above the day timeline.
/// The bubble is anchored to its `timeSlot` x-position and pairs an EmojiCircle
/// of the meal's food emojis with a vertical connector down to the bar.
public struct TimelineMealBubble: Equatable, Hashable, Identifiable {
    public let id: String
    public let timeSlot: Int
    public let emojis: [String]
    /// Optional per-emoji tints, matched to `emojis` by index (NutriKit's dominant-macro emoji
    /// tint, #1921). Empty means every emoji renders untinted (full colour).
    public let emojiTints: [Color?]

    public init(id: String, timeSlot: Int, emojis: [String], emojiTints: [Color?] = []) {
        self.id = id
        self.timeSlot = timeSlot
        self.emojis = emojis
        self.emojiTints = emojiTints
    }
}

/// A workout cluster rendered as an SF-Symbol bubble above the day timeline.
/// One bubble per cluster (workouts grouped within a 30-minute buffer).
public struct TimelineWorkoutBubble: Equatable, Hashable, Identifiable {
    public let id: String
    public let timeSlot: Int
    public let systemImageNames: [String]

    public init(id: String, timeSlot: Int, systemImageNames: [String]) {
        self.id = id
        self.timeSlot = timeSlot
        self.systemImageNames = systemImageNames
    }
}

/// How an interactive slider draws its bar (NutriKit #3302). `standard` is the 50 pt bar of one
/// stripe per quarter-hour that the sheet pickers have always worn; `compact` is the diary card's
/// own track instead — a 30 pt continuous bar with a tick where each meal, workout or marker
/// starts — for a picker that shares its surface with other controls (NutriKit's meal actions
/// panel editor). Live mode has only the one look and ignores this.
public enum TimeSliderStyle: Sendable {
    case standard
    case compact
}

/// Overload's additions to the slider's single pill (#3948), each one optional. The `day:` inits
/// take them all by default; NutriKit's `date:` init none, so its pickers read as they always have.
public struct TimeSliderOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// "Past Midnight" beside a time on the next calendar day, the words NutriKit's meal header
    /// uses (#3014). An interval's two pills have no room for them and show a moon instead.
    public static let pastMidnightLabel = TimeSliderOptions(rawValue: 1 << 0)
    /// The pill's digits roll as they change, and its place and width trail the needle on a
    /// heavy spring.
    public static let rollingDigits = TimeSliderOptions(rawValue: 1 << 1)
    /// The whole slider takes taps and drags, its gaps between pill, bar and axis included.
    public static let wholeAreaTouches = TimeSliderOptions(rawValue: 1 << 2)

    public static let all: TimeSliderOptions = [.pastMidnightLabel, .rollingDigits, .wholeAreaTouches]
}

// MARK: - Interval pills

/// Places an interval's start pill, length chip and end pill (in that order): each pill centred
/// over its needle and the chip midway, pushed apart to `gap`, then walked in from both edges
/// (#3948). The needle positions are its animatable data, so under a spring every frame is laid
/// out afresh from the measured sizes: the pieces move as one and can't overlap.
struct IntervalPillsLayout: Layout {
    var startX: CGFloat
    var endX: CGFloat
    var gap: CGFloat
    var edgePadding: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(startX, endX) }
        set { startX = newValue.first; endX = newValue.second }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let xs = Self.centres(
            startX: startX, endX: endX,
            widths: (sizes[0].width, sizes[1].width, sizes[2].width),
            gap: gap, edgePadding: edgePadding, width: bounds.width
        )
        for (subview, x) in zip(subviews, [xs.start, xs.chip, xs.end]) {
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.midY), anchor: .center, proposal: .unspecified)
        }
    }

    /// The three centres, in the row's own x.
    static func centres(
        startX: CGFloat,
        endX: CGFloat,
        widths: (start: CGFloat, chip: CGFloat, end: CGFloat),
        gap: CGFloat,
        edgePadding: CGFloat,
        width: CGFloat
    ) -> (start: CGFloat, chip: CGFloat, end: CGFloat) {
        let sw = widths.start, cw = widths.chip, ew = widths.end
        let mid = (startX + endX) / 2
        var s = min(startX, mid - cw / 2 - gap - sw / 2)
        var c = mid
        var e = max(endX, mid + cw / 2 + gap + ew / 2)
        let left = edgePadding, right = width - edgePadding
        // From the leading edge…
        s = max(s, left + sw / 2)
        c = max(c, s + sw / 2 + gap + cw / 2)
        e = max(e, c + cw / 2 + gap + ew / 2)
        // …then from the trailing one.
        e = min(e, right - ew / 2)
        c = min(c, e - ew / 2 - gap - cw / 2)
        s = min(s, c - cw / 2 - gap - sw / 2)
        return (s, c, e)
    }
}

// MARK: - Accessibility

/// A slider whose pill opens the precise picker is the one control for its time, so VoiceOver
/// reads it as a single adjustable element: the time as its value, a quarter-hour per swipe, and
/// the wheel on a double-tap (NutriKit #3302). An interval also takes "Longer" / "Shorter" for
/// its end (#3948). A slider without a picker (`name` nil) is left as it was.
struct PreciseTimeAccessibility: ViewModifier {
    let name: String?
    let value: String
    let isInterval: Bool
    let step: (AccessibilityAdjustmentDirection) -> Void
    let resize: (AccessibilityAdjustmentDirection) -> Void
    let openPicker: () -> Void

    func body(content: Content) -> some View {
        if let name {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(name)
                .accessibilityValue(value)
                .accessibilityHint(isInterval
                    ? "Swipe up or down to move it a quarter of an hour. Actions make it longer or shorter."
                    : "Swipe up or down to move a quarter of an hour. Double-tap to set an exact time.")
                .accessibilityAdjustableAction(step)
                .accessibilityAction { openPicker() }
                .accessibilityActions {
                    if isInterval {
                        Button("Longer") { resize(.increment) }
                        Button("Shorter") { resize(.decrement) }
                    }
                }
        } else {
            content
        }
    }
}
