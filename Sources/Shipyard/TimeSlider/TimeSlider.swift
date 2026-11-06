import SwiftUI

/// A day's timeline: a pill over a needle over a bar of quarter-hours (#3950).
///
/// NutriKit's `TimeSlider` (its home card's live timeline and every sheet's time picker) with
/// Overload's additions (#3948), shared by both apps. The day is 30 hours, NutriKit's model: from
/// the day's local midnight through 6 AM of the next calendar day (`TimelineMath.swift`).
///
/// Three shapes, picked by the init:
/// - **A picked time** (`init(date:existingTimeSlots:currentTime:…)`, NutriKit's sheets; or
///   `init(day:time:…)`): a drag moves the needle; holding still zooms in (1× → 3× → 15×, so 15 →
///   5 → 1-minute steps); a tap moves it to where it lands, and, given a wheel, a tap on the pill
///   opens it for the exact time.
/// - **An interval** (`init(day:start:end:…)`): two needles with the stretch between them coloured
///   on the bar, the pills side by side with the length between them. A drag (or tap) takes the
///   end nearer the finger. The start carries the end with it, so picking a start keeps the
///   length; the end alone changes it. Any "from … to …" on a day can host it.
/// - **Live** (`liveMode: true`, NutriKit's home card): the clock's "now" pill, the day's meal and
///   workout bubbles, and a drag (or, away from today, a long press) that places a new meal.
///
/// What an app plugs in (haptics, its number face, the pill's dress): `TimeSliderHooks`.
public struct TimeSlider: View {

    /// Which end of an interval a drag, tap or wheel is moving.
    typealias Handle = TimelineInterval.Handle

    // MARK: - Inputs

    /// Any time on the diary day.
    let date: Date
    /// The day's local midnight.
    let dayStart: Date
    /// The next calendar day's midnight: a time at or past it reads "Past Midnight".
    let nextMidnight: Date
    /// Slots already taken (NutriKit's meals; Overload's other sessions): drawn filled.
    let existingTimeSlots: [Int]

    /// The single time, or an interval's start.
    @Binding var currentTime: Date
    /// An interval's end (a constant for a single time). A real `@Binding`, as the start is, so
    /// SwiftUI tracks it the same way: as a plain stored Binding, a drag of the end updated the
    /// view through its parent and the pills snapped instead of easing (#3948).
    @Binding var intervalEnd: Date
    let isInterval: Bool
    /// An interval's shortest length, in minutes.
    let minimumMinutes: Double

    let spacing: CGFloat = 0.5
    /// The interactive mode's look; see `TimeSliderStyle`.
    let sliderStyle: TimeSliderStyle
    let barHeight: CGFloat
    let liveBarHeight: CGFloat = 30.0
    let options: TimeSliderOptions

    /// When set, the time pill is a button: a tap on it presents a wheel picker for the exact time
    /// in a popover pinned to the pill, and this is that popover's state (NutriKit #3302). Nil keeps
    /// a tap on the pill a tap on the bar, unless the slider keeps its own wheel (`ownsWheel`).
    let precisePicker: Binding<Bool>?
    /// The slider presents its own wheel (the `day:` inits, and an interval's pills always). A
    /// `day:` init also holds a bar tap inside the allowed range, where NutriKit's hosts clamp.
    let ownsWheel: Bool
    /// What VoiceOver calls the slider; nil leaves it as plain views (NutriKit's pickers without
    /// a wheel).
    let accessibilityName: String?
    /// The DatePicker's own range, as NutriKit's wheel always had it; nil for the `day:` inits,
    /// whose wheel picks any clock time and leaves the range to `placeOnTimeline`.
    let wheelRange: ClosedRange<Date>?

    /// The range a time may be picked in.
    let allowedTimeRange: ClosedRange<Date>
    /// `allowedTimeRange` as slots, which a single time's drag and the bar's shading go by.
    let allowedTimeSlotsRange: ClosedRange<Int>
    /// `allowedTimeRange` in minutes, held inside the 30 hours: what an interval goes by.
    let allowedMinutes: ClosedRange<Double>

    /// When true, the slider shows the current time and auto-updates
    let liveMode: Bool

    /// Whether this slider is showing today (shows NOW indicator)
    /// When false and in liveMode, hides the button and connector until dragging
    let isToday: Bool

    /// Custom accent color (live mode's, a picker's tint)
    let accentColorOverride: Color?

    /// Called when drag state changes in live mode (isDragging, targetTimeSlot, targetTime)
    let onDragStateChanged: ((Bool, Int?, Date?) -> Void)?

    /// Called when user releases drag on a valid empty slot - triggers meal creation
    let onCreateMealAt: ((Date) -> Void)?

    /// Called when user drags onto an existing meal's time slot (interactive mode)
    let onExistingSlotDragged: ((Int) -> Void)?

    /// Called when a live drag ends in a quick flick: the day before (a flick right) or after
    /// (left). NutriKit's home card turns the diary's page to it.
    let onQuickFlickToDay: ((Date) -> Void)?

    /// Meal bubbles to display above the timeline — the home card's tappable row in live
    /// mode, and a read-only row over the bar in the sheet pickers (NutriKit #3160)
    let mealBubbles: [TimelineMealBubble]

    /// Workout bubbles to display above the timeline, in both modes (NutriKit #3160)
    let workoutBubbles: [TimelineWorkoutBubble]

    /// Called when a meal bubble is tapped — provides the meal id
    let onMealBubbleTapped: ((String) -> Void)?

    /// Called when a workout bubble is tapped — provides the workout cluster id
    let onWorkoutBubbleTapped: ((String) -> Void)?

    /// When true, the slider holds its position after drag ends (e.g., while a sheet is shown)
    @Binding var isHoldingPosition: Bool

    // MARK: - Drag State Bindings (from parent store to persist across view recreations)

    /// Whether the user is currently dragging the slider (live mode)
    @Binding var isDragging: Bool

    /// The time slot the user is dragging to
    @Binding var dragTimeSlot: Int?

    /// The time slot being held while sheet is presented
    @Binding var heldTimeSlot: Int?

    /// Animated visual position for smooth transitions
    @Binding var animatedSlotPosition: CGFloat?

    /// Whether the slider is animating back to live position
    @Binding var isAnimatingReset: Bool

    /// Position during reset animation - this IS observed in the store
    /// so SwiftUI tracks changes and animates properly
    @Binding var resetAnimationPosition: CGFloat?

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.displayScale) var displayScale

    // MARK: - Layout state

    @State var sliderWidth: CGFloat = 0
    @State var buttonSize: CGSize = .zero
    @State var markersRowHeight: CGFloat = 0
    /// Height of the slider (live: of the pan view) — used to detect when a touch leaves it
    @State var panViewHeight: CGFloat = 0

    // MARK: - Zoom state
    /// Current zoom level: 1.0 (15-min), 3.0 (5-min), 15.0 (1-min)
    @State var zoomLevel: CGFloat = 1.0
    /// Real-world minute at the center of the visible range
    @State var zoomCenterMinute: Double = TimelineSlots.centreMinute
    /// Last known finger x during drag (for zoom timer context)
    @State var lastFingerX: CGFloat = 0
    /// The hold-still timer: cancelled by every move, it zooms in a step after a second.
    @State var zoomTask: Task<Void, Never>?

    // MARK: - Picker state
    /// Tracks whether the interactive drag gesture has been locked in as horizontal
    @State var isInteractiveDragging: Bool = false
    /// The last minute a drag reported, so a haptic ticks once per step, not per frame.
    @State var lastReportedMinute: Int = -1
    /// The slider's own wheel (`ownsWheel`), and the end it is open for.
    @State var showsOwnWheel = false
    @State var wheelHandle: Handle = .start
    /// The end a drag or tap is moving.
    @State var activeHandle: Handle = .start
    /// The interval's length when a move began: the start carries the end at this length, and
    /// takes it back after being squeezed against the range's end.
    @State var carriedMinutes: Double = 0
    /// The needles' x as the interval's pills see it: trailing the real needles on `pillSpring`.
    @State var shownNeedleX: (start: CGFloat, end: CGFloat) = (0, 0)

    // MARK: - Live state
    /// Track the start position for delta-based slot calculation
    @State var panStartSlot: Int?
    /// Whether the current drag has been cancelled by moving outside the view
    @State var isDragCancelled: Bool = false
    @State var liveDragPreciseTime: Date? = nil
    @State var lastLiveDragMinute: Int = -1

    // MARK: - Constants

    /// Horizontal breathing room kept between the time button and the slider's
    /// left/right edges so the button doesn't sit flush against the container
    /// when the current (or dragged) time is near the start/end of the day (NutriKit #1765).
    /// Only the button is inset — the connector needle still tracks the exact time.
    let timeButtonEdgePadding: CGFloat = 8.0
    /// Maximum distance (pts) the finger can move and still count as "holding still"
    let holdStillRadius: CGFloat = 6
    /// Vertical distance (in points) the touch must move outside the view to cancel (or, in a
    /// picker, to zoom back out, NutriKit #525)
    let dragCancelThreshold: CGFloat = 40
    /// Extra horizontal slop around the needle's time button that still counts as
    /// grabbing it — the button's exact bounds are a little tight for a finger (NutriKit #2280).
    let needleGrabSlop: CGFloat = 12
    let compactTrackCornerRadius: CGFloat = 6

    /// The pills' digits rolling: quick enough to keep up with a drag, soft enough to read.
    static let textSpring = Animation.snappy(duration: 0.28)
    /// The pills' place and width (#3948): slow and a little loose, so they trail the needles with
    /// some weight. A spring keeps its velocity when retargeted, so a quick flick left and back
    /// barely moves them; they settle where the finger rests.
    static let pillSpring = Animation.spring(response: 0.85, dampingFraction: 0.92)

    // MARK: - NutriKit's init

    /// A time on the diary day, or (`liveMode`) the home card's live timeline: NutriKit's slider
    /// as it always was. `currentTimeSlot` is accepted for the call sites and unused: the needle
    /// reads `currentTime`.
    public init(
        date: Date,
        existingTimeSlots: [Int],
        currentTime: Binding<Date>,
        currentTimeSlot: Int,
        allowedTimeRange: ClosedRange<Date>? = nil,
        liveMode: Bool = false,
        isToday: Bool = true,
        accentColor: Color? = nil,
        onDragStateChanged: ((Bool, Int?, Date?) -> Void)? = nil,
        onCreateMealAt: ((Date) -> Void)? = nil,
        onExistingSlotDragged: ((Int) -> Void)? = nil,
        onQuickFlickToDay: ((Date) -> Void)? = nil,
        mealBubbles: [TimelineMealBubble] = [],
        workoutBubbles: [TimelineWorkoutBubble] = [],
        onMealBubbleTapped: ((String) -> Void)? = nil,
        onWorkoutBubbleTapped: ((String) -> Void)? = nil,
        isHoldingPosition: Binding<Bool> = .constant(false),
        isDragging: Binding<Bool> = .constant(false),
        dragTimeSlot: Binding<Int?> = .constant(nil),
        heldTimeSlot: Binding<Int?> = .constant(nil),
        animatedSlotPosition: Binding<CGFloat?> = .constant(nil),
        isAnimatingReset: Binding<Bool> = .constant(false),
        resetAnimationPosition: Binding<CGFloat?> = .constant(nil),
        style: TimeSliderStyle = .standard,
        precisePicker: Binding<Bool>? = nil,
        options: TimeSliderOptions = []
    ) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let allowed = allowedTimeRange ?? dayStart...TimelineSlots.endOfPostMidnight(for: date, calendar: calendar)
        self.init(
            date: date,
            dayStart: dayStart,
            existingTimeSlots: existingTimeSlots,
            start: currentTime,
            end: nil,
            minimumMinutes: 0,
            allowedTimeRange: allowed,
            allowedTimeSlotsRange: TimelineSlots.slotSpan(of: allowed, from: dayStart),
            liveMode: liveMode,
            isToday: isToday,
            accentColor: accentColor,
            onDragStateChanged: onDragStateChanged,
            onCreateMealAt: onCreateMealAt,
            onExistingSlotDragged: onExistingSlotDragged,
            onQuickFlickToDay: onQuickFlickToDay,
            mealBubbles: mealBubbles,
            workoutBubbles: workoutBubbles,
            onMealBubbleTapped: onMealBubbleTapped,
            onWorkoutBubbleTapped: onWorkoutBubbleTapped,
            isHoldingPosition: isHoldingPosition,
            isDragging: isDragging,
            dragTimeSlot: dragTimeSlot,
            heldTimeSlot: heldTimeSlot,
            animatedSlotPosition: animatedSlotPosition,
            isAnimatingReset: isAnimatingReset,
            resetAnimationPosition: resetAnimationPosition,
            style: style,
            precisePicker: precisePicker,
            ownsWheel: false,
            accessibilityName: precisePicker != nil ? "Time" : nil,
            wheelRange: allowed,
            options: options
        )
    }

    // MARK: - The day inits (#3948)

    /// One time on the day's 30-hour timeline. A tap on the pill opens a wheel for the exact time;
    /// `markers` (other events that day) are drawn as filled slots.
    public init(
        day: Date,
        time: Binding<Date>,
        markers: [Date] = [],
        allowedRange: ClosedRange<Date>? = nil,
        style: TimeSliderStyle = .standard,
        accentColor: Color? = nil,
        mealBubbles: [TimelineMealBubble] = [],
        workoutBubbles: [TimelineWorkoutBubble] = [],
        options: TimeSliderOptions = .all,
        accessibilityName: String = "Start time"
    ) {
        self.init(day: day, start: time, optionalEnd: nil, markers: markers, allowedRange: allowedRange,
                  minimumDuration: 0, style: style, accentColor: accentColor, mealBubbles: mealBubbles,
                  workoutBubbles: workoutBubbles, options: options, accessibilityName: accessibilityName)
    }

    /// An interval on the day's 30-hour timeline: both ends draggable, the stretch between them
    /// coloured and its length shown. The host keeps `end` after `start`; the slider holds it at
    /// least `minimumDuration` after, and both inside `allowedRange`.
    public init(
        day: Date,
        start: Binding<Date>,
        end: Binding<Date>,
        markers: [Date] = [],
        allowedRange: ClosedRange<Date>? = nil,
        minimumDuration: TimeInterval = 5 * 60,
        style: TimeSliderStyle = .standard,
        accentColor: Color? = nil,
        mealBubbles: [TimelineMealBubble] = [],
        workoutBubbles: [TimelineWorkoutBubble] = [],
        options: TimeSliderOptions = .all,
        accessibilityName: String = "Time"
    ) {
        self.init(day: day, start: start, optionalEnd: end, markers: markers, allowedRange: allowedRange,
                  minimumDuration: minimumDuration, style: style, accentColor: accentColor,
                  mealBubbles: mealBubbles, workoutBubbles: workoutBubbles, options: options,
                  accessibilityName: accessibilityName)
    }

    private init(
        day: Date,
        start: Binding<Date>,
        optionalEnd end: Binding<Date>?,
        markers: [Date],
        allowedRange: ClosedRange<Date>?,
        minimumDuration: TimeInterval,
        style: TimeSliderStyle,
        accentColor: Color?,
        mealBubbles: [TimelineMealBubble],
        workoutBubbles: [TimelineWorkoutBubble],
        options: TimeSliderOptions,
        accessibilityName: String
    ) {
        let dayStart = Calendar.current.startOfDay(for: day)
        let markerSlots = Set(markers.compactMap { marker -> Int? in
            let minute = TimelineSlots.minute(of: marker, from: dayStart)
            guard minute >= 0, minute < TimelineSlots.totalMinutes else { return nil }
            return TimelineSlots.slot(forMinute: minute)
        })
        let minutes = TimelineSlots.allowedMinutes(for: allowedRange, from: dayStart)
        let allowed = TimelineSlots.date(forMinute: minutes.lowerBound, from: dayStart)
            ... TimelineSlots.date(forMinute: minutes.upperBound, from: dayStart)
        self.init(
            date: day,
            dayStart: dayStart,
            existingTimeSlots: markerSlots.sorted(),
            start: start,
            end: end,
            minimumMinutes: max(minimumDuration / 60, 0),
            allowedTimeRange: allowed,
            allowedTimeSlotsRange: TimelineSlots.slot(forMinute: minutes.lowerBound)...TimelineSlots.slot(forMinute: minutes.upperBound),
            liveMode: false,
            isToday: true,
            accentColor: accentColor,
            onDragStateChanged: nil,
            onCreateMealAt: nil,
            onExistingSlotDragged: nil,
            onQuickFlickToDay: nil,
            mealBubbles: mealBubbles,
            workoutBubbles: workoutBubbles,
            onMealBubbleTapped: nil,
            onWorkoutBubbleTapped: nil,
            isHoldingPosition: .constant(false),
            isDragging: .constant(false),
            dragTimeSlot: .constant(nil),
            heldTimeSlot: .constant(nil),
            animatedSlotPosition: .constant(nil),
            isAnimatingReset: .constant(false),
            resetAnimationPosition: .constant(nil),
            style: style,
            precisePicker: nil,
            ownsWheel: true,
            accessibilityName: accessibilityName,
            wheelRange: nil,
            options: options
        )
    }

    // MARK: - The one designated init

    private init(
        date: Date,
        dayStart: Date,
        existingTimeSlots: [Int],
        start: Binding<Date>,
        end: Binding<Date>?,
        minimumMinutes: Double,
        allowedTimeRange: ClosedRange<Date>,
        allowedTimeSlotsRange: ClosedRange<Int>,
        liveMode: Bool,
        isToday: Bool,
        accentColor: Color?,
        onDragStateChanged: ((Bool, Int?, Date?) -> Void)?,
        onCreateMealAt: ((Date) -> Void)?,
        onExistingSlotDragged: ((Int) -> Void)?,
        onQuickFlickToDay: ((Date) -> Void)?,
        mealBubbles: [TimelineMealBubble],
        workoutBubbles: [TimelineWorkoutBubble],
        onMealBubbleTapped: ((String) -> Void)?,
        onWorkoutBubbleTapped: ((String) -> Void)?,
        isHoldingPosition: Binding<Bool>,
        isDragging: Binding<Bool>,
        dragTimeSlot: Binding<Int?>,
        heldTimeSlot: Binding<Int?>,
        animatedSlotPosition: Binding<CGFloat?>,
        isAnimatingReset: Binding<Bool>,
        resetAnimationPosition: Binding<CGFloat?>,
        style: TimeSliderStyle,
        precisePicker: Binding<Bool>?,
        ownsWheel: Bool,
        accessibilityName: String?,
        wheelRange: ClosedRange<Date>?,
        options: TimeSliderOptions
    ) {
        self.date = date
        self.dayStart = dayStart
        self.nextMidnight = TimelineSlots.nextMidnight(after: dayStart)
        self.existingTimeSlots = existingTimeSlots
        _currentTime = start
        _intervalEnd = end ?? .constant(start.wrappedValue)
        self.isInterval = end != nil
        self.minimumMinutes = minimumMinutes
        self.sliderStyle = style
        self.barHeight = style == .compact ? 30 : 50
        self.options = options
        self.precisePicker = precisePicker
        self.ownsWheel = ownsWheel
        self.accessibilityName = accessibilityName
        self.wheelRange = wheelRange
        self.allowedTimeRange = allowedTimeRange
        self.allowedTimeSlotsRange = allowedTimeSlotsRange
        self.allowedMinutes = TimelineSlots.allowedMinutes(for: allowedTimeRange, from: dayStart)
        self.liveMode = liveMode
        self.isToday = isToday
        self.accentColorOverride = accentColor
        self.onDragStateChanged = onDragStateChanged
        self.onCreateMealAt = onCreateMealAt
        self.onExistingSlotDragged = onExistingSlotDragged
        self.onQuickFlickToDay = onQuickFlickToDay
        self.mealBubbles = mealBubbles
        self.workoutBubbles = workoutBubbles
        self.onMealBubbleTapped = onMealBubbleTapped
        self.onWorkoutBubbleTapped = onWorkoutBubbleTapped
        _isHoldingPosition = isHoldingPosition
        _isDragging = isDragging
        _dragTimeSlot = dragTimeSlot
        _heldTimeSlot = heldTimeSlot
        _animatedSlotPosition = animatedSlotPosition
        _isAnimatingReset = isAnimatingReset
        _resetAnimationPosition = resetAnimationPosition
    }

    // MARK: - Body

    public var body: some View {
        if liveMode {
            liveContent
        } else {
            interactiveContent
        }
    }

    // MARK: - Shared helpers

    var isCompact: Bool { sliderStyle == .compact }

    var themedAccentColor: Color {
        accentColorOverride ?? .accentColor
    }

    /// The host's dress for a pill and its needle (`TimeSliderHooks.pillColors`).
    func pillColors(_ context: TimeSliderPillContext, accent: Color) -> TimeSliderPillColors {
        TimeSliderHooks.pillColors(context, accent, colorScheme)
    }

    func minute(of date: Date) -> Double {
        TimelineSlots.minute(of: date, from: dayStart)
    }

    func date(forMinute minute: Double) -> Date {
        TimelineSlots.date(forMinute: minute, from: dayStart)
    }

    func isPastMidnight(_ time: Date) -> Bool {
        time >= nextMidnight
    }

    /// Whether existing-meal slots should block creation/drag interactions.
    /// Only enabled when the host view opts in via `onExistingSlotDragged`
    /// (e.g. NutriKit's ItemEditor, where tapping an existing meal selects it to add items).
    /// MealForm/EditMealView leave this nil so users can create overlapping meals.
    var blocksExistingSlots: Bool {
        onExistingSlotDragged != nil
    }

    /// Whether the finger minute falls on the exact visual slot of an existing meal
    func isExactMealSlot(atMinute minute: Double) -> Bool {
        guard blocksExistingSlots else { return false }
        let realSlot = Int(minute / TimelineSlots.minutesPerSlot)
        guard existingTimeSlots.contains(realSlot) else { return false }
        let mealStartMinute = Double(realSlot) * TimelineSlots.minutesPerSlot
        return minute >= mealStartMinute && minute < mealStartMinute + minutesPerVisualSlot
    }

    /// Whether any drag (interactive or live mode) is currently active
    var isAnyDragActive: Bool {
        isInteractiveDragging || isDragging
    }

    /// Schedule a zoom-in to fire after 1 second of holding still.
    /// Works for both interactive and live mode drags.
    func scheduleZoomTimer() {
        zoomTask?.cancel()
        guard zoomLevel < 15, isAnyDragActive else {
            zoomTask = nil
            return
        }
        zoomTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, isAnyDragActive else { return }
            zoomInAtFinger()
        }
    }

    private func zoomInAtFinger() {
        let targetZoom: CGFloat = zoomLevel >= 3 ? 15 : 3
        let fingerMinute = minuteForVisualSlot(Double(timeSlot(for: lastFingerX)))
        let newCenter = zoomCenter(keeping: fingerMinute, at: lastFingerX, forLevel: targetZoom)

        TimeSliderHaptics.impact(.rigid)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            zoomLevel = targetZoom
            zoomCenterMinute = newCenter
        }

        // Schedule again for next zoom step (3x → 15x)
        scheduleZoomTimer()
    }

    func cancelZoomTimer() {
        zoomTask?.cancel()
        zoomTask = nil
    }

    /// Back to the whole day, as a drag ends or leaves the slider.
    func zoomOut() {
        guard zoomLevel != 1 else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            zoomLevel = 1
            zoomCenterMinute = TimelineSlots.centreMinute
        }
    }
}
