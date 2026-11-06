import SwiftUI

// Live mode: NutriKit's home card timeline (the clock's "now" pill, the day's meal and workout
// bubbles, a drag or long press that places a new meal), moved here whole in #3950. Only the
// app's own calls became hooks: haptics, the number face, the pill's dress, and the day a quick
// flick turns to (`onQuickFlickToDay`).

extension TimeSlider {

    /// Current live time slot computed from now - doesn't re-render the whole view
    var currentLiveTimeSlot: Int {
        TimelineSlots.liveSlot(of: Date(), from: dayStart)
    }

    var liveContent: some View {
        // Determine if we're in a drag/hold/reset state
        // heldTimeSlot is included because it persists from drag end through animation completion,
        // bridging the gap between isHoldingPosition becoming false and isAnimatingReset becoming true
        // When drag is cancelled, treat visual state as if not dragging
        let effectiveDragging = isDragging && !isDragCancelled

        let isInActiveState = effectiveDragging || isHoldingPosition || isAnimatingReset || heldTimeSlot != nil

        // Show the NOW button/connector when viewing today, or when actually dragging on any day
        // On non-today days, only show if dragTimeSlot is set (actual drag position)
        let showNowIndicator = isToday || (isInActiveState && dragTimeSlot != nil)

        // Only use stored positions during active drag/hold/reset states
        // Otherwise, always show current live time to avoid stale position jumps (e.g., after meal deletion)
        let visualSlot: CGFloat = if isInActiveState {
            if let resetPos = resetAnimationPosition {
                resetPos
            } else if let animatedPos = animatedSlotPosition {
                animatedPos
            } else if !isToday, let dragSlot = dragTimeSlot {
                // On non-today days, use drag position directly (no "now" to animate from)
                CGFloat(dragSlot)
            } else {
                CGFloat(currentLiveTimeSlot)
            }
        } else {
            CGFloat(currentLiveTimeSlot)
        }

        // Determine if we're in a "holding" state for color purposes
        // On non-today days, always show green when indicator is visible (since there's no "now" state)
        let showHoldingColor = effectiveDragging || isHoldingPosition || isAnimatingReset || (!isToday && isInActiveState)

        // Convert real-world slot to zoom-aware visual position
        let zoomAwareSlot = visualSlotForMinute(Double(visualSlot) * TimelineSlots.minutesPerSlot)

        return ZStack {
            VStack(spacing: 0) {
                // Draggable area - uses UIKit pan gesture for proper vertical scroll passthrough
                HorizontalPanGestureView(
                    content: VStack(spacing: 0) {
                        // The button row and strip area always reserve a total of
                        // `liveBubbleRowHeight` regardless of whether bubbles are
                        // present, so the cell's height stays constant when meals
                        // come and go. With bubbles: 0pt above + button + 43pt
                        // strip (with bubbles). Without: 21.5pt above + button +
                        // 21.5pt empty strip — the now button shifts down to
                        // visually center within the strip area. `liveBubbleRow`
                        // is always rendered (even when empty) so SwiftUI can
                        // animate its frame change rather than swap between
                        // two views with different identities.
                        Color.clear.frame(height: liveButtonRowTopGap + (hasBubbles ? 0 : liveBubbleRowHeight / 2))
                        liveTimeButtonRow(visualPosition: zoomAwareSlot, isDragging: showHoldingColor, preciseTime: liveDragPreciseTime, shouldShow: showNowIndicator)
                        liveBubbleRow()
                            .frame(height: hasBubbles ? liveBubbleRowHeight : liveBubbleRowHeight / 2)
                        liveSlider()
                            .frame(height: liveBarHeight)
                    }
                    .animation(.easeInOut(duration: 0.3), value: hasBubbles)
                    .animation(.easeInOut(duration: 0.25), value: existingTimeSlots)
                    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: mealBubbles.map(\.id))
                    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: workoutBubbles.map(\.id)),
                    onPanChanged: { translation, location in
                        handleLivePanChanged(translation: translation, location: location)
                    },
                    onPanEnded: { translation, location, velocity in
                        handleLivePanEnded(translation: translation, location: location, velocity: velocity)
                    },
                    onTap: { location in
                        handleLiveTap(at: location)
                    },
                    // NutriKit #2280 — a needle drag must start within the x-boundaries of the
                    // needle's time button, and only while the needle is showing. Any
                    // other horizontal swipe falls through to the day pager / scroll.
                    shouldBeginPan: { location in
                        guard showNowIndicator else { return false }
                        return needleGrabXRange(for: zoomAwareSlot).contains(location.x)
                    },
                    // NutriKit #2280 — when the needle isn't showing (past/future days),
                    // tap-and-hold summons it at the finger; it then follows the drag
                    // until release creates the meal (or dragging out cancels).
                    shouldBeginLongPress: { location in
                        guard !showNowIndicator else { return false }
                        return !isOnBubbleCircle(location)
                    }
                )
                .timeSliderReadSize { size in
                    self.sliderWidth = size.width
                    self.panViewHeight = size.height
                }
                zoomedMarkersRow
            }
            // Conditionally render the connector layer instead of using opacity, so
            // that on non-today days it appears fresh at the finger position when drag
            // starts — without animating offsetX from the leading edge (slot 0, where
            // currentLiveTimeSlot resolves to on past days). The inner VStack always
            // reserves the same total height (`liveBubbleRowHeight`) regardless of
            // bubble presence so the cell doesn't change size when meals come/go.
            if showNowIndicator {
                liveConnectorLayer(visualPosition: zoomAwareSlot, isHolding: showHoldingColor)
            }
        }
        .onChange(of: isHoldingPosition) { _, newValue in
            if !newValue && heldTimeSlot != nil {
                if isToday {
                    // On today: animate back to current live time
                    let targetSlot = currentLiveTimeSlot

                    // Start the reset animation
                    isAnimatingReset = true

                    // Animate the position from held slot back to live slot
                    // resetAnimationPosition is observed, so SwiftUI will animate this change
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        resetAnimationPosition = CGFloat(targetSlot)
                        animatedSlotPosition = CGFloat(targetSlot)
                    }

                    // After animation completes, clear the animated position and reset state
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isAnimatingReset = false
                        }
                        resetAnimationPosition = nil
                        animatedSlotPosition = nil
                        heldTimeSlot = nil
                    }
                } else {
                    // On other days: clear all state and let opacity fade out
                    withAnimation(.easeInOut(duration: 0.2)) {
                        heldTimeSlot = nil
                        dragTimeSlot = nil
                    }
                    // Clear position values so next drag starts fresh
                    animatedSlotPosition = nil
                    resetAnimationPosition = nil
                }
            }
        }
    }

    private func liveTimeSlot(for x: CGFloat) -> Int {
        guard sliderWidth > 0 else { return 0 }
        let slotWidth = sliderWidth / CGFloat(TimelineSlots.count)
        let slot = Int(x / slotWidth)
        let clampedSlot = min(max(slot, 0), TimelineSlots.count - 1)
        return clampedSlot
    }

    // MARK: - UIKit Tap Gesture Handler

    private func handleLiveTap(at location: CGPoint) {
        // Skip the parent tap-to-create when the touch lands inside the bubble row.
        // Bubble buttons handle their own taps; treating their hits as create-meal
        // taps would double-fire (scroll + meal creation prompt).
        if hasBubbles, buttonSize.height > 0 {
            let bubbleRowTop = buttonSize.height
            let bubbleRowBottom = bubbleRowTop + liveBubbleRowHeight
            if location.y >= bubbleRowTop, location.y <= bubbleRowBottom {
                return
            }
        }

        let now = Date()
        onCreateMealAt?(now)
    }

    // MARK: - UIKit Pan Gesture Handlers

    private func handleLivePanChanged(translation: CGPoint, location: CGPoint) {
        timeSliderGestureLogger.debug("[UIKit onChanged] translation=(\(translation.x, privacy: .public), \(translation.y, privacy: .public)), location=(\(location.x, privacy: .public), \(location.y, privacy: .public))")

        if !isDragging {
            isDragging = true
            isDragCancelled = false
            resetAnimationPosition = nil

            let startX = location.x - translation.x
            panStartSlot = liveTimeSlot(for: startX)

            let startSlot = isToday ? currentLiveTimeSlot : liveTimeSlot(for: location.x)
            dragTimeSlot = startSlot
            animatedSlotPosition = CGFloat(startSlot)
            lastLiveDragMinute = -1

            lastFingerX = location.x
            scheduleZoomTimer()
        }

        // Reset zoom timer on any movement — only fires if finger holds still for 1 second
        lastFingerX = location.x
        scheduleZoomTimer()

        // Compute target minute — zoom-aware, precise
        let fingerMinute = minuteForVisualSlot(Double(liveTimeSlot(for: location.x)))
        let granularity = minutesPerVisualSlot
        let snappedMinute = round(fingerMinute / granularity) * granularity
        let maxMinutes = TimelineSlots.totalMinutes
        let clampedMinute = min(max(snappedMinute, 0), maxMinutes - TimelineSlots.minutesPerSlot)

        let targetSlot = min(max(Int(clampedMinute / TimelineSlots.minutesPerSlot), 0), TimelineSlots.count - 1)
        let preciseTime = date(forMinute: clampedMinute)
        /// Fractional real-world slot for smooth positioning (e.g., 12.33 for minute 185)
        let fractionalSlot = CGFloat(clampedMinute / TimelineSlots.minutesPerSlot)

        // Check if touch has moved outside the view bounds vertically
        let isOutsideBounds = location.y < -dragCancelThreshold || location.y > panViewHeight + dragCancelThreshold

        if isOutsideBounds && !isDragCancelled {
            isDragCancelled = true
            cancelZoomTimer()
            TimeSliderHaptics.impact(.light)
            let resetSlot = isToday ? currentLiveTimeSlot : (panStartSlot ?? 0)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                animatedSlotPosition = CGFloat(resetSlot)
            }
            zoomOut()
            liveDragPreciseTime = nil
            lastLiveDragMinute = -1
            onDragStateChanged?(false, nil, nil)
        } else if !isOutsideBounds && isDragCancelled {
            isDragCancelled = false
            TimeSliderHaptics.selection()
            scheduleZoomTimer()
            if !isExactMealSlot(atMinute: clampedMinute) {
                dragTimeSlot = targetSlot
                animatedSlotPosition = fractionalSlot
                liveDragPreciseTime = preciseTime
                lastLiveDragMinute = Int(clampedMinute)
                onDragStateChanged?(true, targetSlot, preciseTime)
            }
        } else if !isDragCancelled {
            let minuteInt = Int(clampedMinute)
            guard minuteInt != lastLiveDragMinute else { return }
            lastLiveDragMinute = minuteInt

            if isExactMealSlot(atMinute: clampedMinute) {
                TimeSliderHaptics.selection()
                dragTimeSlot = targetSlot
                animatedSlotPosition = fractionalSlot
                onExistingSlotDragged?(targetSlot)
            } else {
                TimeSliderHaptics.selection()
                dragTimeSlot = targetSlot
                animatedSlotPosition = fractionalSlot
                liveDragPreciseTime = preciseTime
                onDragStateChanged?(true, targetSlot, preciseTime)
            }
        }
    }

    /// Velocity (pts/sec) above which a swipe is treated as an accidental quick flick.
    /// Intentional meal placements end with the finger slowing to a stop; flicks don't.
    private var quickFlickVelocityThreshold: CGFloat { 500 }

    private func handleLivePanEnded(translation: CGPoint, location: CGPoint, velocity: CGPoint) {
        timeSliderGestureLogger.debug("[UIKit onEnded] translation=(\(translation.x, privacy: .public), \(translation.y, privacy: .public)), velocity=(\(velocity.x, privacy: .public), \(velocity.y, privacy: .public))")

        cancelZoomTimer()

        let isQuickFlick = abs(velocity.x) > quickFlickVelocityThreshold
        if isQuickFlick {
            timeSliderGestureLogger.debug("[UIKit onEnded] CANCELLED: quick flick detected (velocity \(abs(velocity.x), privacy: .public) > \(quickFlickVelocityThreshold, privacy: .public)) — navigating to adjacent day")
            // Swipe right (positive velocity) = previous day; swipe left (negative) = next day
            if let targetDate = Calendar.current.date(byAdding: .day, value: velocity.x > 0 ? -1 : 1, to: date) {
                onQuickFlickToDay?(targetDate)
            }
        }

        if !isDragCancelled && !isQuickFlick, let slot = dragTimeSlot,
           !(blocksExistingSlots && existingTimeSlots.contains(slot)) {
            let targetTime = liveDragPreciseTime ?? TimelineSlots.date(forSlot: slot, from: dayStart)
            onCreateMealAt?(targetTime)
        }

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isDragging = false
            isDragCancelled = false
            dragTimeSlot = nil
            heldTimeSlot = nil
            animatedSlotPosition = nil
            resetAnimationPosition = nil
        }

        zoomOut()

        panStartSlot = nil
        liveDragPreciseTime = nil
        lastLiveDragMinute = -1
        onDragStateChanged?(false, nil, nil)
    }

    // MARK: - Live Mode Helpers

    /// The x-range within which a horizontal pan may pick up the needle: the time
    /// button's current frame (edge clamping mirrored from `liveTimeButtonRow`),
    /// padded by `needleGrabSlop` (NutriKit #2280).
    private func needleGrabXRange(for visualPosition: CGFloat) -> ClosedRange<CGFloat> {
        // Before the first layout pass there's nothing to anchor to — stay permissive
        // rather than dead-zoning the whole strip.
        guard sliderWidth > 0, buttonSize.width > 0 else { return -.infinity...(.infinity) }
        let slotWidth = sliderWidth / CGFloat(TimelineSlots.count)
        let slotCenterX = visualPosition * slotWidth + slotWidth / 2
        let minXBound = buttonSize.width / 2 + timeButtonEdgePadding
        let maxXBound = sliderWidth - buttonSize.width / 2 - timeButtonEdgePadding
        let clampedCenter = maxXBound > minXBound
            ? min(max(slotCenterX, minXBound), maxXBound)
            : sliderWidth / 2
        let halfGrabWidth = buttonSize.width / 2 + needleGrabSlop
        return (clampedCenter - halfGrabWidth)...(clampedCenter + halfGrabWidth)
    }

    /// Whether a touch lands on one of the meal/workout bubble circles — a hold there
    /// is aimed at the bubble, not at summoning the needle (NutriKit #2280). Row geometry
    /// mirrors `handleLiveTap`; bubble x-positions are computed at rest (zoom is
    /// always 1x before a drag begins).
    private func isOnBubbleCircle(_ location: CGPoint) -> Bool {
        guard hasBubbles, sliderWidth > 0, buttonSize.height > 0 else { return false }
        let bubbleRowTop = buttonSize.height
        let bubbleRowBottom = bubbleRowTop + liveBubbleRowHeight
        guard location.y >= bubbleRowTop, location.y <= bubbleRowBottom else { return false }
        let slotWidth = sliderWidth / CGFloat(TimelineSlots.count)
        let allSlots = mealBubbles.map(\.timeSlot) + workoutBubbles.map(\.timeSlot)
        return allSlots.contains { slot in
            let vSlot = visualSlotForMinute(Double(slot) * TimelineSlots.minutesPerSlot)
            let centerX = CGFloat(vSlot) * slotWidth + slotWidth / 2
            return abs(location.x - centerX) <= liveBubbleSize / 2
        }
    }

    private func liveTimeButtonRow(visualPosition: CGFloat, isDragging: Bool, preciseTime: Date?, shouldShow: Bool) -> some View {
        // NutriKit #2702 — the pill wears the secondary-control variant so it stops competing
        // with the diary's plus button. The drag/hold green follows the variant too
        // (a green wash while washed, solid green on the solid variant); the neutral
        // variants borrow the wash while active, since their hueless fills would
        // erase the "creating a meal" signal. The host's `pillColors` hook reads the variant
        // here, in the body path, so an observable tick re-renders the pill when it flips.
        let isActive = isDragging && !isDragCancelled
        let colors = pillColors(.live(isActive: isActive), accent: isActive ? Color.green : themedAccentColor)
        let slotWidth = sliderWidth / CGFloat(TimelineSlots.count)
        let slotCenterX = visualPosition * slotWidth + slotWidth / 2

        let offsetX: CGFloat = {
            let centerX = sliderWidth / 2
            let minXBound = buttonSize.width / 2 + timeButtonEdgePadding
            let maxXBound = sliderWidth - buttonSize.width / 2 - timeButtonEdgePadding
            let clampedSlotCenter = min(max(slotCenterX, minXBound), maxXBound)
            return clampedSlotCenter - centerX
        }()

        return ZStack {
            // Invisible placeholder for stable layout & buttonSize measurement.
            // Always rendered so the timeline keeps its height even when the
            // visible button isn't shown (non-today days outside of a drag).
            Text(isDragging ? "00:00" : "00:00:00")
                // Must match the visible pill below exactly — it's what measures its size.
                .timeSliderNumberFont(.callout, weight: .bold, monospacedDigit: true)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .hidden()
                .timeSliderReadSize { size in
                    buttonSize = size
                }

            // Conditionally render the visible button so it appears fresh at the
            // finger position when drag starts on non-today days, rather than
            // animating its offset from the leading edge.
            if shouldShow {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let displayTime = isDragging
                        ? (preciseTime ?? context.date)
                        : context.date

                    let timeText = isDragging
                        ? displayTime.formatted(.dateTime.hour().minute())
                        : displayTime.formatted(.dateTime.hour().minute().second())

                    Text(timeText)
                        // NutriKit #2733 — the number face, so the pill matches the card's timers
                        // and the values above it. Tabular: this reads H:MM:SS and reflows every
                        // second, so the digits must hold width.
                        .timeSliderNumberFont(.callout, weight: .bold, monospacedDigit: true)
                        .foregroundStyle(colors.foreground)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(colors.fill)
                        )
                        .overlay {
                            if let stroke = colors.stroke {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(stroke, lineWidth: colors.strokeWidth)
                            }
                        }
                        .scaleEffect(isActive ? 1.05 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
                }
                .offset(x: offsetX)
            }
        }
    }

    private func liveSlider() -> some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let slotWidth = totalWidth / CGFloat(TimelineSlots.count)

            ZStack(alignment: .leading) {
                // Continuous background bar
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(.secondarySystemFill))
                    .frame(height: liveBarHeight)

                // Meal markers — zoom-aware positions
                ForEach(existingTimeSlots, id: \.self) { slot in
                    barMarker(slot: slot, slotWidth: slotWidth)
                        .transition(barMarkerTransition)
                }

                // Workout markers — same style as meal markers, so the bubble's
                // connector line continues seamlessly into the bar.
                ForEach(workoutBubbles) { bubble in
                    barMarker(slot: bubble.timeSlot, slotWidth: slotWidth)
                        .transition(barMarkerTransition)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Fade + slight shrink applied when bar markers (meal/workout) are added or
    /// removed. The animation is attached to the transition itself so it runs
    /// even when the change wasn't dispatched inside a `withAnimation` block.
    private var barMarkerTransition: AnyTransition {
        .scale(scale: 0.6)
            .combined(with: .opacity)
            .animation(.easeInOut(duration: 0.25))
    }

    @ViewBuilder
    private func barMarker(slot: Int, slotWidth: CGFloat) -> some View {
        let mealMinute = Double(slot) * TimelineSlots.minutesPerSlot
        let vSlot = visualSlotForMinute(mealMinute)
        let xPosition = CGFloat(vSlot) * slotWidth

        if vSlot >= -1, vSlot <= CGFloat(TimelineSlots.count) + 1 {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(bubbleConnectorColor)
                .frame(width: max(slotWidth * 0.8, 2), height: liveBarHeight)
                .offset(x: xPosition + slotWidth * 0.1)
        }
    }

    private func liveConnectorLayer(visualPosition: CGFloat, isHolding: Bool) -> some View {
        let slotWidth = sliderWidth / CGFloat(TimelineSlots.count)
        let connectorWidth = max(slotWidth * 0.8, 2)
        // Use CGFloat directly for smooth position interpolation during animation
        let xPosition = visualPosition * slotWidth + slotWidth * 0.1

        // Use green when dragging OR holding position (must match liveTimeButtonRow color);
        // the needle wears the pill's dress (NutriKit #2702) in both states — green-washed
        // under a green-washed pill — so it always reads as a continuation of the pill above it.
        let isActive = (isDragging && !isDragCancelled) || isHolding
        let connectorFill = pillColors(.live(isActive: isActive), accent: isActive ? Color.green : themedAccentColor).needle

        var connector: some View {
            Rectangle()
                .fill(connectorFill)
                .frame(width: connectorWidth)
                .timeSliderCornerRadius(1, corners: [.bottomRight, .bottomLeft])
                // Animate color changes (green -> accent) during reset
                .animation(.easeInOut(duration: 0.2), value: isHolding)
        }

        // Calculate offset from center (ZStack centers by default)
        let centerX = sliderWidth / 2
        let connectorCenterX = xPosition + connectorWidth / 2
        let offsetX = connectorCenterX - centerX

        // Mirror the slider VStack: `liveBubbleRowHeight` of vertical space
        // is split between an above-button spacer and the strip below the
        // button when there are no bubbles, so the connector lines up with
        // the now button regardless of bubble presence.
        let middleHeight: CGFloat = hasBubbles ? liveBubbleRowHeight : liveBubbleRowHeight / 2
        let aboveButtonExtra: CGFloat = hasBubbles ? 0 : liveBubbleRowHeight / 2

        return VStack(spacing: 0) {
            Color.clear
                .frame(height: liveButtonRowTopGap + aboveButtonExtra + max(buttonSize.height - 1, 0))
                .animation(.easeInOut(duration: 0.3), value: hasBubbles)
            connector
                .frame(height: middleHeight + liveBarHeight)
                .offset(x: offsetX)
                // Animate position when not actively dragging (i.e., during reset)
                .animation(!isDragging ? .spring(response: 0.4, dampingFraction: 0.8) : nil, value: offsetX)
                .animation(.easeInOut(duration: 0.3), value: hasBubbles)
            Color.clear
                .frame(height: markersRowHeight)
        }
    }

    // MARK: - Bubble Row (Meal/Workout Emoji Bubbles)

    /// Diameter of each meal/workout bubble. Sized to match the per-tap target
    /// while staying narrow enough to fit between adjacent meals.
    var liveBubbleSize: CGFloat { 28 }

    /// Vertical breathing room above each bubble so the circles don't kiss the
    /// time button. Tuned by eye on-device.
    private var liveBubbleTopGap: CGFloat { 8 }

    /// Empty space reserved above the time button. Set to zero so the time
    /// button keeps the original top padding from the card — no extra spacing.
    private var liveButtonRowTopGap: CGFloat { 0 }

    /// Vertical connector below each bubble down to the bar. Tuned by eye
    /// so the bubble reads as visually close to the bar.
    private var liveBubbleBottomConnectorHeight: CGFloat { 7 }

    /// Solid colour used for the bubble→bar connector and the meal/workout
    /// markers on the bar. A solid value avoids the transparency-blend mismatch
    /// that made the line read as two different shades above vs. on the bar.
    private var bubbleConnectorColor: Color {
        // 40% opacity (NutriKit #1449) — softens the emoji-group circles and their
        // connector lines so they blend with the glass timing card.
        Color(.systemGray3).opacity(0.4)
    }

    /// Total height of the bubble row, including the vertical connector that
    /// reaches down to the bar. The same total height is reserved when there
    /// are no bubbles — split into a top spacer (above the now button) and
    /// the strip below — so the cell's overall height stays consistent.
    var liveBubbleRowHeight: CGFloat {
        liveBubbleTopGap + liveBubbleSize + liveBubbleBottomConnectorHeight
    }

    private func liveBubbleRow() -> some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let slotWidth = totalWidth / CGFloat(TimelineSlots.count)
            let connectorWidth = max(slotWidth * 0.8, 2)

            ZStack(alignment: .topLeading) {
                ForEach(mealBubbles) { bubble in
                    bubbleColumn(
                        for: bubble.timeSlot,
                        slotWidth: slotWidth,
                        connectorWidth: connectorWidth,
                        action: {
                            TimeSliderHaptics.impact(.soft)
                            onMealBubbleTapped?(bubble.id)
                        },
                        bubble: {
                            EmojiCircle(
                                emojis: bubble.emojis,
                                tints: bubble.emojiTints,
                                size: liveBubbleSize,
                                fillMaterial: .ultraThinMaterial
                            )
                        }
                    )
                    .transition(bubbleTransition)
                }
                ForEach(workoutBubbles) { bubble in
                    bubbleColumn(
                        for: bubble.timeSlot,
                        slotWidth: slotWidth,
                        connectorWidth: connectorWidth,
                        action: {
                            TimeSliderHaptics.impact(.soft)
                            onWorkoutBubbleTapped?(bubble.id)
                        },
                        bubble: {
                            EmojiCircle(
                                symbols: bubble.systemImageNames,
                                size: liveBubbleSize,
                                fillMaterial: .ultraThinMaterial,
                                symbolColor: Color(.label)
                            )
                        }
                    )
                    .transition(bubbleTransition)
                }
            }
            .frame(width: totalWidth, height: liveBubbleRowHeight, alignment: .topLeading)
        }
        .frame(height: liveBubbleRowHeight)
    }

    /// Fade + scale applied when meal/workout bubbles are added or removed.
    /// Animation is attached to the transition so removals animate even when
    /// the upstream state change wasn't wrapped in `withAnimation`.
    private var bubbleTransition: AnyTransition {
        .scale(scale: 0.4)
            .combined(with: .opacity)
            .animation(.spring(response: 0.4, dampingFraction: 0.75))
    }

    @ViewBuilder
    private func bubbleColumn<B: View>(
        for timeSlot: Int,
        slotWidth: CGFloat,
        connectorWidth: CGFloat,
        action: @escaping () -> Void,
        @ViewBuilder bubble: () -> B
    ) -> some View {
        let mealMinute = Double(timeSlot) * TimelineSlots.minutesPerSlot
        let vSlot = visualSlotForMinute(mealMinute)
        // Centre of the slot, mirroring how meal markers position themselves
        let slotCenterX = CGFloat(vSlot) * slotWidth + slotWidth / 2

        if vSlot >= -1, vSlot <= CGFloat(TimelineSlots.count) + 1 {
            Button(action: action) {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(width: liveBubbleSize, height: liveBubbleTopGap)
                    bubble()
                        .frame(width: liveBubbleSize, height: liveBubbleSize)
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .frame(width: connectorWidth, height: liveBubbleBottomConnectorHeight)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(x: slotCenterX, y: liveBubbleRowHeight / 2)
        }
    }
}
