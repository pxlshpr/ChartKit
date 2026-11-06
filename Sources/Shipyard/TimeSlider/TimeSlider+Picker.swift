import SwiftUI

// The interactive slider: a picked time (NutriKit's sheets, Overload's single time) or an
// interval (#3948). A single time runs NutriKit's code as it was; an interval runs Overload's.

extension TimeSlider {

    var interactiveContent: some View {
        ZStack {
            VStack(spacing: 0) {
                timeButtonRow
                // NutriKit #3160 — with the day's meals and workouts handed in, the gap between
                // the pill and the bar grows into a row of bubbles (drawn in
                // `interactiveBubbleLayer` above the needle); without them it stays the original
                // connector gap.
                if hasBubbles {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(height: interactiveBubbleRowHeight)
                } else {
                    connectorRowPlaceholder
                }
                slider
                    .frame(height: barHeight)
                    .timeSliderReadSize { size in
                        self.sliderWidth = size.width
                    }
                zoomedMarkersRow
            }
            connectorLayer
            if hasBubbles {
                interactiveBubbleLayer
            }
        }
        .modifier(WholeAreaTouches(isOn: options.contains(.wholeAreaTouches)))
        .timeSliderReadSize { size in
            self.panViewHeight = size.height
        }
        // UIKit's pan, begun only by a clearly horizontal move, so a vertical swipe still reaches
        // the sheet's swipe-to-dismiss (a SwiftUI DragGesture claims it, NutriKit #2025).
        .gesture(interactivePanGesture)
        .onTapGesture { handleInteractiveTap(at: $0) }
        .onDisappear { cancelZoomTimer() }
        .modifier(PreciseTimeAccessibility(
            name: accessibilityName,
            value: accessibilityValue,
            isInterval: isInterval,
            step: { stepTime(by: $0) },
            resize: { stepEnd(by: $0) },
            openPicker: { openWheel(for: .start) }
        ))
    }

    // MARK: - Taps

    /// A tap on the pill opens the precise picker when there is one (NutriKit #3302); any other
    /// tap, or every tap without one, moves the needle (an interval's nearer end) to where it
    /// landed. An interval's pills take their own taps.
    func handleInteractiveTap(at location: CGPoint) {
        if isInterval {
            intervalTap(at: location)
            return
        }
        if hasWheel, timeButtonHitFrame.contains(location) {
            TimeSliderHaptics.impact(.soft)
            openWheel(for: .start)
            return
        }
        tappedX(location.x)
    }

    /// The pill's frame in the slider's own space, a little generous for a finger — it heads
    /// the stack, so its top is the slider's.
    var timeButtonHitFrame: CGRect {
        guard sliderWidth > 0, buttonSize.width > 0 else { return .null }
        let centerX = sliderWidth / 2 + clampedTimeButtonOffset
        return CGRect(
            x: centerX - buttonSize.width / 2,
            y: 0,
            width: buttonSize.width,
            height: buttonSize.height
        ).insetBy(dx: -needleGrabSlop, dy: -6)
    }

    func tappedX(_ x: CGFloat) {
        let visualSlotIndex = timeSlot(for: x)
        let tappedMinute = minuteForVisualSlot(Double(visualSlotIndex))
        let realSlot = Int(tappedMinute / TimelineSlots.minutesPerSlot)

        /// If tapped on an existing meal slot and the host opts in
        /// (e.g. ItemEditor's select-meal-to-add-items affordance), select it.
        if blocksExistingSlots, existingTimeSlots.contains(realSlot) {
            withAnimation(.interactiveSpring()) {
                TimeSliderHaptics.impact(.soft)
                onExistingSlotDragged?(realSlot)
            }
            return
        }

        // NutriKit's hosts hold the time in range themselves (a clamping binding); the `day:`
        // inits hold a tap inside the allowed range here, as Overload's port did (#3948).
        let tapped = TimelineSlots.date(forSlot: realSlot, from: dayStart)
        withAnimation(.interactiveSpring()) {
            TimeSliderHaptics.impact(.soft)
            self.currentTime = ownsWheel
                ? min(max(tapped, allowedTimeRange.lowerBound), allowedTimeRange.upperBound)
                : tapped
        }
    }

    /// An interval's tap: the nearer end to the start of the slot it landed on.
    private func intervalTap(at location: CGPoint) {
        let minute = minuteForVisualSlot(Double(timeSlot(for: location.x)))
        let slotStart = Double(TimelineSlots.slot(forMinute: minute)) * TimelineSlots.minutesPerSlot
        let handle = interval.nearestHandle(toMinute: minute)
        carriedMinutes = intervalMinutes
        TimeSliderHaptics.impact(.soft)
        withAnimation(.interactiveSpring()) {
            move(handle, toMinute: slotStart)
        }
    }

    // MARK: - VoiceOver

    /// VoiceOver's quarter-hour step, held inside the allowed range (an interval moves whole).
    func stepTime(by direction: AccessibilityAdjustmentDirection) {
        if isInterval {
            let step = TimelineSlots.minutesPerSlot * (direction == .increment ? 1 : -1)
            carriedMinutes = intervalMinutes
            setStart(minute(of: currentTime) + step)
            return
        }
        let step: TimeInterval = direction == .increment ? TimelineSlots.secondsPerSlot : -TimelineSlots.secondsPerSlot
        let stepped = currentTime.addingTimeInterval(step)
        currentTime = min(max(stepped, allowedTimeRange.lowerBound), allowedTimeRange.upperBound)
    }

    /// VoiceOver's "Longer" / "Shorter": the interval's end by a quarter-hour.
    func stepEnd(by direction: AccessibilityAdjustmentDirection) {
        let step = TimelineSlots.minutesPerSlot * (direction == .increment ? 1 : -1)
        setEnd(minute(of: endTime) + step)
    }

    var accessibilityValue: String {
        func spoken(_ time: Date) -> String {
            let value = time.formatted(date: .omitted, time: .shortened)
            guard isPastMidnight(time), isInterval || options.contains(.pastMidnightLabel) else { return value }
            return "\(value), past midnight"
        }
        guard isInterval else { return spoken(currentTime) }
        return "\(spoken(currentTime)) to \(spoken(endTime)), \(DurationText.spoken(minutes: intervalMinutes))"
    }

    // MARK: - Moving an interval's ends

    var endTime: Date { isInterval ? intervalEnd : currentTime }
    var interval: TimelineInterval { TimelineInterval(start: minute(of: currentTime), end: minute(of: endTime)) }
    var intervalMinutes: Double { interval.length }

    func move(_ handle: Handle, toMinute m: Double) {
        if handle == .end { setEnd(m) } else { setStart(m) }
    }

    /// The start, carrying an interval's end `carriedMinutes` after it (squeezed, never below the
    /// minimum, against the end of the allowed range). A single time is held inside the range.
    func setStart(_ m: Double) {
        guard isInterval else {
            currentTime = date(forMinute: min(max(m, allowedMinutes.lowerBound), allowedMinutes.upperBound))
            return
        }
        let next = interval.settingStart(m, carrying: carriedMinutes, minimum: minimumMinutes, allowed: allowedMinutes)
        currentTime = date(forMinute: next.start)
        intervalEnd = date(forMinute: next.end)
    }

    /// The end alone: at least the minimum after the start, inside the allowed range.
    func setEnd(_ m: Double) {
        guard isInterval else { return }
        let next = interval.settingEnd(m, minimum: minimumMinutes, allowed: allowedMinutes)
        intervalEnd = date(forMinute: next.end)
    }

    // MARK: - Drag and zoom

    /// UIKit pan that only begins for clearly horizontal movements, so vertical
    /// swipes on the timeline reach the containing sheet's dismiss gesture (NutriKit #2025).
    var interactivePanGesture: InteractiveHorizontalPanGesture {
        InteractiveHorizontalPanGesture(
            onChanged: { location in
                if isInterval {
                    handleIntervalPanChanged(at: location)
                } else {
                    handleInteractivePanChanged(at: location)
                }
            },
            onEnded: { handleInteractivePanEnded() }
        )
    }

    private func handleInteractivePanChanged(at location: CGPoint) {
        if !isInteractiveDragging {
            isInteractiveDragging = true
            // NutriKit #2575 — every gesture starts from a clean baseline rather than trusting
            // the last one to have cleaned up after itself: a pan that ends in a state
            // `handleUIGestureRecognizerAction` doesn't route to `onEnded` would
            // otherwise carry its last reported minute into the next drag and swallow
            // that drag's first update.
            lastReportedMinute = -1
        }

        lastFingerX = location.x
        // Reset zoom timer on any movement — only fires if finger holds still for 1 second
        scheduleZoomTimer()

        // Zoom out if drag has left the timeline view vertically (NutriKit #525)
        let isOutsideBounds = location.y < -dragCancelThreshold || location.y > panViewHeight + dragCancelThreshold
        if isOutsideBounds && zoomLevel != 1 {
            cancelZoomTimer()
            zoomOut()
        }

        // Map finger x to real-world minute
        let fingerMinute = minuteForVisualSlot(Double(timeSlot(for: location.x)))

        let granularity = minutesPerVisualSlot
        let snappedMinute = round(fingerMinute / granularity) * granularity
        let maxMinutes = TimelineSlots.totalMinutes
        let clampedMinute = min(max(snappedMinute,
                                    Double(allowedTimeSlotsRange.lowerBound) * TimelineSlots.minutesPerSlot),
                                min(Double(allowedTimeSlotsRange.upperBound) * TimelineSlots.minutesPerSlot, maxMinutes))

        let minuteInt = Int(clampedMinute)
        guard minuteInt != lastReportedMinute else { return }
        lastReportedMinute = minuteInt

        let realSlot = Int(clampedMinute / TimelineSlots.minutesPerSlot)
        let clampedSlot = min(max(realSlot, allowedTimeSlotsRange.lowerBound), allowedTimeSlotsRange.upperBound)

        TimeSliderHaptics.selection()

        if isExactMealSlot(atMinute: clampedMinute) {
            onExistingSlotDragged?(clampedSlot)
        } else {
            self.currentTime = date(forMinute: clampedMinute)
        }
    }

    /// An interval's drag (#3948): the end nearer the finger as it began, minute-precise inside
    /// the allowed range.
    private func handleIntervalPanChanged(at location: CGPoint) {
        if !isInteractiveDragging {
            isInteractiveDragging = true
            // Every drag starts from a clean baseline (NutriKit #2575).
            lastReportedMinute = -1
            activeHandle = interval.nearestHandle(toMinute: minuteForVisualSlot(Double(timeSlot(for: location.x))))
            carriedMinutes = intervalMinutes
        }
        lastFingerX = location.x

        let isOutsideBounds = location.y < -dragCancelThreshold
            || location.y > panViewHeight + dragCancelThreshold
        if isOutsideBounds {
            cancelZoomTimer()
            zoomOut()
        } else {
            // Any move restarts the hold-still timer.
            scheduleZoomTimer()
        }

        let fingerMinute = minuteForVisualSlot(Double(timeSlot(for: location.x)))
        let granularity = minutesPerVisualSlot
        let snapped = (fingerMinute / granularity).rounded() * granularity
        let clamped = min(max(snapped, allowedMinutes.lowerBound), allowedMinutes.upperBound)

        let minuteInt = Int(clamped.rounded())
        guard minuteInt != lastReportedMinute else { return }
        lastReportedMinute = minuteInt

        TimeSliderHaptics.selection()
        move(activeHandle, toMinute: clamped)
    }

    private func handleInteractivePanEnded() {
        isInteractiveDragging = false
        lastReportedMinute = -1
        cancelZoomTimer()
        zoomOut()
    }

    // MARK: - The wheel

    /// Whether a tap on the single pill opens a wheel: the host's (`precisePicker`) or the
    /// slider's own.
    var hasWheel: Bool { precisePicker != nil || ownsWheel }

    func openWheel(for handle: Handle) {
        if ownsWheel || isInterval {
            wheelHandle = handle
            showsOwnWheel = true
        } else {
            precisePicker?.wrappedValue = true
        }
    }

    /// The single pill's popover: the host's binding, the slider's own, or none.
    var singleWheelBinding: Binding<Bool> {
        if let precisePicker { return precisePicker }
        guard ownsWheel else { return .constant(false) }
        return Binding(get: { showsOwnWheel }, set: { showsOwnWheel = $0 })
    }

    /// The exact time on the system's wheel (NutriKit #3302): what a compact date picker beside the
    /// slider used to offer, now behind the pill that already shows the time. The wheel picks a
    /// clock time, placed on the 30 hours at the end nearer the time being edited (#3948).
    func precisePickerContent(for handle: Handle) -> some View {
        let selection = Binding<Date>(
            get: { handle == .end ? endTime : currentTime },
            set: { picked in
                let near = handle == .end ? endTime : currentTime
                let placed = TimelineSlots.placeOnTimeline(
                    picked, near: near, dayStart: dayStart, nextMidnight: nextMidnight, allowed: allowedTimeRange
                )
                if !isInterval {
                    currentTime = placed
                } else if handle == .end {
                    setEnd(minute(of: placed))
                } else {
                    carriedMinutes = intervalMinutes
                    setStart(minute(of: placed))
                }
            }
        )
        return Group {
            if let wheelRange {
                DatePicker("Time", selection: selection, in: wheelRange, displayedComponents: [.hourAndMinute])
            } else {
                DatePicker("Time", selection: selection, displayedComponents: [.hourAndMinute])
            }
        }
        .datePickerStyle(.wheel)
        .labelsHidden()
        .padding(.horizontal, 16)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: - The single pill

    @ViewBuilder
    var timeButtonRow: some View {
        if isInterval {
            intervalButtonRow
        } else {
            singleButtonRow
        }
    }

    private var singleButtonRow: some View {
        // NutriKit #2702 — the sheet pickers have their own variant knob, separate from the home
        // timeline's; the host's `pillColors` hook reads it.
        let colors = pillColors(.picker, accent: themedAccentColor)
        let rolls = options.contains(.rollingDigits)
        let minuteValue = minute(of: currentTime)
        let showsPastMidnight = options.contains(.pastMidnightLabel) && isPastMidnight(currentTime)
        var button: some View {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                // NutriKit #2733 — the value and its AM/PM are one readout, so both take the
                // number face; the value stays tabular so stepping through times doesn't resize
                // the pill. #3302 — a size down in the compact style.
                Text(timeString)
                    .timeSliderNumberFont(isCompact ? .headline : .title3, weight: .bold, monospacedDigit: true)
                    .modifier(RollingDigits(isOn: rolls, value: minuteValue))
                Text(amPmString)
                    .timeSliderNumberFont(isCompact ? .footnote : .callout, weight: .semibold)
                    .modifier(InterpolatedText(isOn: rolls))
                if showsPastMidnight {
                    // NutriKit's meal header words for a post-midnight time (#3014).
                    Text("Past Midnight")
                        .font(.system(isCompact ? .caption2 : .caption, weight: .semibold))
                        .opacity(0.85)
                        .padding(.leading, 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .foregroundStyle(colors.foreground)
            .padding(.vertical, isCompact ? 4 : 5)
            .padding(.horizontal, isCompact ? 9 : 10)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(colors.fill)
            )
            .overlay {
                if let stroke = colors.stroke {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(stroke, lineWidth: colors.strokeWidth)
                }
            }
            // The digits roll quickly; the pill's width follows on a heavier spring (#3948).
            .modifier(PillSpring(isOn: rolls, minute: Int(minuteValue.rounded()), isPastMidnight: showsPastMidnight))
        }

        return ZStack {
            button
            // NutriKit #3302 — the precise picker hangs off the pill itself, so it points at the
            // time it sets wherever the needle has left it.
            .popover(isPresented: singleWheelBinding) {
                precisePickerContent(for: .start)
            }
            .offset(x: clampedTimeButtonOffset)
            .timeSliderReadSize { size in
                buttonSize = size
            }
        }
        .modifier(PillPlacementAnimation(
            rolls: rolls, visualSlot: currentVisualSlot, offset: clampedTimeButtonOffset
        ))
    }

    /// The pill's offset from the slider's centre: over the needle, held clear of both ends.
    var clampedTimeButtonOffset: CGFloat {
        let rawOffset = offsetXForVisualSlot(currentVisualSlot)
        let halfButton = buttonSize.width / 2.0
        let halfSlider = sliderWidth / 2.0
        return min(max(rawOffset, -halfSlider + halfButton + timeButtonEdgePadding), halfSlider - halfButton - timeButtonEdgePadding)
    }

    var timeString: String {
        Self.clockFormatter.string(from: currentTime)
    }

    var amPmString: String {
        Self.amPmFormatter.string(from: currentTime).lowercased()
    }

    /// "h:mm" and "a", as NutriKit's pill has always read (a formatter apiece, made once).
    static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    static let amPmFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "a"
        return formatter
    }()

    // MARK: - An interval's pills (#3948)

    /// An interval's pills each over its own needle with the length between them, pushed apart
    /// where they'd overlap and held clear of the slider's ends. Only the two needle positions
    /// animate, on a heavy spring; `IntervalPillsLayout` places all three pieces from them on
    /// every frame, so they trail with some weight but never overlap or drift apart. Each pill
    /// opens the wheel for its end.
    private var intervalButtonRow: some View {
        IntervalPillsLayout(startX: shownNeedleX.start, endX: shownNeedleX.end,
                            gap: isCompact ? 6 : 8, edgePadding: timeButtonEdgePadding) {
            intervalPill(for: .start)
            durationChip
            intervalPill(for: .end)
        }
        // Widths change with the digits ("1h 30m" → "1h"): they ease on the same spring.
        .animation(Self.pillSpring, value: Int(minute(of: currentTime).rounded()))
        .animation(Self.pillSpring, value: Int(minute(of: endTime).rounded()))
        .frame(maxWidth: .infinity)
        .timeSliderReadSize { buttonSize = CGSize(width: 0, height: $0.height) }
        // A retargeted spring keeps its velocity, so a quick flick barely moves the pills.
        .onChange(of: needleX(currentVisualSlot), initial: true) { _, x in
            withAnimation(Self.pillSpring) { shownNeedleX.start = x }
        }
        .onChange(of: needleX(endVisualSlot), initial: true) { _, x in
            withAnimation(Self.pillSpring) { shownNeedleX.end = x }
        }
    }

    /// A needle's x in the slider's own space (0 at its leading edge).
    private func needleX(_ slot: CGFloat) -> CGFloat {
        offsetXForVisualSlot(slot) + sliderWidth / 2
    }

    private var durationChip: some View {
        Text(DurationText.short(minutes: intervalMinutes))
            .timeSliderNumberFont(isCompact ? .footnote : .callout, weight: .semibold, monospacedDigit: true)
            .foregroundStyle(themedAccentColor)
            .contentTransition(.numericText(value: intervalMinutes))
            .animation(Self.textSpring, value: Int(intervalMinutes.rounded()))
            .padding(.horizontal, isCompact ? 8 : 10)
            .padding(.vertical, isCompact ? 3 : 4)
            .background(themedAccentColor.opacity(0.14), in: .capsule)
            .fixedSize()
    }

    private func intervalPill(for handle: Handle) -> some View {
        let time = handle == .end ? endTime : currentTime
        let colors = pillColors(.picker, accent: themedAccentColor)
        let isActive = isInteractiveDragging && activeHandle == handle
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(Self.clockFormatter.string(from: time))
                .timeSliderNumberFont(isCompact ? .subheadline : .headline, weight: .bold, monospacedDigit: true)
                .contentTransition(.numericText(value: minute(of: time)))
                .animation(Self.textSpring, value: Int(minute(of: time).rounded()))
            Text(Self.amPmFormatter.string(from: time).lowercased())
                .timeSliderNumberFont(isCompact ? .caption : .footnote, weight: .semibold)
                .contentTransition(.interpolate)
            if isPastMidnight(time) {
                // Two pills have no room for "Past Midnight": a moon says it.
                Image(systemName: "moon.fill")
                    .font(.system(size: isCompact ? 9 : 10, weight: .semibold))
                    .opacity(0.85)
                    .padding(.leading, 2)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .foregroundStyle(colors.foreground)
        .padding(.vertical, isCompact ? 4 : 5)
        .padding(.horizontal, isCompact ? 8 : 9)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(colors.fill))
        .overlay {
            if let stroke = colors.stroke {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(stroke, lineWidth: colors.strokeWidth)
            }
        }
        .scaleEffect(isActive ? 1.06 : 1)
        .animation(.snappy(duration: 0.2), value: isActive)
        .contentShape(Rectangle())
        .onTapGesture {
            TimeSliderHaptics.impact(.soft)
            openWheel(for: handle)
        }
        .fixedSize()
        .popover(isPresented: Binding(
            get: { showsOwnWheel && wheelHandle == handle },
            set: { showsOwnWheel = $0 }
        )) {
            precisePickerContent(for: handle)
        }
    }

    // MARK: - Needles

    var connectorLayer: some View {
        let slotWidth = sliderWidth / CGFloat(TimelineSlots.count)
        let connectorWidth = max(slotWidth * 0.8, 2)
        let connectorFill = pillColors(.picker, accent: themedAccentColor).needle

        var connector: some View {
            Rectangle()
                .fill(connectorFill)
                .frame(width: connectorWidth)
                .timeSliderCornerRadius(1, corners: [.bottomRight, .bottomLeft])
        }

        return VStack(spacing: 0) {
            Color.clear
                .frame(height: max(buttonSize.height - 1, 0))
            ZStack {
                connector
                    .frame(height: interactiveGapHeight + barHeight)
                    .offset(x: offsetXForVisualSlot(currentVisualSlot))
                if isInterval {
                    connector
                        .frame(height: interactiveGapHeight + barHeight)
                        .offset(x: offsetXForVisualSlot(endVisualSlot))
                }
            }
            Color.clear
                .frame(height: markersRowHeight)
        }
        .modifier(NeedleAnimation(
            isInterval: isInterval,
            isDragging: isInteractiveDragging,
            start: currentVisualSlot,
            end: endVisualSlot
        ))
    }

    var connectorRowPlaceholder: some View {
        let slotWidth = sliderWidth / CGFloat(TimelineSlots.count)
        let connectorWidth = max(slotWidth * 0.8, 2)

        var connector: some View {
            Rectangle()
                .fill(themedAccentColor)
                .frame(width: connectorWidth, height: 20)
        }

        return ZStack {
            connector
                .offset(x: offsetXForVisualSlot(currentVisualSlot))
                .opacity(0)
        }
    }
}

// MARK: - Modifiers

/// The whole slider takes touches (`TimeSliderOptions.wholeAreaTouches`).
private struct WholeAreaTouches: ViewModifier {
    let isOn: Bool
    func body(content: Content) -> some View {
        if isOn {
            content.contentShape(Rectangle())
        } else {
            content
        }
    }
}

/// The single pill's digits rolling (`TimeSliderOptions.rollingDigits`).
private struct RollingDigits: ViewModifier {
    let isOn: Bool
    let value: Double
    func body(content: Content) -> some View {
        if isOn {
            content
                .contentTransition(.numericText(value: value))
                .animation(TimeSlider.textSpring, value: Int(value.rounded()))
        } else {
            content
        }
    }
}

private struct InterpolatedText: ViewModifier {
    let isOn: Bool
    func body(content: Content) -> some View {
        if isOn {
            content.contentTransition(.interpolate)
        } else {
            content
        }
    }
}

/// The single pill's width easing on the heavy spring (`rollingDigits`).
private struct PillSpring: ViewModifier {
    let isOn: Bool
    let minute: Int
    let isPastMidnight: Bool
    func body(content: Content) -> some View {
        if isOn {
            content
                .animation(TimeSlider.pillSpring, value: minute)
                .animation(TimeSlider.pillSpring, value: isPastMidnight)
        } else {
            content
        }
    }
}

/// Where the single pill moves: on NutriKit's interactive spring as the needle moves, or with
/// `rollingDigits` on the heavy spring as its place changes.
private struct PillPlacementAnimation: ViewModifier {
    let rolls: Bool
    let visualSlot: CGFloat
    let offset: CGFloat
    func body(content: Content) -> some View {
        if rolls {
            content.animation(TimeSlider.pillSpring, value: offset)
        } else {
            content.animation(.interactiveSpring(), value: visualSlot)
        }
    }
}

/// The needles' glide: a single needle always on the interactive spring (NutriKit's); an
/// interval's sit on the finger under a drag, as its coloured stretch does, and glide for taps
/// and the wheel (#3948: a spring under the drag left them trailing the stretch).
private struct NeedleAnimation: ViewModifier {
    let isInterval: Bool
    let isDragging: Bool
    let start: CGFloat
    let end: CGFloat
    func body(content: Content) -> some View {
        if isInterval {
            content
                .allowsHitTesting(false)
                .animation(isDragging ? nil : .interactiveSpring(), value: start)
                .animation(isDragging ? nil : .interactiveSpring(), value: end)
        } else {
            content
                .animation(.interactiveSpring(), value: start)
        }
    }
}
