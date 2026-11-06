import SwiftUI

// The interactive slider's bar (stripes or the compact track), the axis under it, the bubbles
// over it, and the zoom geometry every mode shares.

extension TimeSlider {

    // MARK: - Bar

    var slider: some View {
        GeometryReader { proxy in
            if sliderStyle == .compact {
                continuousTrack(width: proxy.size.width)
            } else {
                stripes
            }
        }
    }

    /// The bar's 120 stripes in one Canvas, each snapped to whole device pixels with the same gap
    /// (#3948). As 120 views ~2.4 pt wide with 0.5 pt gaps they landed on fractional pixels, and
    /// the antialiased edges beat against the pixel grid: bands of lighter and darker stripes.
    private var stripes: some View {
        let colors = (0..<TimelineSlots.count).map { stripeColor(at: $0) }
        let scale = max(displayScale, 1)
        let gap = spacing
        return Canvas { context, size in
            let count = colors.count
            let totalPixels = (size.width * scale).rounded(.down)
            let gapPixels = max((gap * scale).rounded(), 1)
            for i in 0..<count {
                let from = (totalPixels * CGFloat(i) / CGFloat(count)).rounded()
                let to = (totalPixels * CGFloat(i + 1) / CGFloat(count)).rounded() - gapPixels
                let rect = CGRect(x: from / scale, y: 0, width: max(to - from, 1) / scale, height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1, style: .continuous), with: .color(colors[i]))
            }
        }
    }

    /// One quarter-hour stripe (or, zoomed, a 5- or 1-minute one).
    func stripeColor(at visualIndex: Int) -> Color {
        let minute = minuteForVisualSlot(Double(visualIndex))
        let realSlot = Int(minute / TimelineSlots.minutesPerSlot)
        let isInDay = minute >= 0 && minute < TimelineSlots.totalMinutes

        /// Only the one visual slot holding the start of a 15-min real slot, so a meal (or
        /// workout, or marker) isn't drawn several times over when zoomed in.
        func startsHere(_ slot: Int) -> Bool {
            let startMinute = Double(slot) * TimelineSlots.minutesPerSlot
            return minute >= startMinute && minute < startMinute + minutesPerVisualSlot
        }
        let isExistingMeal = isInDay && existingTimeSlots.contains(realSlot) && startsHere(realSlot)
        /// NutriKit #3160 — a workout's start marks the bar like a meal does, so its bubble's
        /// connector lands on a tick. Kept apart from `existingTimeSlots`: a workout is never a
        /// meal to snap to or select.
        let isWorkout = isInDay && workoutBubbles.contains(where: { $0.timeSlot == realSlot }) && startsHere(realSlot)
        let isAllowed = isInDay && allowedTimeSlotsRange.contains(realSlot)

        if isInterval {
            // An interval's stretch, by the stripe's start (#3948).
            if minute >= self.minute(of: currentTime) - minutesPerVisualSlot / 2,
               minute < self.minute(of: endTime) - minutesPerVisualSlot / 2 {
                return themedAccentColor.opacity(0.4)
            }
        } else if visualIndex == Int(currentVisualSlot) {
            return Color(.secondarySystemFill)
        }
        if isExistingMeal || isWorkout {
            return Color(.label).opacity(0.25)
        }
        if !isAllowed {
            return Color(.quaternarySystemFill).opacity(0.5)
        }
        return Color(.secondarySystemFill)
    }

    // MARK: - Compact track (NutriKit #3302)

    /// The compact style's bar: live mode's continuous track (`liveSlider`) at this mode's
    /// zoom, in place of a stripe per quarter-hour. The stripes' three tones carry over — the
    /// allowed stretch on the track's fill, the rest on the lighter one, and a tick in the
    /// meal colour where each meal and workout starts, which the bubbles' connectors land on.
    /// An interval's stretch is coloured over it.
    private func continuousTrack(width: CGFloat) -> some View {
        let slotWidth = width / CGFloat(TimelineSlots.count)
        let shape = RoundedRectangle(cornerRadius: compactTrackCornerRadius, style: .continuous)
        let allowed = allowedTrackSpan(width: width)
        let tickSlots = existingTimeSlots + workoutBubbles.map(\.timeSlot)
        return ZStack(alignment: .leading) {
            shape.fill(Color(.quaternarySystemFill).opacity(0.5))
            Rectangle()
                .fill(Color(.secondarySystemFill))
                .frame(width: max(allowed.upperBound - allowed.lowerBound, 0))
                .offset(x: allowed.lowerBound)
            if isInterval {
                // The interval's stretch, at the current zoom.
                let from = min(max(currentVisualSlot * slotWidth, 0), width)
                let to = min(max(endVisualSlot * slotWidth, from), width)
                Rectangle()
                    .fill(themedAccentColor.opacity(0.4))
                    .frame(width: to - from)
                    .offset(x: from)
            }
            ForEach(Array(Set(tickSlots)).sorted(), id: \.self) { slot in
                trackTick(slot: slot, slotWidth: slotWidth)
            }
        }
        .frame(width: width, height: barHeight, alignment: .leading)
        .clipShape(shape)
    }

    /// The allowed range's stretch of the track, in its own x — clamped to what the zoom shows.
    private func allowedTrackSpan(width: CGFloat) -> ClosedRange<CGFloat> {
        let slotWidth = width / CGFloat(TimelineSlots.count)
        let startMinute = Double(allowedTimeSlotsRange.lowerBound) * TimelineSlots.minutesPerSlot
        let endMinute = Double(allowedTimeSlotsRange.upperBound + 1) * TimelineSlots.minutesPerSlot
        let start = min(max(visualSlotForMinute(startMinute) * slotWidth, 0), width)
        let end = min(max(visualSlotForMinute(endMinute) * slotWidth, start), width)
        return start...end
    }

    @ViewBuilder
    private func trackTick(slot: Int, slotWidth: CGFloat) -> some View {
        let vSlot = visualSlotForMinute(Double(slot) * TimelineSlots.minutesPerSlot)
        if vSlot >= -1, vSlot <= CGFloat(TimelineSlots.count) + 1 {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color(.label).opacity(0.25))
                .frame(width: max(slotWidth * 0.8, 2), height: barHeight)
                .offset(x: vSlot * slotWidth + slotWidth * 0.1)
        }
    }

    func width(for width: CGFloat) -> CGFloat {
        let available = (width - (spacing * (CGFloat(TimelineSlots.count) - 1.0)))
        return max(available / CGFloat(TimelineSlots.count), 0)
    }

    /// The visual slot under an x in the slider's space.
    func timeSlot(for x: CGFloat) -> Int {
        let width = width(for: sliderWidth)
        let timeSlot = Int(x / (width + spacing))
        return min(max(timeSlot, 0), TimelineSlots.count - 1)
    }

    // MARK: - Axis

    private struct MarkerItem {
        let minute: Double
        let label: String
    }

    /// Ticks and hour labels under the bar, following the zoom (both modes).
    var zoomedMarkersRow: some View {
        let markers = generateZoomedMarkers()

        return ZStack {
            ForEach(markers.indices, id: \.self) { index in
                let marker = markers[index]
                let visualSlot = visualSlotForMinute(marker.minute)
                let offsetX = offsetXForVisualSlot(visualSlot)

                // Only show if within visible bounds (with small margin)
                let isVisible = visualSlot >= -2 && visualSlot <= CGFloat(TimelineSlots.count) + 2

                if isVisible {
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(Color(.systemFill))
                            .frame(width: marker.label.isEmpty ? 0.75 : 1.0, height: 5)
                        Text(marker.label)
                            // NutriKit #2733 — hour labels are numerals: the host's number face,
                            // like the pill above them.
                            .timeSliderNumberFont(.caption2)
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                    .offset(x: offsetX)
                }
            }
            .timeSliderReadSize { size in
                markersRowHeight = size.height
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: zoomLevel)
    }

    private func generateZoomedMarkers() -> [MarkerItem] {
        var markers: [MarkerItem] = []
        let lastMinute = Int(TimelineSlots.totalMinutes)

        if zoomLevel < 2 {
            // 1x: label every 6h, ticks every 3h
            let hourLabels: [Int: String] = [0: "12a", 6: "6a", 12: "12p", 18: "6p", 24: "12a", 30: "6a"]
            for hour in stride(from: 0, through: 30, by: 3) {
                markers.append(MarkerItem(minute: Double(hour * 60), label: hourLabels[hour] ?? ""))
            }
        } else if zoomLevel < 10 {
            // 3x: label every hour, ticks every 15 min
            let startMinute = max(0, Int(visibleStartMinute) - 60)
            let endMinute = min(lastMinute, Int(visibleStartMinute + totalVisibleMinutes) + 60)

            for minute in stride(from: (startMinute / 15) * 15, through: endMinute, by: 15) {
                let label = minute % 60 == 0 ? TimelineSlots.axisLabel(forMinute: minute) : ""
                markers.append(MarkerItem(minute: Double(minute), label: label))
            }
        } else {
            // 15x: label every 15 min, ticks every 5 min
            let startMinute = max(0, Int(visibleStartMinute) - 15)
            let endMinute = min(lastMinute, Int(visibleStartMinute + totalVisibleMinutes) + 15)

            for minute in stride(from: (startMinute / 5) * 5, through: endMinute, by: 5) {
                let label = minute % 15 == 0 ? TimelineSlots.axisLabel(forMinute: minute) : ""
                markers.append(MarkerItem(minute: Double(minute), label: label))
            }
        }

        return markers
    }

    // MARK: - Interactive Bubbles (NutriKit #3160)

    var hasBubbles: Bool {
        !mealBubbles.isEmpty || !workoutBubbles.isEmpty
    }

    /// Diameter of a bubble in the sheet pickers — a touch smaller than the home card's,
    /// since these timelines sit in a narrower card and never take taps on a bubble.
    private var interactiveBubbleSize: CGFloat { 24 }
    private var interactiveBubbleTopGap: CGFloat { 6 }
    private var interactiveBubbleBottomConnectorHeight: CGFloat { 6 }

    var interactiveBubbleRowHeight: CGFloat {
        interactiveBubbleTopGap + interactiveBubbleSize + interactiveBubbleBottomConnectorHeight
    }

    /// The height between the time pill and the bar — the needle's run above the bar.
    var interactiveGapHeight: CGFloat {
        hasBubbles ? interactiveBubbleRowHeight : 20
    }

    /// The day's meals (emoji circles of their foods) and workouts (their activity symbols)
    /// over the bar, each on a connector down to its tick. Drawn above the needle so a meal
    /// or workout the needle rests on stays legible, and zoom-aware like the ticks. It takes
    /// no touches: a tap or drag here is the slider's own, exactly as over the bar.
    var interactiveBubbleLayer: some View {
        let slotWidth = sliderWidth / CGFloat(TimelineSlots.count)
        let connectorWidth = max(slotWidth * 0.8, 2)
        return VStack(spacing: 0) {
            Color.clear
                .frame(height: buttonSize.height)
            ZStack(alignment: .topLeading) {
                ForEach(mealBubbles) { bubble in
                    interactiveBubbleColumn(for: bubble.timeSlot, slotWidth: slotWidth, connectorWidth: connectorWidth) {
                        EmojiCircle(
                            emojis: bubble.emojis,
                            tints: bubble.emojiTints,
                            size: interactiveBubbleSize
                        )
                    }
                }
                ForEach(workoutBubbles) { bubble in
                    interactiveBubbleColumn(for: bubble.timeSlot, slotWidth: slotWidth, connectorWidth: connectorWidth) {
                        EmojiCircle(
                            symbols: bubble.systemImageNames,
                            size: interactiveBubbleSize,
                            symbolColor: Color(.label)
                        )
                    }
                }
            }
            .frame(width: sliderWidth, height: interactiveBubbleRowHeight, alignment: .topLeading)
            Color.clear
                .frame(height: barHeight + markersRowHeight)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func interactiveBubbleColumn<B: View>(
        for timeSlot: Int,
        slotWidth: CGFloat,
        connectorWidth: CGFloat,
        @ViewBuilder bubble: () -> B
    ) -> some View {
        let vSlot = visualSlotForMinute(Double(timeSlot) * TimelineSlots.minutesPerSlot)
        let slotCenterX = CGFloat(vSlot) * slotWidth + slotWidth / 2
        if vSlot >= -1, vSlot <= CGFloat(TimelineSlots.count) + 1 {
            VStack(spacing: 0) {
                Color.clear
                    .frame(width: interactiveBubbleSize, height: interactiveBubbleTopGap)
                bubble()
                    .frame(width: interactiveBubbleSize, height: interactiveBubbleSize)
                Rectangle()
                    .fill(Color(.label).opacity(0.25))
                    .frame(width: connectorWidth, height: interactiveBubbleBottomConnectorHeight)
            }
            .position(x: slotCenterX, y: interactiveBubbleRowHeight / 2)
        }
    }

    // MARK: - Zoom geometry

    /// Minutes each visual slot represents at the current zoom level
    var minutesPerVisualSlot: Double {
        TimelineSlots.minutesPerSlot / Double(zoomLevel)
    }

    /// Total minutes visible in the slider at the current zoom level
    var totalVisibleMinutes: Double {
        Double(TimelineSlots.count) * minutesPerVisualSlot
    }

    /// The clamped zoom center so the visible range doesn't exceed the day
    var clampedZoomCenter: Double {
        let halfVisible = totalVisibleMinutes / 2.0
        return min(max(zoomCenterMinute, halfVisible), TimelineSlots.totalMinutes - halfVisible)
    }

    /// First visible minute at the leading edge of the slider
    var visibleStartMinute: Double {
        clampedZoomCenter - totalVisibleMinutes / 2.0
    }

    /// Map a real-world minute to a visual slot index (can be fractional, 0...120)
    func visualSlotForMinute(_ minute: Double) -> CGFloat {
        CGFloat((minute - visibleStartMinute) / minutesPerVisualSlot)
    }

    /// Map a visual slot index to a real-world minute
    func minuteForVisualSlot(_ slot: Double) -> Double {
        visibleStartMinute + slot * minutesPerVisualSlot
    }

    /// Offset from ZStack center for a given fractional visual slot
    func offsetXForVisualSlot(_ slot: CGFloat) -> CGFloat {
        guard sliderWidth > 0 else { return 0 }
        let slotWidth = sliderWidth / CGFloat(TimelineSlots.count)
        return slot * slotWidth - sliderWidth / 2.0 + slotWidth / 2.0
    }

    /// The visual slot position for the current time needle (precise, not just 15-min aligned)
    var currentVisualSlot: CGFloat {
        visualSlotForMinute(minute(of: currentTime))
    }

    /// An interval's end needle.
    var endVisualSlot: CGFloat {
        visualSlotForMinute(minute(of: endTime))
    }

    /// Update zoom center so that `fingerX` keeps mapping to `fingerMinute` after zoom change
    func zoomCenter(keeping fingerMinute: Double, at fingerX: CGFloat, forLevel level: CGFloat) -> Double {
        let newTotalVisible = Double(TimelineSlots.count) * (TimelineSlots.minutesPerSlot / Double(level))
        let fingerFraction = Double(fingerX / max(sliderWidth, 1))
        return fingerMinute + newTotalVisible * (0.5 - fingerFraction)
    }
}
